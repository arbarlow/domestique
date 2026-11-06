// Package codex drives `codex app-server` (JSON-RPC over stdio). One app-server process is shared
// by every Codex session using the same binary; it uses the user's existing ChatGPT login from
// ~/.codex. Port of AgentKit's CodexAppServer and CodexSession.
package codex

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent/lineproc"
	ts "github.com/arbarlow/domestique/teamcar/internal/agent/toolsummary"
	"google.golang.org/protobuf/proto"
)

// proc is the subset of *lineproc.Process the server uses (faked in tests).
type proc interface {
	WriteJSON(v any) error
	CloseInput()
	Terminate()
	Running() bool
	Lines() <-chan []byte
	Done() <-chan struct{}
	ExitStatus() int
	StderrTail() string
}

// threadHandler receives notifications and server requests for one thread.
type threadHandler interface {
	handleNotification(method string, params ts.JSON)
	// handleServerRequest returns the JSON-RPC result for a server-initiated request (approvals
	// etc.), or ok=false if unsupported. It may block on the user.
	handleServerRequest(method string, params ts.JSON) (result any, ok bool)
	serverExited(message string)
	rateLimit(rl *radiov1.RateLimit)
}

type rpcResult struct {
	result ts.JSON
	err    error
}

// RPCError is a JSON-RPC error returned by the app-server.
type RPCError struct{ Message string }

func (e *RPCError) Error() string { return e.Message }

// AppServer is one `codex app-server` process.
type AppServer struct {
	spawn func() (proc, error)

	startMu sync.Mutex // serialises starts

	mu           sync.Mutex
	proc         proc
	ready        bool
	nextID       int64
	pending      map[int64]chan rpcResult
	handlers     map[string]threadHandler
	cachedModels []*radiov1.ModelOption
	usage        ts.UsageTracker
	lastRate     *radiov1.RateLimit
}

func newAppServer(spawn func() (proc, error)) *AppServer {
	return &AppServer{spawn: spawn, pending: map[int64]chan rpcResult{}, handlers: map[string]threadHandler{}}
}

var servers struct {
	sync.Mutex
	byExe map[string]*AppServer
}

// serverFor returns the shared app-server for a resolved executable (started lazily).
func serverFor(exe string) *AppServer {
	servers.Lock()
	defer servers.Unlock()
	if servers.byExe == nil {
		servers.byExe = map[string]*AppServer{}
	}
	if s := servers.byExe[exe]; s != nil {
		return s
	}
	s := newAppServer(func() (proc, error) {
		home, _ := os.UserHomeDir()
		p, err := lineproc.Start(lineproc.Options{Path: exe, Args: []string{"app-server"}, Dir: home, Env: lineproc.Environ(nil)})
		if err != nil {
			return nil, err
		}
		return p, nil
	})
	servers.byExe[exe] = s
	return s
}

// ShutdownServers stops every shared app-server (call on Team Car exit).
func ShutdownServers() {
	servers.Lock()
	all := make([]*AppServer, 0, len(servers.byExe))
	for _, s := range servers.byExe {
		all = append(all, s)
	}
	servers.Unlock()
	for _, s := range all {
		s.Shutdown()
	}
}

// MARK: lifecycle

func (s *AppServer) running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.proc != nil && s.ready && s.proc.Running()
}

func (s *AppServer) ensureRunning(ctx context.Context) error {
	if s.running() {
		return nil
	}
	s.startMu.Lock()
	defer s.startMu.Unlock()
	if s.running() {
		return nil
	}
	p, err := s.spawn()
	if err != nil {
		return fmt.Errorf("couldn't start codex app-server: %w", err)
	}
	s.mu.Lock()
	old := s.proc
	s.mu.Unlock()
	if old != nil {
		s.exited(old) // dead but its reader hasn't reported it yet
	}
	s.mu.Lock()
	s.proc = p
	s.ready = false
	s.mu.Unlock()
	go s.readLoop(p)
	_, err = s.rawRequest(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "domestique", "title": "Domestique", "version": "0.1.0"},
		"capabilities": map[string]any{"experimentalApi": true},
	})
	if err != nil {
		p.CloseInput()
		p.Terminate()
		return fmt.Errorf("codex app-server didn't initialize: %w", err)
	}
	if err := p.WriteJSON(map[string]any{"method": "initialized"}); err != nil {
		return err
	}
	s.mu.Lock()
	if s.proc == p {
		s.ready = true
	}
	s.mu.Unlock()
	return nil
}

