package radio

import (
	"context"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/proc"
)

const (
	// procCredit caps one process's output chunks queued on the event lane (16 x 64 KB = 1 MB).
	// Past it the process's pipe isn't read, so the process blocks: backpressure, not loss.
	procCredit = 16
	// stdinBacklog caps input queued for a process that isn't reading it.
	stdinBacklog = 16 << 20
)

// procHandle is a process started by this connection.
type procHandle struct {
	id   string
	p    *proc.Process
	conn *conn

	mu     sync.Mutex
	queue  []stdinReq
	queued int
	closed bool
	wake   chan struct{}
}

type stdinReq struct {
	reqID uint64
	data  []byte
	eof   bool
}

// processSpec turns a ProcessTarget into a proc.Spec: argv or shell, cwd, env.
func (c *conn) processSpec(t *radiov1.ProcessTarget) (proc.Spec, *radiov1.Response) {
	bad := func(format string, a ...any) (proc.Spec, *radiov1.Response) {
		return proc.Spec{}, errResponse(radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, format, a...)
	}
	switch {
	case len(t.Argv) > 0 && t.Shell != "":
		return bad("set argv or shell, not both")
	case len(t.Argv) == 0 && t.Shell == "":
		return bad("argv or shell is required")
	case len(t.Argv) > 0 && t.Argv[0] == "":
		return bad("argv[0] is empty")
	}
	home, _ := os.UserHomeDir()
	base := home
	var wsEnv map[string]string
	if t.WorkspaceId != "" {
		path, env, err := c.s.car.WorkspaceEnv(t.WorkspaceId)
		if err != nil {
			return proc.Spec{}, fromError(err)
		}
		base, wsEnv = path, env
	}
	dir := base
	if cwd := t.Cwd; cwd != "" {
		if cwd == "~" || strings.HasPrefix(cwd, "~/") {
			cwd = filepath.Join(home, strings.TrimPrefix(cwd, "~"))
		}
		if filepath.IsAbs(cwd) {
			dir = filepath.Clean(cwd)
		} else {
			dir = filepath.Join(base, cwd)
		}
	}
	env := os.Environ()
	for _, k := range slices.Sorted(maps.Keys(wsEnv)) {
		env = append(env, k+"="+wsEnv[k])
	}
	for _, k := range slices.Sorted(maps.Keys(t.Env)) {
		if k == "" || strings.ContainsAny(k, "=\x00") || strings.Contains(t.Env[k], "\x00") {
			return bad("invalid environment variable %q", k)
		}
		env = append(env, k+"="+t.Env[k])
	}
	if t.Tty && !hasEnv(env, "TERM") {
		env = append(env, "TERM=xterm-256color")
	}
	return proc.Spec{
		Argv: t.Argv, Shell: t.Shell, Dir: dir, Env: dedupeEnv(env), TTY: t.Tty,
		Cols: uint16(min(t.Cols, 65535)), Rows: uint16(min(t.Rows, 65535)),
	}, nil
}

func hasEnv(env []string, key string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			return true
		}
	}
	return false
}

// dedupeEnv keeps the last value of each variable (later layers override earlier ones).
func dedupeEnv(env []string) []string {
	last := map[string]int{}
	for i, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		last[k] = i
	}
	out := make([]string, 0, len(last))
	for i, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if last[k] == i {
			out = append(out, kv)
		}
	}
	return out
}

func (c *conn) subscribeProcess(reqID uint64, t *radiov1.ProcessTarget) {
	spec, errResp := c.processSpec(t)
	if errResp != nil {
		c.respond(reqID, errResp)
		return
	}
	id, ctx := c.addSub()
	c.respond(reqID, &radiov1.Response{Result: &radiov1.Response_Subscribe{Subscribe: &radiov1.SubscribeResult{SubscriptionId: id}}})
	go c.runProcess(ctx, id, spec)
}

// runProcess streams one process: ProcessStarted, ProcessOutput..., ProcessExited. The
// subscription ending first (unsubscribe, disconnect) hangs the process up instead.
func (c *conn) runProcess(ctx context.Context, subID uint64, spec proc.Spec) {
	defer c.endSub(subID)
	var (
		seqMu   sync.Mutex
		seq     uint64
		started = make(chan struct{})
		credit  = make(chan struct{}, procCredit)
	)
	// send queues one event; events of one process keep the order they're sent in.
	send := func(ev *radiov1.Event, sent func()) bool {
		seqMu.Lock()
		defer seqMu.Unlock()
		seq++
		ev.SubscriptionId, ev.Seq = subID, seq
		return c.sendEventCtx(ctx, &radiov1.ServerFrame{Frame: &radiov1.ServerFrame_Event{Event: ev}}, sent)
	}
	out := func(s proc.Stream, data []byte) bool {
		select {
		case <-started:
		case <-ctx.Done():
			return false
		}
		select {
		case credit <- struct{}{}:
		case <-ctx.Done():
			return false
		}
		stream := radiov1.OutputStream_OUTPUT_STREAM_STDOUT
		if s == proc.Stderr {
			stream = radiov1.OutputStream_OUTPUT_STREAM_STDERR
		}
		return send(&radiov1.Event{Payload: &radiov1.Event_ProcessOutput{ProcessOutput: &radiov1.ProcessOutput{Stream: stream, Data: data}}},
			func() { <-credit })
	}
	p, err := proc.Start(spec, out)
	if err != nil {
		send(&radiov1.Event{Payload: &radiov1.Event_ProcessExited{ProcessExited: &radiov1.ProcessExited{ExitCode: 127, Error: err.Error()}}}, nil)
		return
	}
	h := &procHandle{id: "p" + strconv.FormatUint(subID, 10), p: p, conn: c, wake: make(chan struct{}, 1)}
	c.subMu.Lock()
	c.procs[h.id] = h
	c.subMu.Unlock()
	defer func() {
		c.subMu.Lock()
		delete(c.procs, h.id)
		c.subMu.Unlock()
		h.close()
	}()
	go h.inputLoop()

	send(&radiov1.Event{Payload: &radiov1.Event_ProcessStarted{ProcessStarted: &radiov1.ProcessStarted{ProcessId: h.id, Pid: int32(p.Pid())}}}, nil)
	close(started)
	c.s.log.Debug("process started", "remote", c.remote, "pid", p.Pid(), "argv", spec.Argv, "tty", spec.TTY)

	select {
	case <-p.Done():
		// Every output chunk was queued before Done; the exit goes after them on the same lane.
		ex := p.Exit()
		send(&radiov1.Event{Payload: &radiov1.Event_ProcessExited{ProcessExited: &radiov1.ProcessExited{
			ExitCode: int32(ex.Code), Signal: int32(ex.Signal)}}}, nil)
	case <-ctx.Done():
		p.Hangup()
		<-p.Done()
	}
}

