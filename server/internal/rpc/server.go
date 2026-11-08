// Package rpc serves the Domestique protocol: protobuf frames over WebSocket, on Unix sockets and TCP.
package rpc

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

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/core"
	"github.com/arbarlow/domestique/server/internal/mcp"
	"github.com/arbarlow/domestique/server/internal/sandbox"
	"github.com/arbarlow/domestique/server/internal/store"
)

const (
	// Path is the WebSocket endpoint.
	Path = "/domestique/v1"
	// LegacyPath is what clients built before the rename connect to.
	LegacyPath = "/radio/v1"
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
	server *core.Server
	store  *store.Store
	log    *slog.Logger
	idem   *idempotency
	// Sandbox providers; nil = none (every sandbox request answers UNIMPLEMENTED).
	sandboxes *sandbox.Manager
	mcp       *mcp.Manager
}

// SetSandboxes attaches this server's sandbox providers. Call before Serve.
func (s *Server) SetSandboxes(m *sandbox.Manager) { s.sandboxes = m }

// SetMcp enables the MCP server commands.
func (s *Server) SetMcp(m *mcp.Manager) { s.mcp = m }

func NewServer(server *core.Server, st *store.Store, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	return &Server{server: server, store: st, log: log, idem: newIdempotency()}
}

// Serve accepts the Domestique protocol connections on l until ctx is done. trusted listeners (the Unix socket,
// protected by file permissions) don't require a token.
func (s *Server) Serve(ctx context.Context, l net.Listener, trusted bool) error {
	mux := http.NewServeMux()
	accept := func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			// Native clients only; browsers would need an Origin allowlist.
			InsecureSkipVerify: true,
		})
		if err != nil {
			return
		}
		c.SetReadLimit(MaxFrameBytes)
		s.handle(r.Context(), c, trusted, r.RemoteAddr)
	}
	mux.HandleFunc(Path, accept)
	mux.HandleFunc(LegacyPath, accept)
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
	scope   domestiquev1.TokenScope
	tokenID string
	remote  string

	control chan *domestiquev1.ServerFrame // responses, pongs, gaps: always written first
	events  chan outFrame                  // subscription events

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
	f    *domestiquev1.ServerFrame
	sent func()
}

func (s *Server) handle(parent context.Context, ws *websocket.Conn, trusted bool, remote string) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	c := &conn{
		s: s, ws: ws, ctx: ctx, cancel: cancel, remote: remote,
		control: make(chan *domestiquev1.ServerFrame, controlLaneSize),
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
	var f domestiquev1.ClientFrame
	if err := proto.Unmarshal(data, &f); err != nil || f.GetHello() == nil {
		c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_PROTOCOL, "first frame must be Hello")
		return errors.New("no hello")
	}
	h := f.GetHello()
	if h.ProtocolVersion != domestiquev1.ProtocolVersion_PROTOCOL_VERSION_1 {
		c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_PROTOCOL, fmt.Sprintf("unsupported protocol version %v", h.ProtocolVersion))
		return errors.New("protocol version")
	}
	switch {
	case h.Token != "":
		info, err := c.s.store.Authenticate(h.Token)
		if err != nil {
			c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "invalid token")
			return errors.New("invalid token")
		}
		c.scope, c.tokenID = info.Scope, info.Id
	case trusted:
		c.scope, c.tokenID = domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN, "local"
	default:
		c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "a token is required")
		return errors.New("missing token")
	}
	welcome := &domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Welcome{Welcome: &domestiquev1.Welcome{
		ProtocolVersion: domestiquev1.ProtocolVersion_PROTOCOL_VERSION_1,
		ServerId:        c.s.server.ServerID(), ServerName: c.s.server.ServerName(), ServerVersion: c.s.server.Version(),
		Capabilities: []string{"coalesce"}, Scope: c.scope,
	}}}
	return c.writeFrame(hctx, welcome)
}

func (c *conn) goodbye(code domestiquev1.ErrorCode, msg string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = c.writeFrame(ctx, &domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Goodbye{Goodbye: &domestiquev1.Goodbye{Code: code, Message: msg}}})
	_ = c.ws.Close(websocket.StatusPolicyViolation, msg)
}

