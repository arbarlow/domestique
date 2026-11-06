// Package radio serves Race Radio: protobuf frames over WebSocket, on Unix sockets and TCP.
package radio

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/core"
	"github.com/arbarlow/domestique/teamcar/internal/store"
)

const (
	// Path is the WebSocket endpoint.
	Path = "/radio/v1"
	// MaxFrameBytes caps one incoming frame (attachments included).
	MaxFrameBytes     = 64 << 20
	helloTimeout      = 10 * time.Second
	defaultCoalesce   = 33 * time.Millisecond
	controlLaneSize   = 256
	streamLaneSize    = 4096
	idempotencyTTL    = 10 * time.Minute
	defaultTranscript = 500
)

// Keepalive. Variables so tests can shorten them.
var (
	pingInterval = 15 * time.Second
	pingTimeout  = 30 * time.Second
)

type Server struct {
	car   *core.Car
	store *store.Store
	log   *slog.Logger
	idem  *idempotency
}

func NewServer(car *core.Car, st *store.Store, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	return &Server{car: car, store: st, log: log, idem: newIdempotency()}
}

// Serve accepts Race Radio connections on l until ctx is done. trusted listeners (the Unix socket,
// protected by file permissions) don't require a token.
func (s *Server) Serve(ctx context.Context, l net.Listener, trusted bool) error {
	mux := http.NewServeMux()
	mux.HandleFunc(Path, func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			// Native clients only; browsers would need an Origin allowlist.
			InsecureSkipVerify: true,
		})
		if err != nil {
			return
		}
		c.SetReadLimit(MaxFrameBytes)
		s.handle(r.Context(), c, trusted, r.RemoteAddr)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	hs := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second, BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = hs.Shutdown(shutdown)
	}()
	err := hs.Serve(l)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// ---- connection

type conn struct {
	s       *Server
	ws      *websocket.Conn
	ctx     context.Context
	cancel  context.CancelFunc
	scope   radiov1.TokenScope
	tokenID string
	remote  string

	control chan *radiov1.ServerFrame // responses, pongs, gaps: always written first
	events  chan outFrame             // subscription events

	subMu  sync.Mutex
	subs   map[uint64]context.CancelFunc
	procs  map[string]*procHandle // running processes, by process id (this connection's only)
	nextID atomic.Uint64

	// When the client was last heard from: any frame, or a pong.
	lastHeard atomic.Int64
}

// outFrame is an event-lane frame. sent (optional) runs once the frame is written (or the write
// failed), so a producer can limit how much it has in flight.
type outFrame struct {
	f    *radiov1.ServerFrame
	sent func()
}

func (s *Server) handle(parent context.Context, ws *websocket.Conn, trusted bool, remote string) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	c := &conn{
		s: s, ws: ws, ctx: ctx, cancel: cancel, remote: remote,
		control: make(chan *radiov1.ServerFrame, controlLaneSize),
		events:  make(chan outFrame, streamLaneSize),
		subs:    map[uint64]context.CancelFunc{},
		procs:   map[string]*procHandle{},
	}
	if err := c.handshake(trusted); err != nil {
		s.log.Info("handshake failed", "remote", remote, "err", err)
		return
	}
	s.log.Info("client connected", "remote", remote, "scope", c.scope)
	go c.writeLoop()
	go c.pingLoop()
	c.readLoop()
	s.log.Info("client disconnected", "remote", remote)
}

