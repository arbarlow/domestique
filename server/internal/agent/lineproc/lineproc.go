// Package lineproc runs a long-lived child process that speaks newline-delimited JSON on
// stdin/stdout (the agent CLIs' stdio protocols).
//
// Lines are delivered in order on Lines(), which is closed once stdout reaches EOF and every line
// has been received. Stdout is always drained into an unbounded buffer, so a slow consumer never
// back-pressures the child (which could otherwise stop reading stdin and deadlock a writer).
// Done() is closed once the process has been reaped and stdout has reached EOF, so a consumer that
// ranges over Lines() and then waits on Done() sees every line before the exit.
package lineproc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Options describe the process to start.
type Options struct {
	// Path is the absolute path of the executable (see LookPath).
	Path string
	Args []string
	Dir  string
	// Env is the complete environment (see Environ). Nil inherits this process's environment.
	Env []string
}

const stderrKeep = 16 << 10

// Process is a running child. All methods are safe for concurrent use.
type Process struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	lines *Queue[[]byte]
	done  chan struct{}

	writeMu sync.Mutex

	mu         sync.Mutex
	stderrTail []byte
	status     int
	inputDone  bool
	stopOnce   sync.Once
}

// Start launches the process. The child gets its own process group so Terminate/Kill reach any
// grandchildren (tool subprocesses) too.
func Start(opts Options) (*Process, error) {
	cmd := exec.Command(opts.Path, opts.Args...)
	cmd.Dir = opts.Dir
	cmd.Env = opts.Env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		return nil, err
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		stdoutR.Close()
		stdoutW.Close()
		return nil, err
	}
	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	if err := cmd.Start(); err != nil {
		for _, f := range []*os.File{stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW} {
			f.Close()
		}
		return nil, err
	}
	// The child holds its own copies.
	stdinR.Close()
	stdoutW.Close()
	stderrW.Close()

	p := &Process{
		cmd:   cmd,
		stdin: stdinW,
		lines: NewQueue[[]byte](),
		done:  make(chan struct{}),
	}

	stdoutDone := make(chan struct{})
	go func() {
		defer close(stdoutDone)
		defer p.lines.Close()
		readLines(stdoutR, p.lines.Push)
	}()
	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		buf := make([]byte, 8192)
		for {
			n, err := stderrR.Read(buf)
			if n > 0 {
				p.mu.Lock()
				p.stderrTail = append(p.stderrTail, buf[:n]...)
				if len(p.stderrTail) > stderrKeep {
					p.stderrTail = append([]byte(nil), p.stderrTail[len(p.stderrTail)-stderrKeep/2:]...)
				}
				p.mu.Unlock()
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		err := cmd.Wait()
		status := exitStatus(cmd.ProcessState, err)
		// Grandchildren can keep stdout/stderr open after the child exits; give the readers a moment
		// to drain, then force them closed.
		timer := time.NewTimer(2 * time.Second)
		select {
		case <-stdoutDone:
		case <-timer.C:
			stdoutR.Close()
			<-stdoutDone
		}
		timer.Stop()
		select {
		case <-stderrDone:
		case <-time.After(200 * time.Millisecond):
			stderrR.Close()
			<-stderrDone
		}
		stdoutR.Close()
		stderrR.Close()
		p.mu.Lock()

		p.status = status
		p.mu.Unlock()
		p.writeMu.Lock()
		stdinW.Close()
		p.writeMu.Unlock()
		close(p.done)
	}()
	return p, nil
}

// readLines splits r on '\n' with no line length limit and sends each non-empty line.
func readLines(r io.Reader, out func([]byte)) {
	br := bufio.NewReaderSize(r, 256<<10)
	for {
		line, err := br.ReadBytes('\n')
		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(line) > 0 {
			out(line)
		}
		if err != nil {
			return
		}
	}
}

func exitStatus(ps *os.ProcessState, err error) int {
	if ps == nil {
		if err != nil {
			return -1
		}
		return 0
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		// Matches Foundation's terminationStatus for an uncaught signal.
		return int(ws.Signal())
	}
	return ps.ExitCode()
}

// Pid of the child.
func (p *Process) Pid() int { return p.cmd.Process.Pid }

// Lines delivers stdout lines (without the newline). Closed after stdout EOF once drained.
func (p *Process) Lines() <-chan []byte { return p.lines.Out() }

// Done is closed after the process exited and stdout reached EOF.
func (p *Process) Done() <-chan struct{} { return p.done }

// Running reports whether the process has not yet been fully reaped.
func (p *Process) Running() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

// ExitStatus is the exit code, or the signal number if the process was killed by a signal.
// Valid after Done().
func (p *Process) ExitStatus() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.status
}

// StderrTail returns the last few KB the process wrote to stderr.
func (p *Process) StderrTail() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return string(p.stderrTail)
}

// ErrClosed is returned by writes after the input was closed or the process exited.
var ErrClosed = errors.New("lineproc: process input closed")

// Write writes data followed by a newline. Writes are serialised.
func (p *Process) Write(data []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	if p.inputDone || !p.Running() {
		return ErrClosed
	}
	buf := make([]byte, 0, len(data)+1)
	buf = append(buf, data...)
	buf = append(buf, '\n')
	_, err := p.stdin.Write(buf)
	return err
}

// WriteJSON marshals v (without HTML escaping) and writes it as one line.
func (p *Process) WriteJSON(v any) error {
	data, err := MarshalJSON(v)
	if err != nil {
		return err
	}
	return p.Write(data)
}

// MarshalJSON encodes v compactly without HTML escaping.
func MarshalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}

// CloseInput closes the child's stdin.
func (p *Process) CloseInput() {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	if !p.inputDone {
		p.inputDone = true
		p.stdin.Close()
	}
}

// Terminate stops the process group gently: SIGINT (ends a turn cleanly), SIGTERM after 1.5 s,
// SIGKILL after 4 s. Returns immediately.
func (p *Process) Terminate() {
	p.stopOnce.Do(func() {
		if !p.Running() {
			return
		}
		p.signal(syscall.SIGINT)
		go func() {
			select {
			case <-p.done:
				return
			case <-time.After(1500 * time.Millisecond):
			}
			p.signal(syscall.SIGTERM)
			select {
			case <-p.done:
				return
			case <-time.After(2500 * time.Millisecond):
			}
			p.signal(syscall.SIGKILL)
		}()
	})
}

// Kill sends SIGKILL to the process group immediately.
func (p *Process) Kill() { p.signal(syscall.SIGKILL) }

func (p *Process) signal(sig syscall.Signal) {
	if !p.Running() {
		return
	}
	pid := p.cmd.Process.Pid
	if err := syscall.Kill(-pid, sig); err != nil {
		_ = p.cmd.Process.Signal(sig)
	}
}