func (c *conn) process(id string) (*procHandle, *radiov1.Response) {
	c.subMu.Lock()
	h := c.procs[id]
	c.subMu.Unlock()
	if h == nil {
		return nil, errResponse(radiov1.ErrorCode_ERROR_CODE_NOT_FOUND, "no process %q on this connection", id)
	}
	return h, nil
}

// processInput runs on the read loop so input is applied in order. It never blocks on the
// process: input queues (up to stdinBacklog) and is answered once written.
func (c *conn) processInput(reqID uint64, in *radiov1.ProcessInput) {
	if c.scope < radiov1.TokenScope_TOKEN_SCOPE_OPERATE {
		c.respond(reqID, errResponse(radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "this token's scope (%v) doesn't allow this request (needs %v)", c.scope, radiov1.TokenScope_TOKEN_SCOPE_OPERATE))
		return
	}
	h, errResp := c.process(in.ProcessId)
	if errResp != nil {
		c.respond(reqID, errResp)
		return
	}
	h.push(stdinReq{reqID: reqID, data: in.Data, eof: in.Eof})
}

func (h *procHandle) push(r stdinReq) {
	h.mu.Lock()
	switch {
	case h.closed:
		h.mu.Unlock()
		h.conn.respond(r.reqID, errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "process has exited"))
		return
	case h.queued+len(r.data) > stdinBacklog:
		h.mu.Unlock()
		h.conn.respond(r.reqID, errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "the process isn't reading its input (%d bytes queued)", h.queued))
		return
	}
	h.queue = append(h.queue, r)
	h.queued += len(r.data)
	h.mu.Unlock()
	select {
	case h.wake <- struct{}{}:
	default:
	}
}

func (h *procHandle) close() {
	h.mu.Lock()
	h.closed = true
	h.mu.Unlock()
	select {
	case h.wake <- struct{}{}:
	default:
	}
}

// inputLoop writes queued input to the process, answering each request once its data is written.
func (h *procHandle) inputLoop() {
	for {
		h.mu.Lock()
		for len(h.queue) == 0 && !h.closed {
			h.mu.Unlock()
			<-h.wake
			h.mu.Lock()
		}
		if len(h.queue) == 0 {
			h.mu.Unlock()
			return
		}
		r := h.queue[0]
		h.queue[0] = stdinReq{}
		h.queue = h.queue[1:]
		h.queued -= len(r.data)
		closed := h.closed
		h.mu.Unlock()
		if closed {
			h.conn.respond(r.reqID, errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "process has exited"))
			continue
		}
		var err error
		if len(r.data) > 0 {
			err = h.p.Write(r.data)
		}
		if err == nil && r.eof {
			err = h.p.CloseStdin()
		}
		if err != nil {
			h.conn.respond(r.reqID, errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "stdin: %v", err))
			continue
		}
		h.conn.respond(r.reqID, empty())
	}
}

func (c *conn) resizeProcess(r *radiov1.ResizeProcess) *radiov1.Response {
	h, errResp := c.process(r.ProcessId)
	if errResp != nil {
		return errResp
	}
	if r.Cols == 0 || r.Rows == 0 || r.Cols > 65535 || r.Rows > 65535 {
		return errResponse(radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid size %dx%d", r.Cols, r.Rows)
	}
	if err := h.p.Resize(uint16(r.Cols), uint16(r.Rows)); err != nil {
		return errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "resize: %v", err)
	}
	return empty()
}

func (c *conn) signalProcess(r *radiov1.SignalProcess) *radiov1.Response {
	h, errResp := c.process(r.ProcessId)
	if errResp != nil {
		return errResp
	}
	if r.Signal <= 0 || r.Signal > 64 {
		return errResponse(radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid signal %d", r.Signal)
	}
	if err := h.p.Signal(syscall.Signal(r.Signal)); err != nil {
		return errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "signal: %v", err)
	}
	return empty()
}