func (c *conn) handshake(trusted bool) error {
	hctx, cancel := context.WithTimeout(c.ctx, helloTimeout)
	defer cancel()
	_, data, err := c.ws.Read(hctx)
	if err != nil {
		return err
	}
	var f radiov1.ClientFrame
	if err := proto.Unmarshal(data, &f); err != nil || f.GetHello() == nil {
		c.goodbye(radiov1.ErrorCode_ERROR_CODE_PROTOCOL, "first frame must be Hello")
		return errors.New("no hello")
	}
	h := f.GetHello()
	if h.ProtocolVersion != radiov1.ProtocolVersion_PROTOCOL_VERSION_1 {
		c.goodbye(radiov1.ErrorCode_ERROR_CODE_PROTOCOL, fmt.Sprintf("unsupported protocol version %v", h.ProtocolVersion))
		return errors.New("protocol version")
	}
	switch {
	case h.Token != "":
		info, err := c.s.store.Authenticate(h.Token)
		if err != nil {
			c.goodbye(radiov1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "invalid token")
			return errors.New("invalid token")
		}
		c.scope, c.tokenID = info.Scope, info.Id
	case trusted:
		c.scope, c.tokenID = radiov1.TokenScope_TOKEN_SCOPE_ADMIN, "local"
	default:
		c.goodbye(radiov1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "a token is required")
		return errors.New("missing token")
	}
	welcome := &radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Welcome{Welcome: &radiov1.Welcome{
		ProtocolVersion: radiov1.ProtocolVersion_PROTOCOL_VERSION_1,
		ServerId:        c.s.car.ServerID(), ServerName: c.s.car.ServerName(), ServerVersion: c.s.car.Version(),
		Capabilities: []string{"coalesce"}, Scope: c.scope,
	}}}
	return c.writeFrame(hctx, welcome)
}

func (c *conn) goodbye(code radiov1.ErrorCode, msg string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = c.writeFrame(ctx, &radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Goodbye{Goodbye: &radiov1.Goodbye{Code: code, Message: msg}}})
	_ = c.ws.Close(websocket.StatusPolicyViolation, msg)
}

func (c *conn) heard() { c.lastHeard.Store(time.Now().UnixNano()) }

func (c *conn) writeFrame(ctx context.Context, f *radiov1.ServerFrame) error {
	b, err := proto.Marshal(f)
	if err != nil {
		return err
	}
	return c.ws.Write(ctx, websocket.MessageBinary, b)
}

func (c *conn) writeLoop() {
	defer c.cancel()
	for {
		// Control frames first, always.
		select {
		case f := <-c.control:
			if c.writeFrame(c.ctx, f) != nil {
				return
			}
			continue
		default:
		}
		select {
		case f := <-c.control:
			if c.writeFrame(c.ctx, f) != nil {
				return
			}
		case o := <-c.events:
			err := c.writeFrame(c.ctx, o.f)
			if o.sent != nil {
				o.sent()
			}
			if err != nil {
				return
			}
		case <-c.ctx.Done():
			_ = c.ws.Close(websocket.StatusNormalClosure, "")
			return
		}
	}
}

// pingLoop drops a client it hasn't heard from (no frame, no pong) for pingTimeout. A client that
// stops reading to push back on a process's output can't answer pings, so it must keep sending
// frames: Ping every pingInterval or so (the Go SDK does). Pings are sent without a deadline:
// coder/websocket closes the connection when a write's deadline passes mid-frame.
func (c *conn) pingLoop() {
	t := time.NewTicker(pingInterval)
	defer t.Stop()
	c.heard()
	var pinging atomic.Bool
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-t.C:
		}
		if pinging.CompareAndSwap(false, true) {
			go func() {
				defer pinging.Store(false)
				if c.ws.Ping(c.ctx) == nil {
					c.heard()
				}
			}()
		}
		if time.Since(time.Unix(0, c.lastHeard.Load())) > pingTimeout {
			c.s.log.Info("client stopped answering; disconnecting", "remote", c.remote)
			c.cancel()
			return
		}
	}
}

func (c *conn) readLoop() {
	defer c.cancel()
	for {
		_, data, err := c.ws.Read(c.ctx)
		if err != nil {
			return
		}
		c.heard()
		var f radiov1.ClientFrame
		if err := proto.Unmarshal(data, &f); err != nil {
			c.goodbye(radiov1.ErrorCode_ERROR_CODE_PROTOCOL, "malformed frame")
			return
		}
		switch fr := f.Frame.(type) {
		case *radiov1.ClientFrame_Ping:
			// Pongs are droppable: never let them block reading (the lane fills while a
			// back-pressuring client isn't reading).
			select {
			case c.control <- &radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Pong{Pong: &radiov1.Pong{Nonce: fr.Ping.Nonce}}}:
			default:
			}
		case *radiov1.ClientFrame_Request:
			if in := fr.Request.GetProcessInput(); in != nil {
				// Inline, so a process's input is applied in the order it was sent.
				c.processInput(fr.Request.Id, in)
				continue
			}
			go c.dispatch(fr.Request)
		case *radiov1.ClientFrame_Hello:
			c.goodbye(radiov1.ErrorCode_ERROR_CODE_PROTOCOL, "duplicate Hello")
			return
		}
	}
}

