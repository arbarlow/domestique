package lineproc

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func sh(t *testing.T, script string) *Process {
	t.Helper()
	p, err := Start(Options{Path: "/bin/sh", Args: []string{"-c", script}, Dir: t.TempDir(), Env: Environ(nil)})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func waitDone(t *testing.T, p *Process) {
	t.Helper()
	select {
	case <-p.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("process didn't exit")
	}
}

func TestEchoLinesAndExit(t *testing.T) {
	// cat echoes stdin; lines come back in order, empty lines are skipped, a final line without a
	// newline is still delivered.
	p := sh(t, `cat; printf 'tail'; echo oops >&2; exit 3`)
	for _, l := range []string{`{"a":1}`, "", `{"b":2}`} {
		if err := p.Write([]byte(l)); err != nil {
			t.Fatal(err)
		}
	}
	p.CloseInput()
	var got []string
	for line := range p.Lines() {
		got = append(got, string(line))
	}
	waitDone(t, p)
	if strings.Join(got, "|") != `{"a":1}|{"b":2}|tail` {
		t.Fatalf("lines = %q", got)
	}
	if p.ExitStatus() != 3 {
		t.Errorf("status = %d", p.ExitStatus())
	}
	if strings.TrimSpace(p.StderrTail()) != "oops" {
		t.Errorf("stderr = %q", p.StderrTail())
	}
	if p.Running() {
		t.Error("still running")
	}
	if err := p.Write([]byte("x")); err == nil {
		t.Error("write after exit succeeded")
	}
}

func TestHugeLine(t *testing.T) {
	dir := t.TempDir()
	big := bytes.Repeat([]byte("x"), 12<<20) // 12 MB on one line
	path := filepath.Join(dir, "big")
	if err := os.WriteFile(path, append(append([]byte(`{"d":"`), big...), []byte("\"}\nnext\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	p := sh(t, "cat "+path)
	var lens []int
	for line := range p.Lines() {
		lens = append(lens, len(line))
	}
	waitDone(t, p)
	if len(lens) != 2 || lens[0] != len(big)+8 || lens[1] != 4 {
		t.Fatalf("line lengths = %v", lens)
	}
}

func TestWriteJSONNoHTMLEscape(t *testing.T) {
	p := sh(t, "head -n 1")
	if err := p.WriteJSON(map[string]any{"t": "<a&b>", "n": nil}); err != nil {
		t.Fatal(err)
	}
	line := <-p.Lines()
	if string(line) != `{"n":null,"t":"<a&b>"}` {
		t.Fatalf("line = %s", line)
	}
	waitDone(t, p)
}

func TestTerminateKillsProcessGroup(t *testing.T) {
	// The child ignores SIGINT and SIGTERM and spawns a grandchild; Terminate must still end both.
	p := sh(t, `trap '' INT TERM; sleep 60 & echo $!; wait`)
	pidLine := <-p.Lines()
	grandchild, err := strconv.Atoi(string(pidLine))
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	p.Terminate()
	waitDone(t, p)
	if el := time.Since(start); el < time.Second {
		t.Errorf("exited after %v; expected to need SIGKILL", el)
	}
	if p.ExitStatus() != int(syscall.SIGKILL) {
		t.Errorf("status = %d", p.ExitStatus())
	}
	time.Sleep(100 * time.Millisecond)
	if err := syscall.Kill(grandchild, 0); err == nil {
		t.Error("grandchild survived")
	}
}

func TestSigintExitStatus(t *testing.T) {
	p := sh(t, `echo ready; sleep 30`)
	<-p.Lines()
	p.Terminate()
	waitDone(t, p)
	if p.ExitStatus() != int(syscall.SIGINT) {
		t.Errorf("status = %d, want %d", p.ExitStatus(), syscall.SIGINT)
	}
}

func TestSlowConsumerDoesNotBlockChild(t *testing.T) {
	// The child writes far more than a pipe buffer before reading stdin; with no consumer reading
	// Lines(), it must still get to read our write and exit.
	p := sh(t, `i=0; while [ $i -lt 5000 ]; do echo "line $i padding padding padding padding"; i=$((i+1)); done; read x; echo "got $x"`)
	time.Sleep(200 * time.Millisecond)
	if err := p.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	waitDone(t, p)
	var last string
	n := 0
	for l := range p.Lines() {
		last = string(l)
		n++
	}
	if n != 5001 || last != "got hello" {
		t.Fatalf("n=%d last=%q", n, last)
	}
}

func TestEnviron(t *testing.T) {
	t.Setenv("CLAUDECODE", "1")
	env := Environ(map[string]string{"DOMESTIQUE_PORT": "4100"})
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	if m["DOMESTIQUE_PORT"] != "4100" {
		t.Error("extra env missing")
	}
	if _, ok := m["CLAUDECODE"]; ok {
		t.Error("CLAUDECODE leaked")
	}
	if !strings.Contains(m["PATH"], "/opt/homebrew/bin") || !strings.HasPrefix(m["PATH"], os.Getenv("PATH")) {
		t.Errorf("PATH = %q", m["PATH"])
	}
}

func TestLookPath(t *testing.T) {
	if p, err := LookPath("", "sh"); err != nil || !filepath.IsAbs(p) {
		t.Errorf("sh: %q %v", p, err)
	}
	if p, err := LookPath("/bin/sh", "claude"); err != nil || p != "/bin/sh" {
		t.Errorf("explicit: %q %v", p, err)
	}
	if _, err := LookPath("", "definitely-not-a-binary-xyz"); err == nil {
		t.Error("expected not found")
	}
	if !versionLess("v9.1.0", "v22.14.0") || versionLess("v22.14.0", "v22.2.0") {
		t.Error("versionLess")
	}
}

func TestQueueOrderAndClose(t *testing.T) {
	q := NewQueue[int]()
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				q.Push(i)
			}
		}()
	}
	wg.Wait()
	q.Close()
	q.Close()
	q.Push(99) // dropped after close, must not panic
	n := 0
	for range q.Out() {
		n++
	}
	if n != 4000 {
		t.Fatalf("got %d items", n)
	}
}

func TestQueuePreservesOrder(t *testing.T) {
	q := NewQueue[int]()
	for i := 0; i < 10000; i++ {
		q.Push(i)
	}
	q.Close()
	want := 0
	for v := range q.Out() {
		if v != want {
			t.Fatalf("got %d want %d", v, want)
		}
		want++
	}
}
