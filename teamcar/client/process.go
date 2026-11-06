package client

import (
	"context"
	"errors"
	"sync"
	"syscall"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

var (
	// ErrProcessLost: the connection dropped while the process ran. The server hung it up; it is
	// never restarted on reconnect (that would run the command again).
	ErrProcessLost = errors.New("teamcar: connection lost; the process was hung up")
	// ErrProcessClosed: Close was called before the process exited.
	ErrProcessClosed = errors.New("teamcar: process closed")
)

const (
	// Input is sent in chunks of at most this size...
	inputChunk = 256 << 10
	// ...with at most this many unacknowledged (so Write doesn't wait a round trip per chunk).
	inputWindow = 8
	// Output queued in the client before the connection stops reading (backpressure to the
	// server, and from there to the process).
	outputQueueBytes = 4 << 20
)

// Process is a command running on the Team Car (see StartProcess). It belongs to the client's
// connection: closing the client or losing the connection hangs it up.
type Process struct {
	c   *Client
	sub *Subscription
	id  string
	pid int

	out    chan *radiov1.ProcessOutput
	done   chan struct{}
	closed chan struct{}
	exit   *radiov1.ProcessExited
	err    error

	closeOnce sync.Once
	wmu       sync.Mutex
	window    chan struct{}
	acks      sync.WaitGroup
	werrMu    sync.Mutex
	werr      error
}

// StartProcess runs a command on the Team Car (needs the OPERATE scope) and returns once it has
// started: one Subscribe round trip.
//
// Output must be drained: undelivered output queues in the client up to a few MB, then the whole
// connection stops reading, so the server stops reading the process's pipes and the process blocks
// (as with ssh). Read Output concurrently with any large Write, or a process that echoes its input
// can deadlock both sides.
//
// If the command can't be started (not found, bad cwd), StartProcess still succeeds and Wait
// reports exit code 127 with ProcessExited.Error set; Output is closed at once. Invalid targets
// (argv and shell both set, unknown workspace) and missing scope are returned as errors.
//
// The process is never resumed after a reconnect: Wait returns ErrProcessLost.
func (c *Client) StartProcess(ctx context.Context, t *radiov1.ProcessTarget) (*Process, error) {
	s := newSubscription(c, &radiov1.Subscribe{Target: &radiov1.Subscribe_Process{Process: t}})
	s.noResume, s.maxBytes = true, outputQueueBytes
	if _, err := c.startSub(ctx, s); err != nil {
		return nil, err
	}
	p := &Process{
		c: c, sub: s, out: make(chan *radiov1.ProcessOutput), done: make(chan struct{}),
		closed: make(chan struct{}), window: make(chan struct{}, inputWindow),
	}
	select {
	case ev, ok := <-s.Events():
		switch {
		case !ok:
			return nil, p.endErr()
		case ev.GetProcessStarted() != nil:
			p.id, p.pid = ev.GetProcessStarted().ProcessId, int(ev.GetProcessStarted().Pid)
		case ev.GetProcessExited() != nil:
			s.drop()
			p.exit = ev.GetProcessExited()
			close(p.out)
			close(p.done)
			return p, nil
		default:
			s.Close()
			return nil, errors.New("teamcar: unexpected first process event")
		}
	case <-ctx.Done():
		s.Close()
		return nil, ctx.Err()
	}
	go p.run()
	return p, nil
}

func (p *Process) endErr() error {
	if err := p.sub.Err(); err != nil {
		return err
	}
	return ErrProcessClosed
}

func (p *Process) run() {
	defer close(p.done)
	defer close(p.out)
	for ev := range p.sub.Events() {
		switch {
		case ev.GetProcessOutput() != nil:
			select {
			case p.out <- ev.GetProcessOutput():
			case <-p.closed:
				p.err = ErrProcessClosed
				return
			}
		case ev.GetProcessExited() != nil:
			// The server ends the subscription after the exit.
			p.sub.drop()
			p.exit = ev.GetProcessExited()
			return
		}
	}
	p.err = p.endErr()
}

// ID is the server's process id. Empty when the process never started.
func (p *Process) ID() string { return p.id }

// Pid is the process's pid on the Team Car's host (also its process group id).
func (p *Process) Pid() int { return p.pid }

// Output delivers stdout and stderr chunks in order (in tty mode everything is STDOUT). It is
// closed when the process exits (all its output has been delivered by then) or the stream ends.
func (p *Process) Output() <-chan *radiov1.ProcessOutput { return p.out }

// Done is closed when the process has exited or the stream ended.
func (p *Process) Done() <-chan struct{} { return p.done }

// Wait blocks until the process exits and returns how. It needs Output to be drained. The error is
// set when the stream ended without an exit (ErrProcessLost, ErrProcessClosed, client closed).
func (p *Process) Wait() (*radiov1.ProcessExited, error) {
	<-p.done
	return p.exit, p.err
}

// Write sends data to the process's stdin (the terminal in tty mode). It returns once the data is
// on its way (a few chunks may be unacknowledged); a failure to deliver earlier data is returned by
// a later Write or CloseStdin. data is not retained.
func (p *Process) Write(ctx context.Context, data []byte) error {
	p.wmu.Lock()
	defer p.wmu.Unlock()
	for len(data) > 0 {
		n := min(len(data), inputChunk)
		if err := p.sendInput(ctx, data[:n], false); err != nil {
			return err
		}
		data = data[n:]
	}
	return p.writeErr()
}

// CloseStdin closes the process's stdin after everything written so far, and waits until the
// server has applied it. Ignored by the server in tty mode (a terminal has no EOF; write ^D).
func (p *Process) CloseStdin(ctx context.Context) error {
	p.wmu.Lock()
	defer p.wmu.Unlock()
	if err := p.sendInput(ctx, nil, true); err != nil {
		return err
	}
	acked := make(chan struct{})
	go func() { p.acks.Wait(); close(acked) }()
	select {
	case <-acked:
	case <-ctx.Done():
		return ctx.Err()
	}
	return p.writeErr()
}

func (p *Process) sendInput(ctx context.Context, data []byte, eof bool) error {
	if p.id == "" {
		return errors.New("teamcar: process never started")
	}
	if err := p.writeErr(); err != nil {
		return err
	}
	select {
	case p.window <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	req := &radiov1.Request{Command: &radiov1.Request_ProcessInput{ProcessInput: &radiov1.ProcessInput{
		ProcessId: p.id, Data: data, Eof: eof}}}
	pending, err := p.c.send(ctx, req, nil)
	if err != nil {
		<-p.window
		return err
	}
	p.acks.Add(1)
	go func() {
		defer p.acks.Done()
		// Answered when the server wrote the data, or failed by a disconnect: never hangs.
		_, err := p.c.await(context.Background(), req.Id, pending)
		<-p.window
		if err != nil {
			p.werrMu.Lock()
			if p.werr == nil {
				p.werr = err
			}
			p.werrMu.Unlock()
		}
	}()
	return nil
}

func (p *Process) writeErr() error {
	p.werrMu.Lock()
	defer p.werrMu.Unlock()
	return p.werr
}

// Resize changes the terminal size (tty mode).
func (p *Process) Resize(ctx context.Context, cols, rows uint32) error {
	_, err := p.c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ResizeProcess{ResizeProcess: &radiov1.ResizeProcess{
		ProcessId: p.id, Cols: cols, Rows: rows}}})
	return err
}

// Signal sends a signal to the process's group.
func (p *Process) Signal(ctx context.Context, sig syscall.Signal) error {
	_, err := p.c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_SignalProcess{SignalProcess: &radiov1.SignalProcess{
		ProcessId: p.id, Signal: int32(sig)}}})
	return err
}

// Close hangs the process up (SIGHUP to its group, SIGKILL a few seconds later) unless it already
// exited. Wait then returns ErrProcessClosed.
func (p *Process) Close() {
	p.closeOnce.Do(func() {
		close(p.closed)
		select {
		case <-p.done:
			return
		default:
		}
		p.sub.Close()
	})
}
