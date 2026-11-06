package client_test

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/arbarlow/domestique/teamcar/client"
	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

type result struct {
	stdout, stderr string
	exit           *radiov1.ProcessExited
	err            error
}

func run(t *testing.T, c *client.Client, target *radiov1.ProcessTarget) result {
	t.Helper()
	p, err := c.StartProcess(ctx(t), target)
	if err != nil {
		t.Fatalf("start %v: %v", target, err)
	}
	return collect(p)
}

func collect(p *client.Process) result {
	var out, errb bytes.Buffer
	for o := range p.Output() {
		if o.Stream == radiov1.OutputStream_OUTPUT_STREAM_STDERR {
			errb.Write(o.Data)
		} else {
			out.Write(o.Data)
		}
	}
	ex, err := p.Wait()
	return result{out.String(), errb.String(), ex, err}
}

func alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func waitGone(t *testing.T, within time.Duration, pids ...int) {
	t.Helper()
	deadline := time.Now().Add(within)
	for _, pid := range pids {
		for alive(pid) {
			if time.Now().After(deadline) {
				t.Fatalf("pid %d still alive after %v", pid, within)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

// readLine reads output until a full line arrives.
func readLine(t *testing.T, p *client.Process, buf *bytes.Buffer) string {
	t.Helper()
	timeout := time.After(10 * time.Second)
	for {
		if i := bytes.IndexByte(buf.Bytes(), '\n'); i >= 0 {
			line := string(buf.Next(i + 1))
			return strings.TrimRight(line, "\r\n")
		}
		select {
		case o, ok := <-p.Output():
			if !ok {
				t.Fatalf("output ended waiting for a line (have %q)", buf.String())
			}
			buf.Write(o.Data)
		case <-timeout:
			t.Fatalf("no line within 10s (have %q)", buf.String())
		}
	}
}

func TestProcessRuns(t *testing.T) {
	e := newEnv(t)
	c := e.dial()

	r := run(t, c, &radiov1.ProcessTarget{Argv: []string{"echo", "hello", "world"}})
	if r.err != nil || r.exit.ExitCode != 0 || r.stdout != "hello world\n" || r.stderr != "" {
		t.Fatalf("argv run: %+v", r)
	}
	r = run(t, c, &radiov1.ProcessTarget{Shell: "echo out; echo err >&2; echo more; exit 7"})
	if r.err != nil || r.exit.ExitCode != 7 || r.stdout != "out\nmore\n" || r.stderr != "err\n" {
		t.Fatalf("shell run: %+v", r)
	}
	r = run(t, c, &radiov1.ProcessTarget{Shell: "kill -KILL $$"})
	if r.err != nil || r.exit.ExitCode != -1 || r.exit.Signal != 9 {
		t.Fatalf("killed: %+v", r)
	}
	r = run(t, c, &radiov1.ProcessTarget{Argv: []string{"definitely-not-a-command-xyz"}})
	if r.err != nil || r.exit.ExitCode != 127 || !strings.Contains(r.exit.Error, "not found") {
		t.Fatalf("missing command: %+v", r)
	}
	r = run(t, c, &radiov1.ProcessTarget{Argv: []string{"true"}, Cwd: "/does/not/exist"})
	if r.err != nil || r.exit.ExitCode != 127 || r.exit.Error == "" {
		t.Fatalf("missing cwd: %+v", r)
	}
	// PATH lookup uses the process's environment.
	bin := t.TempDir()
	os.WriteFile(filepath.Join(bin, "hello-tc"), []byte("#!/bin/sh\necho from-path\n"), 0o755)
	r = run(t, c, &radiov1.ProcessTarget{Argv: []string{"hello-tc"}, Env: map[string]string{"PATH": bin + ":/usr/bin:/bin"}})
	if r.err != nil || r.stdout != "from-path\n" {
		t.Fatalf("PATH lookup: %+v", r)
	}

	cx := ctx(t)
	for _, bad := range []*radiov1.ProcessTarget{
		{},
		{Argv: []string{"echo"}, Shell: "echo"},
		{Argv: []string{"echo"}, Env: map[string]string{"A=B": "c"}},
	} {
		if _, err := c.StartProcess(cx, bad); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
			t.Fatalf("%v: %v", bad, err)
		}
	}
	if _, err := c.StartProcess(cx, &radiov1.ProcessTarget{WorkspaceId: "nope", Argv: []string{"true"}}); !client.IsNotFound(err) {
		t.Fatalf("unknown workspace: %v", err)
	}
}

func TestProcessLargeOutputBackpressure(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	dir := t.TempDir()
	marker := filepath.Join(dir, "finished")
	const n = 2_500_000 // ~19.4 MB of numbered lines
	p, err := c.StartProcess(ctx(t), &radiov1.ProcessTarget{Cwd: dir,
		Shell: fmt.Sprintf("awk 'BEGIN { for (i = 1; i <= %d; i++) print i }'; echo done >&2; touch finished", n)})
	if err != nil {
		t.Fatal(err)
	}
	var (
		next    = 1
		partial []byte
		total   int
		paused  bool
		stderr  bytes.Buffer
		chunks  int
	)
	for o := range p.Output() {
		if o.Stream == radiov1.OutputStream_OUTPUT_STREAM_STDERR {
			stderr.Write(o.Data)
			continue
		}
		if len(o.Data) > 64<<10 {
			t.Fatalf("chunk of %d bytes", len(o.Data))
		}
		chunks++
		total += len(o.Data)
		partial = append(partial, o.Data...)
		for {
			i := bytes.IndexByte(partial, '\n')
			if i < 0 {
				break
			}
			if got := string(partial[:i]); got != strconv.Itoa(next) {
				t.Fatalf("line %d: got %q", next, got)
			}
			next++
			partial = partial[i+1:]
		}
		if !paused && total > 1<<20 {
			// A slow reader: the process must be held up, not run ahead into an unbounded buffer.
			paused = true
			time.Sleep(500 * time.Millisecond)
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("the process finished while its reader was stalled: output isn't back-pressured")
			}
		}
		if chunks%64 == 0 {
			time.Sleep(time.Millisecond)
		}
	}
	ex, err := p.Wait()
	if err != nil || ex.ExitCode != 0 {
		t.Fatalf("exit %v %v", ex, err)
	}
	if next != n+1 || len(partial) != 0 {
		t.Fatalf("got %d lines (+%d bytes), want %d", next-1, len(partial), n)
	}
	if stderr.String() != "done\n" {
		t.Fatalf("stderr %q", stderr.String())
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("exit arrived before the process finished")
	}
}

func TestProcessStdin(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"cat"}})
	if err != nil {
		t.Fatal(err)
	}
	want := make([]byte, 3<<20+17)
	for i := range want {
		want[i] = byte(i*7 + i/251)
	}
	res := make(chan result, 1)
	go func() { res <- collect(p) }()
	for off := 0; off < len(want); off += 100_000 {
		if err := p.Write(cx, want[off:min(off+100_000, len(want))]); err != nil {
			t.Fatal(err)
		}
	}
	if err := p.CloseStdin(cx); err != nil {
		t.Fatal(err)
	}
	r := <-res
	if r.err != nil || r.exit.ExitCode != 0 {
		t.Fatalf("cat: %+v", r.exit)
	}
	if r.stdout != string(want) {
		t.Fatalf("cat returned %d bytes, want %d (equal prefix: %v)", len(r.stdout), len(want), strings.HasPrefix(string(want), r.stdout))
	}
	// Writing after the process exited fails (and doesn't hang).
	if err := p.Write(cx, []byte("late")); err == nil {
		if err = p.CloseStdin(cx); err == nil {
			t.Fatal("writing to an exited process should fail")
		}
	}

	// A line at a time, with an answer to each.
	p, err = c.StartProcess(cx, &radiov1.ProcessTarget{Shell: `while read -r l; do echo "got $l"; done; echo bye`})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	for _, l := range []string{"a", "b", "c"} {
		if err := p.Write(cx, []byte(l+"\n")); err != nil {
			t.Fatal(err)
		}
		if got := readLine(t, p, &buf); got != "got "+l {
			t.Fatalf("got %q", got)
		}
	}
	if err := p.CloseStdin(cx); err != nil {
		t.Fatal(err)
	}
	if got := readLine(t, p, &buf); got != "bye" {
		t.Fatalf("got %q", got)
	}
	if r := collect(p); r.err != nil || r.exit.ExitCode != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestProcessTTY(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Tty: true, Cols: 120, Rows: 40,
		Shell: `stty size; [ -t 0 ] && echo tty; echo "term=$TERM"; echo err >&2; read x; stty size; echo "read=$x"`})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if got := readLine(t, p, &buf); got != "40 120" {
		t.Fatalf("size %q", got)
	}
	for _, want := range []string{"tty", "term=xterm-256color", "err"} {
		if got := readLine(t, p, &buf); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
	if err := p.Resize(cx, 100, 30); err != nil {
		t.Fatal(err)
	}
	if err := p.Write(cx, []byte("hi\r")); err != nil {
		t.Fatal(err)
	}
	if got := readLine(t, p, &buf); got != "hi" { // the terminal echoes input
		t.Fatalf("echo %q", got)
	}
	if got := readLine(t, p, &buf); got != "30 100" {
		t.Fatalf("size after resize %q", got)
	}
	if got := readLine(t, p, &buf); got != "read=hi" {
		t.Fatalf("got %q", got)
	}
	var rest bytes.Buffer
	for o := range p.Output() {
		if o.Stream != radiov1.OutputStream_OUTPUT_STREAM_STDOUT {
			t.Fatalf("tty output on %v", o.Stream)
		}
		rest.Write(o.Data)
	}
	if ex, err := p.Wait(); err != nil || ex.ExitCode != 0 {
		t.Fatalf("exit %v %v (rest %q)", ex, err, rest.String())
	}
	// Resizing a pipe process is refused.
	p, err = c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"cat"}})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err := p.Resize(cx, 80, 24); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("resize without a tty: %v", err)
	}
}