func (c *conn) heard() { c.lastHeard.Store(time.Now().UnixNano()) }

func (c *conn) writeFrame(ctx context.Context, f *domestiquev1.ServerFrame) error {
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
		var f domestiquev1.ClientFrame
		if err := proto.Unmarshal(data, &f); err != nil {
			c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_PROTOCOL, "malformed frame")
			return
		}
		switch fr := f.Frame.(type) {
		case *domestiquev1.ClientFrame_Ping:
			// Pongs are droppable: never let them block reading (the lane fills while a
			// back-pressuring client isn't reading).
			select {
			case c.control <- &domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Pong{Pong: &domestiquev1.Pong{Nonce: fr.Ping.Nonce}}}:
			default:
			}
		case *domestiquev1.ClientFrame_Request:
			if in := fr.Request.GetProcessInput(); in != nil {
				// Inline, so a process's input is applied in the order it was sent.
				c.processInput(fr.Request.Id, in)
				continue
			}
			go c.dispatch(fr.Request)
		case *domestiquev1.ClientFrame_Hello:
			c.goodbye(domestiquev1.ErrorCode_ERROR_CODE_PROTOCOL, "duplicate Hello")
			return
		}
	}
}

func (c *conn) sendControl(f *domestiquev1.ServerFrame) {
	select {
	case c.control <- f:
	case <-c.ctx.Done():
	}
}

func (c *conn) sendEvent(f *domestiquev1.ServerFrame) bool {
	return c.sendEventCtx(c.ctx, f, nil)
}

// sendEventCtx queues an event, blocking while the lane is full (until ctx is done).
func (c *conn) sendEventCtx(ctx context.Context, f *domestiquev1.ServerFrame, sent func()) bool {
	select {
	case c.events <- outFrame{f: f, sent: sent}:
		return true
	case <-ctx.Done():
		return false
	}
}

func (c *conn) respond(id uint64, resp *domestiquev1.Response) {
	resp.Id = id
	c.sendControl(&domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Response{Response: resp}})
}

func errResponse(code domestiquev1.ErrorCode, format string, a ...any) *domestiquev1.Response {
	return &domestiquev1.Response{Result: &domestiquev1.Response_Error{Error: &domestiquev1.Error{Code: code, Message: fmt.Sprintf(format, a...)}}}
}

func fromError(err error) *domestiquev1.Response {
	code := domestiquev1.ErrorCode_ERROR_CODE_INTERNAL
	var api *sandbox.APIError
	switch {
	case errors.As(err, &api):
		// The sandbox service's answer. Never UNAUTHENTICATED: that would read as a bad server token.
		msg := api.Message
		if api.URL != "" {
			msg += " (" + api.URL + ")"
		}
		switch {
		case api.Status == 404:
			code = domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND
		case api.Status == 400 || api.Status == 422:
			code = domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT
		case api.Status == 429 || api.Status >= 500 || api.Status == 0:
			code = domestiquev1.ErrorCode_ERROR_CODE_UNAVAILABLE
		default:
			code = domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Error{Error: &domestiquev1.Error{Code: code, Message: msg}}}
	case errors.Is(err, sandbox.ErrNotFound):
		code = domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND
	case errors.Is(err, sandbox.ErrInvalid):
		code = domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT
	case errors.Is(err, sandbox.ErrPrecondition):
		code = domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION
	case errors.Is(err, core.ErrNotFound), errors.Is(err, store.ErrNotFound):
		code = domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND
	case errors.Is(err, core.ErrInvalid):
		code = domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT
	case errors.Is(err, core.ErrPrecondition):
		code = domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		code = domestiquev1.ErrorCode_ERROR_CODE_UNAVAILABLE
	}
	return &domestiquev1.Response{Result: &domestiquev1.Response_Error{Error: &domestiquev1.Error{Code: code, Message: err.Error()}}}
}