func (c *conn) sendControl(f *radiov1.ServerFrame) {
	select {
	case c.control <- f:
	case <-c.ctx.Done():
	}
}

func (c *conn) sendEvent(f *radiov1.ServerFrame) bool {
	return c.sendEventCtx(c.ctx, f, nil)
}

// sendEventCtx queues an event, blocking while the lane is full (until ctx is done).
func (c *conn) sendEventCtx(ctx context.Context, f *radiov1.ServerFrame, sent func()) bool {
	select {
	case c.events <- outFrame{f: f, sent: sent}:
		return true
	case <-ctx.Done():
		return false
	}
}

func (c *conn) respond(id uint64, resp *radiov1.Response) {
	resp.Id = id
	c.sendControl(&radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Response{Response: resp}})
}

func errResponse(code radiov1.ErrorCode, format string, a ...any) *radiov1.Response {
	return &radiov1.Response{Result: &radiov1.Response_Error{Error: &radiov1.Error{Code: code, Message: fmt.Sprintf(format, a...)}}}
}

func fromError(err error) *radiov1.Response {
	code := radiov1.ErrorCode_ERROR_CODE_INTERNAL
	switch {
	case errors.Is(err, core.ErrNotFound), errors.Is(err, store.ErrNotFound):
		code = radiov1.ErrorCode_ERROR_CODE_NOT_FOUND
	case errors.Is(err, core.ErrInvalid):
		code = radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT
	case errors.Is(err, core.ErrPrecondition):
		code = radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		code = radiov1.ErrorCode_ERROR_CODE_UNAVAILABLE
	}
	return &radiov1.Response{Result: &radiov1.Response_Error{Error: &radiov1.Error{Code: code, Message: err.Error()}}}
}

func empty() *radiov1.Response {
	return &radiov1.Response{Result: &radiov1.Response_Empty{Empty: &radiov1.Empty{}}}
}

// ---- subscriptions

func (c *conn) addSub() (uint64, context.Context) {
	id := c.nextID.Add(1)
	ctx, cancel := context.WithCancel(c.ctx)
	c.subMu.Lock()
	c.subs[id] = cancel
	c.subMu.Unlock()
	return id, ctx
}

func (c *conn) endSub(id uint64) bool {
	c.subMu.Lock()
	cancel, ok := c.subs[id]
	delete(c.subs, id)
	c.subMu.Unlock()
	if ok {
		cancel()
	}
	return ok
}

func eventFrame(subID uint64, ev *radiov1.Event) *radiov1.ServerFrame {
	return &radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Event{Event: &radiov1.Event{
		SubscriptionId: subID, Seq: ev.Seq, Payload: ev.Payload,
	}}}
}

func (c *conn) subscribeServer(reqID uint64) {
	snap, sub := c.s.car.SubscribeServer()
	id, ctx := c.addSub()
	c.respond(reqID, &radiov1.Response{Result: &radiov1.Response_Subscribe{Subscribe: &radiov1.SubscribeResult{SubscriptionId: id}}})
	go func() {
		defer sub.Close()
		defer c.endSub(id)
		var n uint64 = 1
		if !c.sendEvent(eventFrame(id, &radiov1.Event{Seq: n, Payload: &radiov1.Event_ServerSnapshot{ServerSnapshot: snap}})) {
			return
		}
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-sub.C:
				if !ok {
					c.sendControl(&radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Gap{Gap: &radiov1.Gap{
						SubscriptionId: id, Reason: "server stream lagged; resubscribe for a fresh snapshot"}}})
					return
				}
				n++
				if !c.sendEvent(eventFrame(id, &radiov1.Event{Seq: n, Payload: ev.Payload})) {
					return
				}
			}
		}
	}()
}

