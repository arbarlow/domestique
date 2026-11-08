// Package client is the Go SDK for the Domestique protocol: drive a server from any Go program.
//
//	c, err := client.Dial(ctx, "wss://server.example.com:7420/domestique/v1", client.WithToken(token))
//	repo, _ := c.AddRepository(ctx, &domestiquev1.AddRepository{CloneUrl: "git@github.com:acme/api.git"})
//	ws, session, _ := c.CreateWorkspace(ctx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id})
//	turn, _ := c.Prompt(ctx, session.Id, "Fix the flaky test", client.PromptOptions{})
//
// One Client multiplexes every request and subscription over one WebSocket. It reconnects with
// backoff when the connection drops and resumes every subscription from its last cursor, so
// subscribers see a continuous stream. Requests in flight during a drop fail with ErrDisconnected;
// retry them (set an idempotency key on ones that create things).
package client

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

var (
	// ErrDisconnected: the connection dropped before the response arrived.
	ErrDisconnected = errors.New("domestique: disconnected")
	// ErrClosed: the client was closed.
	ErrClosed = errors.New("domestique: client closed")
)

// Error is an error response from the server.
type Error struct {
	Code    domestiquev1.ErrorCode
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("domestique: %s: %s", e.Code, e.Message) }

// IsNotFound reports whether err is a NOT_FOUND response.
func IsNotFound(err error) bool { return Code(err) == domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND }

// Code extracts the error code of a server error (UNSPECIFIED otherwise).
func Code(err error) domestiquev1.ErrorCode {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return domestiquev1.ErrorCode_ERROR_CODE_UNSPECIFIED
}

type options struct {
	token       string
	clientName  string
	clientID    string
	log         *slog.Logger
	reconnect   bool
	maxBackoff  time.Duration
	httpClient  *http.Client
	dialTimeout time.Duration
	keepalive   time.Duration
}

type Option func(*options)

// WithToken sets the bearer token (required on TCP, optional on the local Unix socket).
func WithToken(t string) Option { return func(o *options) { o.token = t } }

// WithClientName sets the name the server logs, e.g. "acme-ci 1.2".
func WithClientName(n string) Option { return func(o *options) { o.clientName = n } }

// WithClientID sets a stable id for this client install.
func WithClientID(id string) Option { return func(o *options) { o.clientID = id } }

func WithLogger(l *slog.Logger) Option { return func(o *options) { o.log = l } }

// WithoutReconnect makes the client give up when the connection drops.
func WithoutReconnect() Option { return func(o *options) { o.reconnect = false } }

// WithMaxBackoff caps the delay between reconnect attempts (default 10s).
func WithMaxBackoff(d time.Duration) Option { return func(o *options) { o.maxBackoff = d } }

// WithKeepalive sets how often the client sends a Ping (default 15s; the server drops connections
// it hasn't heard from for 30s). Pings are written even while the client has stopped reading to
// push back on a process's output, so a paused reader isn't mistaken for a dead one.
func WithKeepalive(d time.Duration) Option { return func(o *options) { o.keepalive = d } }

// WithHTTPClient sets the HTTP client used for the WebSocket handshake (TLS config, proxies).
func WithHTTPClient(h *http.Client) Option { return func(o *options) { o.httpClient = h } }

type pendingReq struct {
	ch chan *domestiquev1.Response
	// hook runs in the read loop before the response is delivered (subscription registration).
	hook func(*domestiquev1.Response)
}

// Client is safe for concurrent use.
type Client struct {
	wsURL string
	opts  options

	ctx    context.Context
	cancel context.CancelFunc
	nextID atomic.Uint64

	mu        sync.Mutex
	ws        *websocket.Conn
	ready     chan struct{} // closed while connected; replaced on disconnect
	welcome   *domestiquev1.Welcome
	pending   map[uint64]*pendingReq
	subs      map[*Subscription]struct{}
	bySubID   map[uint64]*Subscription
	closedErr error
}

