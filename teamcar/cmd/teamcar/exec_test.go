package main

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/core"
	"github.com/arbarlow/domestique/teamcar/internal/radio"
	"github.com/arbarlow/domestique/teamcar/internal/store"
)

var (
	buildOnce sync.Once
	binPath   string
	buildErr  error
)

// teamcarBinary builds the real binary once per test run.
func teamcarBinary(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "tcbin")
		if err != nil {
			buildErr = err
			return
		}
		binPath = filepath.Join(dir, "teamcar")
		out, err := exec.Command("go", "build", "-o", binPath, ".").CombinedOutput()
		if err != nil {
			buildErr = err
			binPath = string(out)
		}
	})
	if buildErr != nil {
		t.Fatalf("go build: %v\n%s", buildErr, binPath)
	}
	return binPath
}

type execEnv struct {
	home    string // TEAMCAR_HOME for the CLI (no socket in it)
	unixURL string
	tcpURL  string
	token   string // OPERATE
}

func newExecEnv(t *testing.T) *execEnv {
	t.Helper()
	dir, err := os.MkdirTemp("", "tce") // short: Unix socket paths are limited
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	dir, _ = filepath.EvalSymlinks(dir)
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, err := store.Open(filepath.Join(dir, "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	car, err := core.New(core.Options{Name: "exec-test", Version: "test", Store: st, Log: quiet,
		WorkspacesRoot: filepath.Join(dir, "ws"), ReposRoot: filepath.Join(dir, "repos")})
	if err != nil {
		t.Fatal(err)
	}
	_, secret, err := st.CreateToken("exec", radiov1.TokenScope_TOKEN_SCOPE_OPERATE)
	if err != nil {
		t.Fatal(err)
	}
	srv := radio.NewServer(car, st, quiet)
	ctx, cancel := context.WithCancel(context.Background())
	sock := filepath.Join(dir, "s.sock")
	ul, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	tl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _ = srv.Serve(ctx, ul, true) }()
	go func() { defer wg.Done(); _ = srv.Serve(ctx, tl, false) }()
	t.Cleanup(func() { cancel(); wg.Wait(); car.Shutdown(); st.Close() })
	home := filepath.Join(dir, "home")
	os.MkdirAll(home, 0o700)
	return &execEnv{home: home, unixURL: "unix://" + sock, tcpURL: "ws://" + tl.Addr().String(), token: secret}
}

// cli prepares `teamcar exec args...` against the TCP listener with the OPERATE token.
func (e *execEnv) cli(t *testing.T, args ...string) *exec.Cmd {
	cmd := exec.Command(teamcarBinary(t), append([]string{"exec"}, args...)...)
	cmd.Env = append(os.Environ(), "TEAMCAR_HOME="+e.home, "TEAMCAR_URL="+e.tcpURL, "TEAMCAR_TOKEN="+e.token)
	return cmd
}

type cliResult struct {
	stdout, stderr string
	code           int
}

func runCLI(t *testing.T, cmd *exec.Cmd, stdin string) cliResult {
	t.Helper()
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = strings.NewReader(stdin), &out, &errb
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return cliResult{out.String(), errb.String(), code}
}