func TestProcessSignal(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Shell: `trap 'echo got-term; exit 5' TERM; echo ready; while :; do sleep 0.05; done`})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if got := readLine(t, p, &buf); got != "ready" {
		t.Fatalf("got %q", got)
	}
	if err := p.Signal(cx, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if got := readLine(t, p, &buf); got != "got-term" {
		t.Fatalf("got %q", got)
	}
	if r := collect(p); r.err != nil || r.exit.ExitCode != 5 {
		t.Fatalf("%+v", r.exit)
	}

	p, err = c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"sleep", "100"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Signal(cx, syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	if r := collect(p); r.err != nil || r.exit.ExitCode != -1 || r.exit.Signal != int32(syscall.SIGINT) {
		t.Fatalf("%+v", r.exit)
	}
	if err := p.Signal(cx, syscall.SIGINT); err == nil {
		t.Fatal("signalling a finished process should fail")
	}
}

// groupScript starts a background child in the process's group and prints its pid.
const groupScript = `sleep 100 & echo $!; wait`

func TestProcessUnsubscribeKillsGroup(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	p, err := c.StartProcess(ctx(t), &radiov1.ProcessTarget{Shell: groupScript})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	child, err := strconv.Atoi(readLine(t, p, &buf))
	if err != nil {
		t.Fatal(err)
	}
	if !alive(p.Pid()) || !alive(child) {
		t.Fatal("not running")
	}
	p.Close()
	if _, err := p.Wait(); !errors.Is(err, client.ErrProcessClosed) {
		t.Fatalf("wait after close: %v", err)
	}
	waitGone(t, 5*time.Second, p.Pid(), child)
	// The client is still fine.
	if _, err := c.ServerInfo(ctx(t)); err != nil {
		t.Fatal(err)
	}
}

func TestProcessExitHangsUpGroup(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	// The shell exits at once; its background child holds stdout open and would keep the stream
	// open forever. It's hung up shortly after the main process exits.
	start := time.Now()
	p, err := c.StartProcess(ctx(t), &radiov1.ProcessTarget{Shell: `sleep 100 & echo $!`})
	if err != nil {
		t.Fatal(err)
	}
	r := collect(p)
	if r.err != nil || r.exit.ExitCode != 0 {
		t.Fatalf("%+v", r)
	}
	child, _ := strconv.Atoi(strings.TrimSpace(r.stdout))
	waitGone(t, 5*time.Second, child)
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("took %v", d)
	}
}