func empty() *domestiquev1.Response {
	return &domestiquev1.Response{Result: &domestiquev1.Response_Empty{Empty: &domestiquev1.Empty{}}}
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

func eventFrame(subID uint64, ev *domestiquev1.Event) *domestiquev1.ServerFrame {
	return &domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Event{Event: &domestiquev1.Event{
		SubscriptionId: subID, Seq: ev.Seq, Payload: ev.Payload,
	}}}
}

func (c *conn) subscribeServer(reqID uint64) {
	snap, sub := c.s.server.SubscribeServer()
	id, ctx := c.addSub()
	c.respond(reqID, &domestiquev1.Response{Result: &domestiquev1.Response_Subscribe{Subscribe: &domestiquev1.SubscribeResult{SubscriptionId: id}}})
	go func() {
		defer sub.Close()
		defer c.endSub(id)
		var n uint64 = 1
		if !c.sendEvent(eventFrame(id, &domestiquev1.Event{Seq: n, Payload: &domestiquev1.Event_ServerSnapshot{ServerSnapshot: snap}})) {
			return
		}
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-sub.C:
				if !ok {
					c.sendControl(&domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Gap{Gap: &domestiquev1.Gap{
						SubscriptionId: id, Reason: "server stream lagged; resubscribe for a fresh snapshot"}}})
					return
				}
				n++
				if !c.sendEvent(eventFrame(id, &domestiquev1.Event{Seq: n, Payload: ev.Payload})) {
					return
				}
			}
		}
	}()
}

func (c *conn) subscribeSession(reqID uint64, t *domestiquev1.SessionTarget) {
	r, err := c.s.server.Session(t.SessionId)
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
	c.respond(reqID, &domestiquev1.Response{Result: &domestiquev1.Response_Subscribe{Subscribe: &domestiquev1.SubscribeResult{SubscriptionId: id}}})
	go func() {
		defer sub.Close()
		defer c.endSub(id)
		last := t.FromSeq
		for _, e := range replay {
			if !c.sendEvent(eventFrame(id, &domestiquev1.Event{Seq: e.Seq, Payload: &domestiquev1.Event_ItemUpserted{ItemUpserted: e.Item}})) {
				return
			}
			last = max(last, e.Seq)
		}
		if !c.sendEvent(eventFrame(id, &domestiquev1.Event{Seq: last, Payload: &domestiquev1.Event_ReplayDone{ReplayDone: &domestiquev1.ReplayDone{}}})) {
			return
		}
		c.pumpSession(ctx, id, sub, coalesce, last)
	}()
}

// pumpSession forwards live session events, merging AppendText deltas for up to `coalesce`.
func (c *conn) pumpSession(ctx context.Context, id uint64, sub *core.Subscriber, coalesce time.Duration, last uint64) {
	var pending []*domestiquev1.AppendText
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
			if !c.sendEvent(eventFrame(id, &domestiquev1.Event{Seq: pendingSeq, Payload: &domestiquev1.Event_AppendText{AppendText: a}})) {
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
				reason := "session closed"
				if sub.Dropped() {
					reason = "client lagged; resubscribe from resume_seq"
				}
				c.sendControl(&domestiquev1.ServerFrame{Frame: &domestiquev1.ServerFrame_Gap{Gap: &domestiquev1.Gap{SubscriptionId: id, ResumeSeq: last, Reason: reason}}})
				return
			}
			if ev.Seq > last {
				last = ev.Seq
			}
			if a := ev.GetAppendText(); a != nil {
				if n := len(pending); n > 0 && pending[n-1].ItemId == a.ItemId {
					pending[n-1] = &domestiquev1.AppendText{ItemId: a.ItemId, Delta: pending[n-1].Delta + a.Delta}
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
	resp *domestiquev1.Response
	at   time.Time
}

type idempotency struct {
	mu sync.Mutex
	m  map[string]*idemEntry
}

func newIdempotency() *idempotency { return &idempotency{m: map[string]*idemEntry{}} }

// do runs fn once per key within idempotencyTTL; concurrent and later callers get the same response.
func (i *idempotency) do(key string, fn func() *domestiquev1.Response) *domestiquev1.Response {
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
		return proto.Clone(e.resp).(*domestiquev1.Response)
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
	return proto.Clone(resp).(*domestiquev1.Response)
}