func TestExecCLI(t *testing.T) {
	e := newExecEnv(t)
	cwd := t.TempDir()
	cwd, _ = filepath.EvalSymlinks(cwd)
	big := strings.Repeat("0123456789abcdef", 1<<16) // 1 MB
	cases := []struct {
		name   string
		args   []string
		stdin  string
		want   cliResult
		errHas string
	}{
		{name: "argv", args: []string{"--", "printf", "%s-%s\n", "a", "b"}, want: cliResult{stdout: "a-b\n"}},
		{name: "argv without --", args: []string{"echo", "hi"}, want: cliResult{stdout: "hi\n"}},
		{name: "streams and exit code", args: []string{"--shell", "echo out; echo err >&2; exit 42"},
			want: cliResult{stdout: "out\n", stderr: "err\n", code: 42}},
		{name: "stdin pipe", args: []string{"--", "tr", "a-z", "A-Z"}, stdin: "hello\nworld\n", want: cliResult{stdout: "HELLO\nWORLD\n"}},
		{name: "big stdin", args: []string{"--shell", "wc -c | tr -d ' '"}, stdin: big, want: cliResult{stdout: strconv.Itoa(len(big)) + "\n"}},
		{name: "empty stdin", args: []string{"--", "cat"}, want: cliResult{}},
		{name: "env and cwd", args: []string{"--cwd", cwd, "--env", "A=1", "--env", "B=two words", "--shell", `echo "$A $B"; pwd -P`},
			want: cliResult{stdout: "1 two words\n" + cwd + "\n"}},
		{name: "killed by a signal", args: []string{"--shell", "kill -TERM $$"}, want: cliResult{code: 128 + 15}},
		{name: "not found", args: []string{"--", "no-such-command-xyz"}, want: cliResult{code: 127}, errHas: "not found"},
		{name: "tty without a terminal", args: []string{"--tty", "--cols", "90", "--rows", "33", "--", "stty", "size"},
			want: cliResult{stdout: "33 90\r\n"}},
		{name: "both shell and argv", args: []string{"--shell", "true", "--", "true"}, want: cliResult{code: 255}, errHas: "not both"},
		{name: "nothing to run", args: nil, want: cliResult{code: 255}, errHas: "nothing to run"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := runCLI(t, e.cli(t, tc.args...), tc.stdin)
			if tc.errHas != "" {
				if !strings.Contains(r.stderr, tc.errHas) {
					t.Fatalf("stderr %q doesn't mention %q", r.stderr, tc.errHas)
				}
				r.stderr = ""
			}
			if r != tc.want {
				t.Fatalf("got %+v, want %+v", r, tc.want)
			}
		})
	}

	t.Run("unix socket", func(t *testing.T) {
		cmd := e.cli(t, "--url", e.unixURL, "--", "echo", "local")
		cmd.Env = append(cmd.Env, "TEAMCAR_TOKEN=") // the socket is trusted
		if r := runCLI(t, cmd, ""); r != (cliResult{stdout: "local\n"}) {
			t.Fatalf("%+v", r)
		}
	})
	t.Run("bad token", func(t *testing.T) {
		cmd := e.cli(t, "--", "echo", "never")
		cmd.Env = append(cmd.Env, "TEAMCAR_TOKEN=tc_wrong")
		r := runCLI(t, cmd, "")
		if r.code != 255 || r.stdout != "" || !strings.Contains(r.stderr, "invalid token") {
			t.Fatalf("%+v", r)
		}
	})
	t.Run("no server", func(t *testing.T) {
		cmd := e.cli(t, "--", "echo", "never")
		cmd.Env = append(cmd.Env, "TEAMCAR_URL=") // falls back to the (absent) local socket
		if r := runCLI(t, cmd, ""); r.code != 255 || r.stderr == "" {
			t.Fatalf("%+v", r)
		}
	})
}

func TestExecCLISignals(t *testing.T) {
	e := newExecEnv(t)

	// SIGTERM to the CLI is forwarded to the remote process group.
	cmd := e.cli(t, "--shell", `trap 'echo bye; exit 3' TERM; echo ready; while :; do sleep 0.05; done`)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	rd := bufio.NewReader(stdout)
	if l, _ := rd.ReadString('\n'); l != "ready\n" {
		t.Fatalf("got %q", l)
	}
	cmd.Process.Signal(syscall.SIGTERM)
	if l, _ := rd.ReadString('\n'); l != "bye\n" {
		t.Fatalf("got %q", l)
	}
	if err := cmd.Wait(); cmd.ProcessState.ExitCode() != 3 {
		t.Fatalf("exit %v", err)
	}

	// Killing the CLI hangs up the remote process: its connection is gone.
	cmd = e.cli(t, "--shell", `sleep 100 & echo $$ $!; wait`)
	stdout, _ = cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	l, _ := bufio.NewReader(stdout).ReadString('\n')
	var pids []int
	for _, f := range strings.Fields(l) {
		pid, err := strconv.Atoi(f)
		if err != nil {
			t.Fatalf("pids %q", l)
		}
		pids = append(pids, pid)
	}
	cmd.Process.Kill()
	cmd.Wait()
	deadline := time.Now().Add(5 * time.Second)
	for _, pid := range pids {
		for syscall.Kill(pid, 0) == nil {
			if time.Now().After(deadline) {
				t.Fatalf("pid %d outlived the CLI", pid)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}