func TestProcessConnectionDrop(t *testing.T) {
	e := newEnv(t)
	admin := e.dial()
	cx := ctx(t)
	tok, _ := admin.CreateToken(cx, "mac", radiov1.TokenScope_TOKEN_SCOPE_OPERATE)
	px := newProxy(t, e.tcpAddr)
	c, err := client.Dial(cx, "ws://"+px.l.Addr().String(), client.WithToken(tok.Secret), client.WithLogger(quietLog()), client.WithMaxBackoff(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	dir := t.TempDir()
	// The child ignores SIGHUP (nohup), so only the SIGKILL that follows gets rid of it.
	p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Cwd: dir, Shell: `echo run >> runs; nohup sh -c 'touch immune; exec sleep 100' >/dev/null 2>&1 & echo $!; wait`})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	child, err := strconv.Atoi(readLine(t, p, &buf))
	if err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(filepath.Join(dir, "immune")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the child never started")
		}
	}
	px.sever()
	for range p.Output() {
	}
	if _, err := p.Wait(); !errors.Is(err, client.ErrProcessLost) {
		t.Fatalf("wait after a drop: %v", err)
	}
	t0 := time.Now()
	waitGone(t, 8*time.Second, p.Pid(), child)
	if d := time.Since(t0); d < 2*time.Second {
		t.Fatalf("a SIGHUP-immune child died after %v: expected the SIGKILL that follows %v later", d, 3*time.Second)
	}
	// The client reconnects, but never runs the command again.
	if _, err := c.ServerInfo(cx); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if runs, _ := os.ReadFile(filepath.Join(dir, "runs")); string(runs) != "run\n" {
		t.Fatalf("runs = %q", runs)
	}
}