// Dial connects to a server. Accepted URLs: ws://host:port/domestique/v1, wss://..., and
// unix:///path/to/server.sock. Dial returns once the first handshake succeeds.
func Dial(ctx context.Context, rawURL string, opts ...Option) (*Client, error) {
	o := options{reconnect: true, maxBackoff: 10 * time.Second, log: slog.Default(), dialTimeout: 10 * time.Second, keepalive: 15 * time.Second}
	for _, f := range opts {
		f(&o)
	}
	if o.clientID == "" {
		b := make([]byte, 8)
		_, _ = rand.Read(b)
		o.clientID = "go-" + hex.EncodeToString(b)
	}
	if o.clientName == "" {
		o.clientName = "domestique Go SDK"
	}
	wsURL, hc, err := resolveURL(rawURL, o.httpClient)
	if err != nil {
		return nil, err
	}
	o.httpClient = hc
	cctx, cancel := context.WithCancel(context.Background())
	c := &Client{
		wsURL: wsURL, opts: o, ctx: cctx, cancel: cancel, ready: make(chan struct{}),
		pending: map[uint64]*pendingReq{}, subs: map[*Subscription]struct{}{}, bySubID: map[uint64]*Subscription{},
	}
	ws, welcome, err := c.connect(ctx)
	if err != nil {
		cancel()
		return nil, err
	}
	c.attach(ws, welcome)
	go c.run(ws)
	return c, nil
}

func resolveURL(raw string, hc *http.Client) (string, *http.Client, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", nil, err
	}
	switch u.Scheme {
	case "unix", "ws+unix":
		path := u.Path
		if path == "" {
			path = u.Opaque
		}
		if path == "" {
			return "", nil, fmt.Errorf("unix URL needs a socket path: %q", raw)
		}
		tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		}}
		return "ws://localhost/radio/v1", &http.Client{Transport: tr}, nil
	case "ws", "wss":
		if u.Path == "" || u.Path == "/" {
			u.Path = "/radio/v1"
		}
		return u.String(), hc, nil
	case "http", "https":
		u.Scheme = strings.Replace(u.Scheme, "http", "ws", 1)
		if u.Path == "" || u.Path == "/" {
			u.Path = "/radio/v1"
		}
		return u.String(), hc, nil
	}
	return "", nil, fmt.Errorf("unsupported URL scheme %q (use ws, wss or unix)", u.Scheme)
}

func (c *Client) connect(ctx context.Context) (*websocket.Conn, *domestiquev1.Welcome, error) {
	dctx, cancel := context.WithTimeout(ctx, c.opts.dialTimeout)
	defer cancel()
	ws, _, err := websocket.Dial(dctx, c.wsURL, &websocket.DialOptions{HTTPClient: c.opts.httpClient})
	if err != nil {
		return nil, nil, fmt.Errorf("domestique: dial %s: %w", c.wsURL, err)
	}
	ws.SetReadLimit(256 << 20)
	hello := &domestiquev1.ClientFrame{Frame: &domestiquev1.ClientFrame_Hello{Hello: &domestiquev1.Hello{
		ProtocolVersion: domestiquev1.ProtocolVersion_PROTOCOL_VERSION_1, ClientId: c.opts.clientID,
		ClientName: c.opts.clientName, Token: c.opts.token,
	}}}
	if err := writeFrame(dctx, ws, hello); err != nil {
		ws.CloseNow()
		return nil, nil, err
	}
	_, data, err := ws.Read(dctx)
	if err != nil {
		ws.CloseNow()
		return nil, nil, fmt.Errorf("domestique: handshake: %w", err)
	}
	var f domestiquev1.ServerFrame
	if err := proto.Unmarshal(data, &f); err != nil {
		ws.CloseNow()
		return nil, nil, err
	}
	if g := f.GetGoodbye(); g != nil {
		ws.CloseNow()
		return nil, nil, &Error{Code: g.Code, Message: g.Message}
	}
	w := f.GetWelcome()
	if w == nil {
		ws.CloseNow()
		return nil, nil, errors.New("domestique: expected Welcome")
	}
	return ws, w, nil
}

func writeFrame(ctx context.Context, ws *websocket.Conn, f *domestiquev1.ClientFrame) error {
	b, err := proto.Marshal(f)
	if err != nil {
		return err
	}
	return ws.Write(ctx, websocket.MessageBinary, b)
}