func (s *AppServer) readLoop(p proc) {
	for line := range p.Lines() {
		msg, err := ts.ParseJSON(line)
		if err != nil {
			continue
		}
		s.handle(p, msg)
	}
	<-p.Done()
	s.exited(p)
}

func (s *AppServer) exited(p proc) {
	s.mu.Lock()
	if s.proc != p {
		// Already handled, or shut down.
		s.mu.Unlock()
		return
	}
	s.proc = nil
	s.ready = false
	for id, ch := range s.pending {
		ch <- rpcResult{err: errors.New("codex app-server exited")}
		delete(s.pending, id)
	}
	live := make([]threadHandler, 0, len(s.handlers))
	for _, h := range s.handlers {
		live = append(live, h)
	}
	clear(s.handlers)
	s.mu.Unlock()

	status := p.ExitStatus()
	msg := ""
	if status != 0 {
		trimmed := strings.TrimSpace(p.StderrTail())
		if trimmed == "" {
			msg = fmt.Sprintf("codex exited (%d)", status)
		} else {
			r := []rune(trimmed)
			if len(r) > 2000 {
				r = r[len(r)-2000:]
			}
			msg = string(r)
		}
	}
	for _, h := range live {
		h.serverExited(msg)
	}
}

// Shutdown stops the process.
func (s *AppServer) Shutdown() {
	s.mu.Lock()
	p := s.proc
	s.proc = nil
	s.ready = false
	s.mu.Unlock()
	if p != nil {
		p.CloseInput()
		p.Terminate()
	}
}

// MARK: requests

func (s *AppServer) register(threadID string, h threadHandler) {
	s.mu.Lock()
	s.handlers[threadID] = h
	last := s.lastRate
	s.mu.Unlock()
	if last != nil {
		h.rateLimit(proto.Clone(last).(*radiov1.RateLimit))
	}
}

func (s *AppServer) unregister(threadID string, h threadHandler) {
	s.mu.Lock()
	if s.handlers[threadID] == h {
		delete(s.handlers, threadID)
	}
	s.mu.Unlock()
}

func (s *AppServer) request(ctx context.Context, method string, params any) (ts.JSON, error) {
	if err := s.ensureRunning(ctx); err != nil {
		return ts.JSON{}, err
	}
	return s.rawRequest(ctx, method, params)
}

func (s *AppServer) rawRequest(ctx context.Context, method string, params any) (ts.JSON, error) {
	s.mu.Lock()
	p := s.proc
	if p == nil {
		s.mu.Unlock()
		return ts.JSON{}, errors.New("codex app-server isn't running")
	}
	s.nextID++
	id := s.nextID
	ch := make(chan rpcResult, 1)
	s.pending[id] = ch
	s.mu.Unlock()
	if err := p.WriteJSON(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
		return ts.JSON{}, err
	}
	select {
	case r := <-ch:
		return r.result, r.err
	case <-ctx.Done():
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
		return ts.JSON{}, ctx.Err()
	}
}

// ListModels returns the visible models (cached after the first successful call).
func (s *AppServer) ListModels(ctx context.Context) ([]*radiov1.ModelOption, error) {
	s.mu.Lock()
	cached := s.cachedModels
	s.mu.Unlock()
	if cached != nil {
		return cloneModels(cached), nil
	}
	result, err := s.request(ctx, "model/list", map[string]any{})
	if err != nil {
		return nil, err
	}
	models := ParseModels(result)
	s.mu.Lock()
	s.cachedModels = models
	s.mu.Unlock()
	return cloneModels(models), nil
}

// ParseModels reads a model/list result.
func ParseModels(result ts.JSON) []*radiov1.ModelOption {
	out := []*radiov1.ModelOption{}
	for _, m := range result.Get("data").Arr() {
		if hidden, _ := m.Get("hidden").Bool(); hidden {
			continue
		}
		id, ok := m.Get("id").Str()
		if !ok {
			if id, ok = m.Get("model").Str(); !ok {
				continue
			}
		}
		var efforts []string
		for _, e := range m.Get("supportedReasoningEfforts").Arr() {
			if s, ok := e.Get("reasoningEffort").Str(); ok {
				efforts = append(efforts, s)
			}
		}
		name, ok := m.Get("displayName").Str()
		if !ok {
			name = id
		}
		opt := &radiov1.ModelOption{
			Id: id, DisplayName: name, Description: m.Get("description").S(), Efforts: efforts,
			DefaultEffort: m.Get("defaultReasoningEffort").S(),
		}
		opt.IsDefault, _ = m.Get("isDefault").Bool()
		out = append(out, opt)
	}
	return out
}