func TestProcessScopes(t *testing.T) {
	e := newEnv(t)
	admin := e.dial()
	cx := ctx(t)
	tcp := "ws://" + e.tcpAddr
	for _, scope := range []radiov1.TokenScope{radiov1.TokenScope_TOKEN_SCOPE_READ, radiov1.TokenScope_TOKEN_SCOPE_TRIGGER} {
		tok, _ := admin.CreateToken(cx, "t", scope)
		c, err := client.Dial(cx, tcp, client.WithToken(tok.Secret), client.WithLogger(quietLog()))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"true"}}); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
			t.Fatalf("%v token starting a process: %v", scope, err)
		}
		for _, cmd := range []*radiov1.Request{
			{Command: &radiov1.Request_ProcessInput{ProcessInput: &radiov1.ProcessInput{ProcessId: "p1", Data: []byte("x")}}},
			{Command: &radiov1.Request_SignalProcess{SignalProcess: &radiov1.SignalProcess{ProcessId: "p1", Signal: 9}}},
			{Command: &radiov1.Request_ResizeProcess{ResizeProcess: &radiov1.ResizeProcess{ProcessId: "p1", Cols: 1, Rows: 1}}},
		} {
			if _, err := c.Do(cx, cmd); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
				t.Fatalf("%v token: %v: %v", scope, cmd, err)
			}
		}
		c.Close()
	}
	tok, _ := admin.CreateToken(cx, "op", radiov1.TokenScope_TOKEN_SCOPE_OPERATE)
	c, err := client.Dial(cx, tcp, client.WithToken(tok.Secret), client.WithLogger(quietLog()))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"cat"}})
	if err != nil {
		t.Fatalf("operate token: %v", err)
	}
	defer p.Close()
	// Process ids belong to the connection that started them.
	for _, cmd := range []*radiov1.Request{
		{Command: &radiov1.Request_ProcessInput{ProcessInput: &radiov1.ProcessInput{ProcessId: p.ID(), Data: []byte("x")}}},
		{Command: &radiov1.Request_SignalProcess{SignalProcess: &radiov1.SignalProcess{ProcessId: p.ID(), Signal: 9}}},
		{Command: &radiov1.Request_ResizeProcess{ResizeProcess: &radiov1.ResizeProcess{ProcessId: p.ID(), Cols: 1, Rows: 1}}},
	} {
		if _, err := admin.Do(cx, cmd); !client.IsNotFound(err) {
			t.Fatalf("another connection: %v: %v", cmd, err)
		}
	}
	if err := p.Write(cx, []byte("still mine\n")); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if got := readLine(t, p, &buf); got != "still mine" {
		t.Fatalf("got %q", got)
	}
}