func (c *Client) attach(ws *websocket.Conn, w *domestiquev1.Welcome) {
	c.mu.Lock()
	c.ws, c.welcome = ws, w
	close(c.ready)
	c.mu.Unlock()
	go c.keepalive(ws)
}

// keepalive pings the server. Its writes keep flowing while the client's reads are paused (a
// process consumer pushing back), so the server knows it's alive either way.
func (c *Client) keepalive(ws *websocket.Conn) {
	if c.opts.keepalive <= 0 {
		return
	}
	t := time.NewTicker(c.opts.keepalive)
	defer t.Stop()
	for n := uint64(1); ; n++ {
		select {
		case <-c.ctx.Done():
			return
		case <-t.C:
		}
		c.mu.Lock()
		current := c.ws == ws
		c.mu.Unlock()
		// No deadline: an expired write deadline closes the connection mid-frame. A write to a
		// dead connection ends when it's closed (detach) or TCP gives up.
		if !current || writeFrame(c.ctx, ws, &domestiquev1.ClientFrame{Frame: &domestiquev1.ClientFrame_Ping{Ping: &domestiquev1.Ping{Nonce: n}}}) != nil {
			return
		}
	}
}

// Welcome returns the server's handshake answer (id, name, version, granted scope).
func (c *Client) Welcome() *domestiquev1.Welcome {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.welcome
}

// Close disconnects and ends every subscription.
func (c *Client) Close() error {
	c.mu.Lock()
	if c.closedErr == nil {
		c.closedErr = ErrClosed
	}
	ws := c.ws
	subs := c.subs
	c.subs = map[*Subscription]struct{}{}
	c.mu.Unlock()
	c.cancel()
	if ws != nil {
		_ = ws.Close(websocket.StatusNormalClosure, "")
	}
	for s := range subs {
		s.finish(ErrClosed)
	}
	return nil
}

// run reads frames and reconnects until the client is closed.
func (c *Client) run(ws *websocket.Conn) {
	for {
		err := c.readLoop(ws)
		c.detach(err)
		if c.ctx.Err() != nil || !c.opts.reconnect {
			c.terminate(err)
			return
		}
		ws = c.reconnect()
		if ws == nil {
			c.terminate(ErrClosed)
			return
		}
		c.resubscribeAll()
	}
}

func (c *Client) readLoop(ws *websocket.Conn) error {
	for {
		_, data, err := ws.Read(c.ctx)
		if err != nil {
			return err
		}
		var f domestiquev1.ServerFrame
		if err := proto.Unmarshal(data, &f); err != nil {
			return err
		}
		switch fr := f.Frame.(type) {
		case *domestiquev1.ServerFrame_Response:
			c.mu.Lock()
			p := c.pending[fr.Response.Id]
			delete(c.pending, fr.Response.Id)
			c.mu.Unlock()
			if p != nil {
				if p.hook != nil {
					p.hook(fr.Response)
				}
				p.ch <- fr.Response
			}
		case *domestiquev1.ServerFrame_Event:
			c.mu.Lock()
			s := c.bySubID[fr.Event.SubscriptionId]
			c.mu.Unlock()
			if s != nil {
				s.deliver(fr.Event)
			}
		case *domestiquev1.ServerFrame_Gap:
			c.mu.Lock()
			s := c.bySubID[fr.Gap.SubscriptionId]
			delete(c.bySubID, fr.Gap.SubscriptionId)
			c.mu.Unlock()
			if s != nil {
				go c.resubscribe(s)
			}
		case *domestiquev1.ServerFrame_Goodbye:
			return &Error{Code: fr.Goodbye.Code, Message: fr.Goodbye.Message}
		}
	}
}