func (c *conn) subscribeRider(reqID uint64, t *radiov1.RiderTarget) {
	r, err := c.s.car.Rider(t.RiderId)
	if err != nil {
		c.respond(reqID, fromError(err))
		return
	}
	replay, sub, err := r.Subscribe(t.FromSeq)
	if err != nil {
		c.respond(reqID, fromError(err))
		return
	}
	coalesce := defaultCoalesce
	if t.CoalesceMs > 0 {
		coalesce = time.Duration(min(t.CoalesceMs, 2000)) * time.Millisecond
	}
	id, ctx := c.addSub()
	c.respond(reqID, &radiov1.Response{Result: &radiov1.Response_Subscribe{Subscribe: &radiov1.SubscribeResult{SubscriptionId: id}}})
	go func() {
		defer sub.Close()
		defer c.endSub(id)
		last := t.FromSeq
		for _, e := range replay {
			if !c.sendEvent(eventFrame(id, &radiov1.Event{Seq: e.Seq, Payload: &radiov1.Event_ItemUpserted{ItemUpserted: e.Item}})) {
				return
			}
			last = max(last, e.Seq)
		}
		if !c.sendEvent(eventFrame(id, &radiov1.Event{Seq: last, Payload: &radiov1.Event_ReplayDone{ReplayDone: &radiov1.ReplayDone{}}})) {
			return
		}
		c.pumpRider(ctx, id, sub, coalesce, last)
	}()
}

// pumpRider forwards live rider events, merging AppendText deltas for up to `coalesce`.
func (c *conn) pumpRider(ctx context.Context, id uint64, sub *core.Subscriber, coalesce time.Duration, last uint64) {
	var pending []*radiov1.AppendText
	var pendingSeq uint64
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	armed := false
	flush := func() bool {
		if armed {
			timer.Stop()
			armed = false
		}
		for _, a := range pending {
			if !c.sendEvent(eventFrame(id, &radiov1.Event{Seq: pendingSeq, Payload: &radiov1.Event_AppendText{AppendText: a}})) {
				return false
			}
		}
		pending = pending[:0]
		return true
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			armed = false
			if !flush() {
				return
			}
		case ev, ok := <-sub.C:
			if !ok {
				if !flush() {
					return
				}
				reason := "rider closed"
				if sub.Dropped() {
					reason = "client lagged; resubscribe from resume_seq"
				}
				c.sendControl(&radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Gap{Gap: &radiov1.Gap{SubscriptionId: id, ResumeSeq: last, Reason: reason}}})
				return
			}
			if ev.Seq > last {
				last = ev.Seq
			}
			if a := ev.GetAppendText(); a != nil {
				if n := len(pending); n > 0 && pending[n-1].ItemId == a.ItemId {
					pending[n-1] = &radiov1.AppendText{ItemId: a.ItemId, Delta: pending[n-1].Delta + a.Delta}
				} else {
					pending = append(pending, a)
				}
				pendingSeq = ev.Seq
				if !armed {
					timer.Reset(coalesce)
					armed = true
				}
				continue
			}
			if !flush() {
				return
			}
			if !c.sendEvent(eventFrame(id, ev)) {
				return
			}
		}
	}
}

// ---- idempotency

type idemEntry struct {
	done chan struct{}
	resp *radiov1.Response
	at   time.Time
}

type idempotency struct {
	mu sync.Mutex
	m  map[string]*idemEntry
}

func newIdempotency() *idempotency { return &idempotency{m: map[string]*idemEntry{}} }

// do runs fn once per key within idempotencyTTL; concurrent and later callers get the same response.
func (i *idempotency) do(key string, fn func() *radiov1.Response) *radiov1.Response {
	i.mu.Lock()
	now := time.Now()
	for k, e := range i.m {
		if e.resp != nil && now.Sub(e.at) > idempotencyTTL {
			delete(i.m, k)
		}
	}
	if e, ok := i.m[key]; ok {
		i.mu.Unlock()
		<-e.done
		return proto.Clone(e.resp).(*radiov1.Response)
	}
	e := &idemEntry{done: make(chan struct{})}
	i.m[key] = e
	i.mu.Unlock()
	resp := fn()
	i.mu.Lock()
	e.resp, e.at = resp, time.Now()
	if resp.GetError() != nil {
		delete(i.m, key) // errors may be retried
	}
	i.mu.Unlock()
	close(e.done)
	return proto.Clone(resp).(*radiov1.Response)
}