func TestProcessWorkspace(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	ws, _ := setup(t, e, c)
	os.MkdirAll(filepath.Join(ws.Path, "sub", "dir"), 0o755)
	r := run(t, c, &radiov1.ProcessTarget{WorkspaceId: ws.Id, Cwd: "sub/dir", Env: map[string]string{"FOO": "bar", "DOMESTIQUE_WORKSPACE": "override"},
		Shell: `pwd -P; echo "$DOMESTIQUE_PORT $DOMESTIQUE_PORT_9 $FOO $DOMESTIQUE_WORKSPACE"`})
	if r.err != nil || r.exit.ExitCode != 0 {
		t.Fatalf("%+v", r)
	}
	want := fmt.Sprintf("%s\n%d %d bar override\n", filepath.Join(ws.Path, "sub", "dir"), ws.PortBase, ws.PortBase+9)
	if r.stdout != want {
		t.Fatalf("got %q, want %q", r.stdout, want)
	}
	// Default cwd: the workspace. Without one: the server user's home.
	if r := run(t, c, &radiov1.ProcessTarget{WorkspaceId: ws.Id, Argv: []string{"pwd", "-P"}}); r.stdout != ws.Path+"\n" {
		t.Fatalf("workspace cwd %q", r.stdout)
	}
	home, _ := os.UserHomeDir()
	home, _ = filepath.EvalSymlinks(home)
	if r := run(t, c, &radiov1.ProcessTarget{Argv: []string{"pwd", "-P"}}); r.stdout != home+"\n" {
		t.Fatalf("default cwd %q", r.stdout)
	}
	// The workspace is a git worktree: git runs in it.
	gitEnv := map[string]string{"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
	if r := run(t, c, &radiov1.ProcessTarget{WorkspaceId: ws.Id, Argv: []string{"git", "rev-parse", "--abbrev-ref", "HEAD"}, Env: gitEnv}); r.stdout != ws.Branch+"\n" {
		t.Fatalf("git in the workspace: %+v", r)
	}
}

// TestProcessNoLeaks runs many processes and checks the server's goroutines and children settle.
func TestProcessNoLeaks(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	// Warm up (lazy goroutines in the client and server).
	run(t, c, &radiov1.ProcessTarget{Argv: []string{"true"}})
	time.Sleep(100 * time.Millisecond)
	base := runtime.NumGoroutine()
	for i := range 20 {
		switch i % 4 {
		case 0:
			run(t, c, &radiov1.ProcessTarget{Shell: "echo hi; echo err >&2"})
		case 1:
			run(t, c, &radiov1.ProcessTarget{Tty: true, Argv: []string{"echo", "tty"}})
		case 2:
			p, err := c.StartProcess(cx, &radiov1.ProcessTarget{Argv: []string{"cat"}})
			if err != nil {
				t.Fatal(err)
			}
			_ = p.Write(cx, []byte("x"))
			p.Close()
			<-p.Done()
		case 3:
			run(t, c, &radiov1.ProcessTarget{Argv: []string{"no-such-command-xyz"}})
		}
	}
	deadline := time.Now().Add(10 * time.Second)
	for runtime.NumGoroutine() > base {
		if time.Now().After(deadline) {
			buf := make([]byte, 1<<20)
			t.Fatalf("goroutines: %d, started with %d\n%s", runtime.NumGoroutine(), base, buf[:runtime.Stack(buf, true)])
		}
		time.Sleep(50 * time.Millisecond)
	}
	// No zombies: every child of this (server) process has been reaped.
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,stat=").Output()
	if err != nil {
		t.Skipf("ps: %v", err)
	}
	me := strconv.Itoa(os.Getpid())
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) >= 3 && f[1] == me && strings.HasPrefix(f[2], "Z") {
			t.Fatalf("zombie child: %s", sc.Text())
		}
	}
}