// detach fails in-flight requests and marks subscriptions as needing a resubscribe.
func (c *Client) detach(err error) {
	c.mu.Lock()
	if c.ws != nil {
		c.ws.CloseNow()
	}
	c.ws = nil
	c.ready = make(chan struct{})
	pending := c.pending
	c.pending = map[uint64]*pendingReq{}
	c.bySubID = map[uint64]*Subscription{}
	// Processes died with the connection (the server hangs them up): end them now rather than
	// after a reconnect.
	var lost []*Subscription
	for s := range c.subs {
		if s.noResume {
			lost = append(lost, s)
			delete(c.subs, s)
		}
	}
	c.mu.Unlock()
	for _, p := range pending {
		p.ch <- nil
	}
	for _, s := range lost {
		s.finish(ErrProcessLost)
	}
	if c.ctx.Err() == nil {
		c.opts.log.Warn("domestique: connection lost", "url", c.wsURL, "err", err)
	}
}

func (c *Client) terminate(err error) {
	c.mu.Lock()
	if c.closedErr == nil {
		c.closedErr = fmt.Errorf("%w: %v", ErrDisconnected, err)
	}
	cerr := c.closedErr
	subs := c.subs
	c.subs = map[*Subscription]struct{}{}
	close(c.ready) // wake waiters; they'll see closedErr
	c.mu.Unlock()
	for s := range subs {
		s.finish(cerr)
	}
}

func (c *Client) reconnect() *websocket.Conn {
	for attempt := 0; ; attempt++ {
		backoff := time.Duration(math.Min(float64(c.opts.maxBackoff), float64(200*time.Millisecond)*math.Pow(2, float64(attempt))))
		backoff = backoff/2 + time.Duration(mrand.Int64N(int64(backoff/2)+1))
		select {
		case <-c.ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		ws, w, err := c.connect(c.ctx)
		if err != nil {
			var se *Error
			if errors.As(err, &se) && se.Code == domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
				c.opts.log.Error("domestique: token rejected; giving up", "url", c.wsURL)
				return nil
			}
			continue
		}
		c.opts.log.Info("domestique: reconnected", "url", c.wsURL)
		c.attach(ws, w)
		return ws
	}
}

// Do sends a raw request and waits for its response. Most callers use the typed methods.
func (c *Client) Do(ctx context.Context, req *domestiquev1.Request) (*domestiquev1.Response, error) {
	return c.do(ctx, req, nil)
}

func (c *Client) do(ctx context.Context, req *domestiquev1.Request, hook func(*domestiquev1.Response)) (*domestiquev1.Response, error) {
	p, err := c.send(ctx, req, hook)
	if err != nil {
		return nil, err
	}
	return c.await(ctx, req.Id, p)
}

// send writes a request and returns its pending response without waiting for it. Requests sent
// one after another from one goroutine reach the server in that order.
func (c *Client) send(ctx context.Context, req *domestiquev1.Request, hook func(*domestiquev1.Response)) (*pendingReq, error) {
	ws, err := c.waitConnected(ctx)
	if err != nil {
		return nil, err
	}
	req.Id = c.nextID.Add(1)
	p := &pendingReq{ch: make(chan *domestiquev1.Response, 1), hook: hook}
	c.mu.Lock()
	if c.ws != ws {
		c.mu.Unlock()
		return nil, ErrDisconnected
	}
	c.pending[req.Id] = p
	c.mu.Unlock()
	if err := writeFrame(ctx, ws, &domestiquev1.ClientFrame{Frame: &domestiquev1.ClientFrame_Request{Request: req}}); err != nil {
		c.mu.Lock()
		delete(c.pending, req.Id)
		c.mu.Unlock()
		return nil, fmt.Errorf("%w: %v", ErrDisconnected, err)
	}
	return p, nil
}

func (c *Client) await(ctx context.Context, id uint64, p *pendingReq) (*domestiquev1.Response, error) {
	select {
	case resp := <-p.ch:
		if resp == nil {
			return nil, ErrDisconnected
		}
		if e := resp.GetError(); e != nil {
			return nil, &Error{Code: e.Code, Message: e.Message}
		}
		return resp, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, ctx.Err()
	}
}

func (c *Client) waitConnected(ctx context.Context) (*websocket.Conn, error) {
	for {
		c.mu.Lock()
		if c.closedErr != nil {
			err := c.closedErr
			c.mu.Unlock()
			return nil, err
		}
		if c.ws != nil {
			ws := c.ws
			c.mu.Unlock()
			return ws, nil
		}
		ready := c.ready
		c.mu.Unlock()
		select {
		case <-ready:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}
