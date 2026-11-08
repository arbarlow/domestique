// Package proc runs one process for a remote client, the way sshd runs a session's command: in a
// new session (so it and everything it spawns share one process group), on pipes or a
// pseudo-terminal, with output delivered through a blocking callback (backpressure, never drops).
//
// Lifecycle:
//
//  1. Start launches the process. Output flows to the callback until both pipes (or the pty)
//     reach EOF.
//  2. When the main process exits, its output is drained. If something it started still holds
//     the pipes open after LingerTimeout, the group is hung up so the stream can end.
//  3. Done closes once the main process is reaped and all output is delivered. Whatever is left
//     in the process group is then hung up too: a process lives as long as its session.
//
// Hangup (unsubscribe, disconnect) sends SIGHUP to the group and SIGKILL after KillTimeout if
// anything in it is still alive.
package proc

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// Stream identifies an output stream.
type Stream int

const (
	Stdout Stream = 1
	Stderr Stream = 2
)

// ChunkSize is the largest slice passed to the output callback.
const ChunkSize = 64 << 10

var (
	// KillTimeout is how long a hung-up group has before SIGKILL.
	KillTimeout = 3 * time.Second
	// LingerTimeout is how long output may stay open after the main process exits before the
	// group is hung up (a background job holding stdout).
	LingerTimeout = time.Second
)

// ErrExited is returned by operations on a process that has finished.
var ErrExited = errors.New("process has exited")

// Spec describes what to run.
type Spec struct {
	// Exactly one of Argv (Argv[0] resolved on the PATH of Env) or Shell.
	Argv  []string
	Shell string
	// Working directory (must exist).
	Dir string
	// The complete environment.
	Env []string
	// Run on a pseudo-terminal of Cols x Rows: stdout and stderr merge into Stdout.
	TTY        bool
	Cols, Rows uint16
}

// Exit is how a process ended.
type Exit struct {
	// -1 when killed by a signal.
	Code int
	// The signal that killed it, or 0.
	Signal int
}

// Output receives output chunks (len <= ChunkSize). It may block: the pipe isn't read meanwhile,
// which slows the process down. It's called from one goroutine per stream, so stdout and stderr
// calls can be concurrent. Returning false stops reading that stream (the caller is going away and
// will hang the process up).
type Output func(s Stream, data []byte) bool

// Process is a running process. Methods are safe for concurrent use.
type Process struct {
	cmd  *exec.Cmd
	pgid int
	tty  bool

	stdinMu sync.Mutex
	stdin   *os.File // pipe write end, or the pty master
	ptmx    *os.File

	readers sync.WaitGroup
	exited  chan struct{} // the main process is reaped
	done    chan struct{} // reaped and all output delivered
	exit    Exit

	hangupOnce sync.Once
}

// Shell is the shell Spec.Shell scripts run with: the server user's $SHELL when it's bash, zsh or
// sh (POSIX-compatible, so scripts written for one run on the others), else bash, else sh.
func Shell() string {
	sh := os.Getenv("SHELL")
	for _, ok := range []string{"/bash", "/zsh", "/sh"} {
		if strings.HasSuffix(sh, ok) && filepath.IsAbs(sh) {
			if _, err := os.Stat(sh); err == nil {
				return sh
			}
		}
	}
	if _, err := os.Stat("/bin/bash"); err == nil {
		return "/bin/bash"
	}
	return "/bin/sh"
}

// LookPath resolves name like a shell would, against the PATH in env (not the server's own).
func LookPath(name string, env []string) (string, error) {
	if name == "" {
		return "", errors.New("empty command")
	}
	if strings.Contains(name, "/") {
		return name, nil
	}
	path := ""
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = v // last one wins, like the kernel's view of a duplicated variable in execve
		}
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			dir = "."
		}
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s: command not found", name)
}