func cloneModels(in []*radiov1.ModelOption) []*radiov1.ModelOption {
	out := make([]*radiov1.ModelOption, len(in))
	for i, m := range in {
		out[i] = proto.Clone(m).(*radiov1.ModelOption)
	}
	return out
}

// RateLimit parses an account/rateLimits/updated rateLimits object.
func RateLimit(limits ts.JSON) (ts.RateLimitInfo, bool) {
	var windows []ts.RateLimitWindow
	for _, key := range []string{"primary", "secondary"} {
		w := limits.Get(key)
		pct, ok := w.Get("usedPercent").Float()
		if !ok {
			continue
		}
		mins, known := w.Get("windowDurationMins").Int()
		windows = append(windows, ts.RateLimitWindow{
			ID: key, Label: ts.WindowLabelMinutes(mins, known), Duration: ts.DurationMinutes(mins, known),
			UsedFraction: pct / 100, ResetsAt: ts.UnixSeconds(w.Get("resetsAt")),
		})
	}
	if len(windows) == 0 {
		return ts.RateLimitInfo{}, false
	}
	return ts.RateLimitInfo{Windows: windows, Plan: limits.Get("planType").S()}, true
}

// MARK: inbound

func (s *AppServer) handle(p proc, msg ts.JSON) {
	method, hasMethod := msg.Get("method").Str()
	idValue := msg.Get("id")

	if hasMethod && idValue.Exists() {
		// Server -> client request. Approvals can wait on the user for minutes, so never block the reader.
		params := msg.Get("params")
		s.mu.Lock()
		h := s.handlers[params.Get("threadId").S()]
		s.mu.Unlock()
		go func() {
			var result any
			ok := false
			if h != nil {
				result, ok = h.handleServerRequest(method, params)
			}
			if ok {
				_ = p.WriteJSON(map[string]any{"id": idValue.Raw(), "result": result})
			} else {
				_ = p.WriteJSON(map[string]any{"id": idValue.Raw(), "error": map[string]any{"code": -32601, "message": "Unsupported by Domestique"}})
			}
		}()
		return
	}
	if method == "account/rateLimits/updated" {
		info, ok := RateLimit(msg.Path("params", "rateLimits"))
		if !ok {
			return
		}
		s.mu.Lock()
		rl := s.usage.Merge(info, time.Now())
		// Sessions attaching later get every window known so far, not just this update's.
		last := proto.Clone(rl).(*radiov1.RateLimit)
		last.Windows = ts.ProtoWindows(s.usage.Windows)
		s.lastRate = last
		live := make([]threadHandler, 0, len(s.handlers))
		for _, h := range s.handlers {
			live = append(live, h)
		}
		s.mu.Unlock()
		// Account-level: every session on this server reports it.
		for _, h := range live {
			h.rateLimit(proto.Clone(rl).(*radiov1.RateLimit))
		}
		return
	}
	if hasMethod {
		params := msg.Get("params")
		tid, ok := params.Get("threadId").Str()
		if !ok {
			tid = params.Path("thread", "id").S()
		}
		s.mu.Lock()
		h := s.handlers[tid]
		s.mu.Unlock()
		if h != nil {
			h.handleNotification(method, params)
		}
		return
	}
	id, ok := idValue.Int()
	if !ok {
		return
	}
	s.mu.Lock()
	ch, ok := s.pending[id]
	delete(s.pending, id)
	s.mu.Unlock()
	if !ok {
		return
	}
	if e := msg.Get("error"); e.Exists() {
		m, ok := e.Get("message").Str()
		if !ok {
			m = "codex error"
		}
		ch <- rpcResult{err: &RPCError{Message: m}}
		return
	}
	r := msg.Get("result")
	if !r.Exists() {
		r = ts.Of(nil)
	}
	ch <- rpcResult{result: r}
}