// Start launches the process. A non-nil error means it never started (bad command or cwd).
func Start(spec Spec, out Output) (*Process, error) {
	var argv []string
	switch {
	case len(spec.Argv) > 0 && spec.Shell != "":
		return nil, errors.New("set argv or shell, not both")
	case len(spec.Argv) > 0:
		argv = spec.Argv
	case spec.Shell != "":
		argv = []string{Shell(), "-c", spec.Shell}
	default:
		return nil, errors.New("argv or shell is required")
	}
	path, err := LookPath(argv[0], spec.Env)
	if err != nil {
		return nil, err
	}
	if st, err := os.Stat(spec.Dir); err != nil {
		return nil, fmt.Errorf("cwd: %w", err)
	} else if !st.IsDir() {
		return nil, fmt.Errorf("cwd %s is not a directory", spec.Dir)
	}
	cmd := &exec.Cmd{Path: path, Args: argv, Dir: spec.Dir, Env: spec.Env}
	p := &Process{cmd: cmd, tty: spec.TTY, exited: make(chan struct{}), done: make(chan struct{})}

	if spec.TTY {
		cols, rows := spec.Cols, spec.Rows
		if cols == 0 {
			cols = 80
		}
		if rows == 0 {
			rows = 24
		}
		ptmx, err := pty.StartWithAttrs(cmd, &pty.Winsize{Cols: cols, Rows: rows},
			&syscall.SysProcAttr{Setsid: true, Setctty: true})
		if err != nil {
			return nil, err
		}
		p.ptmx, p.stdin = ptmx, ptmx
		p.readers.Add(1)
		go p.read(ptmx, Stdout, out)
	} else {
		inR, inW, err := os.Pipe()
		if err != nil {
			return nil, err
		}
		outR, outW, err := os.Pipe()
		if err != nil {
			closeAll(inR, inW)
			return nil, err
		}
		errR, errW, err := os.Pipe()
		if err != nil {
			closeAll(inR, inW, outR, outW)
			return nil, err
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, errW
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		err = cmd.Start()
		// The child has its copies; ours would keep the pipes open forever.
		closeAll(inR, outW, errW)
		if err != nil {
			closeAll(inW, outR, errR)
			return nil, err
		}
		p.stdin = inW
		p.readers.Add(2)
		go p.read(outR, Stdout, out)
		go p.read(errR, Stderr, out)
	}
	// Setsid makes the child a session and group leader: its pid is the group id.
	p.pgid = cmd.Process.Pid
	go p.wait()
	return p, nil
}

func closeAll(fs ...*os.File) {
	for _, f := range fs {
		_ = f.Close()
	}
}

func (p *Process) read(f *os.File, s Stream, out Output) {
	defer p.readers.Done()
	defer f.Close()
	for {
		buf := make([]byte, ChunkSize)
		n, err := f.Read(buf)
		if n > 0 && !out(s, buf[:n]) {
			return
		}
		if err != nil {
			// EOF on pipes; EIO on a pty master once every slave fd is closed (Linux).
			return
		}
	}
}

func (p *Process) wait() {
	_ = p.cmd.Wait()
	st := p.cmd.ProcessState
	if ws, ok := st.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		p.exit = Exit{Code: -1, Signal: int(ws.Signal())}
	} else {
		p.exit = Exit{Code: st.ExitCode()}
	}
	close(p.exited)

	drained := make(chan struct{})
	go func() { p.readers.Wait(); close(drained) }()
	select {
	case <-drained:
	case <-time.After(LingerTimeout):
		// Something in the group still holds the output open.
		p.Hangup()
		<-drained
	}
	p.stdinMu.Lock()
	if !p.tty && p.stdin != nil {
		_ = p.stdin.Close()
	}
	p.stdin = nil
	p.stdinMu.Unlock()
	// The pty master is closed by its reader (it's the same file in tty mode).
	close(p.done)
	// The session ends with its leader.
	p.Hangup()
}

// Pid is the main process's pid (and the process group id).
func (p *Process) Pid() int { return p.pgid }

// Done is closed once the main process has exited and all its output was delivered.
func (p *Process) Done() <-chan struct{} { return p.done }

// Exited is closed once the main process has exited (output may still be in flight).
func (p *Process) Exited() <-chan struct{} { return p.exited }

// Exit is valid after Exited is closed.
func (p *Process) Exit() Exit {
	<-p.exited
	return p.exit
}

// Write writes to the process's stdin (the terminal's input in tty mode). It blocks until the
// process has room for the data.
func (p *Process) Write(b []byte) error {
	p.stdinMu.Lock()
	f := p.stdin
	p.stdinMu.Unlock()
	if f == nil {
		select {
		case <-p.done:
			return ErrExited
		default:
			return errors.New("stdin is closed")
		}
	}
	// Not under stdinMu: Write may block for as long as the process doesn't read, and the closer
	// must be able to interrupt it.
	_, err := f.Write(b)
	if errors.Is(err, os.ErrClosed) {
		return ErrExited
	}
	return err
}

// CloseStdin closes the process's stdin so it reads EOF. Ignored in tty mode: a terminal has no
// EOF of its own (send ^D, 0x04, to a program reading the terminal in canonical mode); the
// terminal closes when the process exits.
func (p *Process) CloseStdin() error {
	if p.tty {
		return nil
	}
	p.stdinMu.Lock()
	f := p.stdin
	p.stdin = nil
	p.stdinMu.Unlock()
	if f == nil {
		return nil
	}
	return f.Close()
}

// Resize changes the terminal size (tty mode only). The process group gets SIGWINCH.
func (p *Process) Resize(cols, rows uint16) error {
	if !p.tty {
		return errors.New("not a terminal")
	}
	select {
	case <-p.done:
		return ErrExited
	default:
	}
	return pty.Setsize(p.ptmx, &pty.Winsize{Cols: cols, Rows: rows})
}

// Signal sends sig to the process group.
func (p *Process) Signal(sig syscall.Signal) error {
	select {
	case <-p.exited:
		return ErrExited
	default:
	}
	if err := syscall.Kill(-p.pgid, sig); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}

// Hangup sends SIGHUP to the process group, then SIGKILL after KillTimeout if any of it is still
// alive. It returns at once; the main process is reaped by the process's own goroutine (wait for
// Done). Idempotent.
func (p *Process) Hangup() {
	p.hangupOnce.Do(func() {
		if err := syscall.Kill(-p.pgid, syscall.SIGHUP); errors.Is(err, syscall.ESRCH) {
			return // nothing left
		}
		// Stopped jobs can't act on SIGHUP until continued.
		_ = syscall.Kill(-p.pgid, syscall.SIGCONT)
		go func() {
			deadline := time.Now().Add(KillTimeout)
			for time.Now().Before(deadline) {
				time.Sleep(20 * time.Millisecond)
				// A group is "alive" while any member exists (a reaped-or-not main counts until it's
				// reaped, which our wait goroutine does promptly).
				if errors.Is(syscall.Kill(-p.pgid, 0), syscall.ESRCH) {
					return
				}
			}
			_ = syscall.Kill(-p.pgid, syscall.SIGKILL)
		}()
	})
}
