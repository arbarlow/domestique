package client_test

import (
	"context"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/arbarlow/domestique/server/client"
	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
	"github.com/arbarlow/domestique/server/internal/agent/fake"
	"github.com/arbarlow/domestique/server/internal/core"
	"github.com/arbarlow/domestique/server/internal/rpc"
	"github.com/arbarlow/domestique/server/internal/store"
)

// env is a running server with a fake agent and a real git origin.
type env struct {
	t        *testing.T
	dir      string
	repoPath string
	st       *store.Store
	server   *core.Server
	unixURL  string
	tcpAddr  string
	cancel   context.CancelFunc
	done     chan struct{}
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	// Ignore the developer's global/system git config (commit signing, hooks, templates).
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func quietLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func newEnv(t *testing.T) *env {
	t.Helper()
	// Short path: Unix socket paths are limited to ~104 bytes on macOS.
	dir, err := os.MkdirTemp("", "tc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	dir, _ = filepath.EvalSymlinks(dir)

	origin := filepath.Join(dir, "origin.git")
	git(t, dir, "init", "--bare", "-b", "main", origin)
	seed := filepath.Join(dir, "seed")
	git(t, dir, "clone", origin, seed)
	os.WriteFile(filepath.Join(seed, "README.md"), []byte("hello\n"), 0o644)
	os.WriteFile(filepath.Join(seed, "domestique.toml"), []byte(`[setup]
script = "echo $DOMESTIQUE_PORT > .port"
copy = [".env"]

[archive]
script = 'touch ../archived-$(basename $PWD)'
`), 0o644)
	git(t, seed, "add", ".")
	git(t, seed, "commit", "-m", "init")
	git(t, seed, "push", "origin", "main")
	repo := filepath.Join(dir, "repo")
	git(t, dir, "clone", origin, repo)
	// Untracked, so only [setup].copy brings it into a worktree.
	os.WriteFile(filepath.Join(repo, ".env"), []byte("SECRET=1\n"), 0o644)

	e := &env{t: t, dir: dir, repoPath: repo}
	e.start()
	t.Cleanup(e.stop)
	return e
}

func (e *env) start() {
	t := e.t
	st, err := store.Open(filepath.Join(e.dir, "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	reg := agent.NewRegistry()
	fake.Register(reg)
	server, err := core.New(core.Options{
		Name: "test-server", Version: "test", Store: st, Agents: reg, Log: quietLog(),
		WorkspacesRoot: filepath.Join(e.dir, "ws"), ReposRoot: filepath.Join(e.dir, "repos"), BranchPrefix: "tc",
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := rpc.NewServer(server, st, quietLog())
	ctx, cancel := context.WithCancel(context.Background())
	sock := filepath.Join(e.dir, "s.sock")
	os.Remove(sock)
	ul, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	tl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _ = srv.Serve(ctx, ul, true) }()
	go func() { defer wg.Done(); _ = srv.Serve(ctx, tl, false) }()
	go func() { wg.Wait(); close(done) }()
	e.st, e.server, e.cancel, e.done = st, server, cancel, done
	e.unixURL, e.tcpAddr = "unix://"+sock, tl.Addr().String()
}

func (e *env) stop() {
	if e.cancel == nil {
		return
	}
	e.cancel()
	<-e.done
	e.server.Shutdown()
	e.st.Close()
	e.cancel = nil
}

func (e *env) dial(opts ...client.Option) *client.Client {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := client.Dial(ctx, e.unixURL, append([]client.Option{client.WithLogger(quietLog())}, opts...)...)
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { c.Close() })
	return c
}

func ctx(t *testing.T) context.Context {
	c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return c
}

// setup adds the repo and creates a ready workspace with an open session.
func setup(t *testing.T, e *env, c *client.Client) (*domestiquev1.Workspace, *domestiquev1.Session) {
	t.Helper()
	cx := ctx(t)
	repo, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath})
	if err != nil {
		t.Fatal(err)
	}
	ws, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id})
	if err != nil {
		t.Fatal(err)
	}
	if ws, err = c.WaitWorkspace(cx, ws.Id); err != nil {
		t.Fatal(err)
	}
	r, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id})
	if err != nil {
		t.Fatal(err)
	}
	return ws, r
}

func TestEndToEnd(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)

	if w := c.Welcome(); w.Scope != domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN || w.ServerName != "test-server" {
		t.Fatalf("welcome = %v", w)
	}
	repo, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath})
	if err != nil {
		t.Fatal(err)
	}
	if repo.DefaultBranch != "main" {
		t.Fatalf("default branch %q", repo.DefaultBranch)
	}
	again, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath + "/"})
	if err != nil || again.Id != repo.Id {
		t.Fatalf("re-adding should return the same repo: %v %v", again, err)
	}

	// Create with a first prompt: the session exists right away and gets the prompt once ready.
	ws, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id, Prompt: "first task"})
	if err != nil {
		t.Fatal(err)
	}
	if ws.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_CREATING || !strings.HasPrefix(ws.Branch, "tc/") {
		t.Fatalf("new workspace = %v", ws)
	}
	if ws, err = c.WaitWorkspace(cx, ws.Id); err != nil {
		t.Fatal(err)
	}
	port, _ := os.ReadFile(filepath.Join(ws.Path, ".port"))
	if strings.TrimSpace(string(port)) == "" || ws.PortBase < 41000 {
		t.Fatalf("setup script didn't run with DOMESTIQUE_PORT (port file %q, base %d)", port, ws.PortBase)
	}
	sessions, err := c.Sessions(cx, ws.Id)
	if err != nil || len(sessions) != 1 {
		t.Fatalf("sessions = %v, %v", sessions, err)
	}
	session := sessions[0]

	// Wait for the first turn by subscribing from 0: the replay covers whatever already happened.
	sub, err := c.SubscribeSession(cx, session.Id, client.SessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	tr := client.NewTranscript()
	waitFor(t, sub, tr, func(ev *domestiquev1.Event) bool {
		return hasTurnSummary(tr)
	})
	sub.Close()
	if got := tr.LastAssistantText(); got != "echo: first task" {
		t.Fatalf("assistant text = %q", got)
	}

	// Prompt a follow-up and get the finished turn.
	turn, err := c.Prompt(cx, session.Id, "second", client.PromptOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if turn.Text != "echo: second" || turn.Summary == nil {
		t.Fatalf("turn = %+v", turn)
	}
	if turn.Summary.GetCostUsd() < 0.0099 || turn.Summary.GetCostUsd() > 0.0101 {
		t.Fatalf("per-turn cost should be the delta of the cumulative cost, got %v", turn.Summary.GetCostUsd())
	}

	// The persisted transcript matches.
	full, err := c.Transcript(cx, session.Id)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, it := range full.Items {
		switch it.Kind.(type) {
		case *domestiquev1.TranscriptItem_User:
			kinds = append(kinds, "user")
		case *domestiquev1.TranscriptItem_Assistant:
			kinds = append(kinds, "assistant")
		case *domestiquev1.TranscriptItem_Tool:
			kinds = append(kinds, "tool")
		case *domestiquev1.TranscriptItem_TurnSummary:
			kinds = append(kinds, "turn")
		}
	}
	want := "user assistant tool turn user assistant tool turn"
	if strings.Join(kinds, " ") != want {
		t.Fatalf("transcript kinds = %v, want %v", kinds, want)
	}
	if full.Item("msg-2").GetAssistant() != "echo: second" {
		t.Fatalf("streamed text wasn't persisted: %q", full.Item("msg-2").GetAssistant())
	}

	sessions, _ = c.Sessions(cx, ws.Id)
	if sessions[0].Title != "first task" || sessions[0].ProviderSessionId == "" {
		t.Fatalf("session meta = %v", sessions[0])
	}

	// Code: diff, files, read, and no path escapes.
	os.WriteFile(filepath.Join(ws.Path, "new.txt"), []byte("a\nb\n"), 0o644)
	os.WriteFile(filepath.Join(ws.Path, "README.md"), []byte("hello\nworld\n"), 0o644)
	d, err := c.Diff(cx, ws.Id, "")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]*domestiquev1.FileDiff{}
	for _, f := range d.Files {
		got[f.Path] = f
	}
	if f := got["new.txt"]; f == nil || f.Status != domestiquev1.FileDiffStatus_FILE_DIFF_STATUS_ADDED || f.Additions != 2 {
		t.Fatalf("new.txt diff = %v", f)
	}
	if f := got["README.md"]; f == nil || f.Additions != 1 || !strings.Contains(f.Patch, "+world") {
		t.Fatalf("README diff = %v", f)
	}
	files, err := c.Files(cx, ws.Id)
	if err != nil || !contains(files, "README.md") || !contains(files, "new.txt") {
		t.Fatalf("files = %v %v", files, err)
	}
	fc, err := c.ReadFile(cx, ws.Id, "README.md", 0)
	if err != nil || string(fc.Data) != "hello\nworld\n" {
		t.Fatalf("read = %v %v", fc, err)
	}
	os.Symlink("/etc", filepath.Join(ws.Path, "escape"))
	if _, err := c.ReadFile(cx, ws.Id, "escape/hosts", 0); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("symlink escape should be refused, got %v", err)
	}
	if _, err := c.ReadFile(cx, ws.Id, "../../../../etc/hosts", 0); err == nil {
		t.Fatal("dot-dot escape should fail")
	}

	if env, _ := os.ReadFile(filepath.Join(ws.Path, ".env")); string(env) != "SECRET=1\n" {
		t.Fatalf("[setup].copy didn't copy .env: %q", env)
	}

	// Archive runs the archive script and removes the worktree.
	if _, err := c.ArchiveWorkspace(cx, ws.Id, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(ws.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree still exists: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(ws.Path), "archived-"+ws.Name)); err != nil {
		t.Fatalf("archive script didn't run: %v", err)
	}
	if out := git(t, e.repoPath, "branch", "--list", ws.Branch); out != "" {
		t.Fatalf("branch not deleted: %q", out)
	}
}

func TestResumeFromCursor(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	_, session := setup(t, e, c)
	if _, err := c.Prompt(cx, session.Id, "one", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
	sub, err := c.SubscribeSession(cx, session.Id, client.SessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	tr := client.NewTranscript()
	waitFor(t, sub, tr, func(ev *domestiquev1.Event) bool { return ev.GetReplayDone() != nil })
	cursor := sub.LastSeq()
	sub.Close()
	if cursor == 0 {
		t.Fatal("expected a cursor")
	}

	if _, err := c.Prompt(cx, session.Id, "two", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
	sub, err = c.SubscribeSession(cx, session.Id, client.SessionOptions{FromSeq: cursor})
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	var replayed []string
	waitFor(t, sub, tr, func(ev *domestiquev1.Event) bool {
		if it := ev.GetItemUpserted(); it != nil {
			replayed = append(replayed, it.Id)
		}
		return ev.GetReplayDone() != nil
	})
	for _, id := range replayed {
		if id == "msg-1" || id == "tool-1" {
			t.Fatalf("replay from cursor %d resent old item %s (%v)", cursor, id, replayed)
		}
	}
	if tr.Item("msg-2").GetAssistant() != "echo: two" || tr.Item("msg-1").GetAssistant() != "echo: one" {
		t.Fatalf("folded transcript wrong: %v", tr.Items)
	}
}

func TestApprovalFlow(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	_, session := setup(t, e, c)

	server, err := c.SubscribeServer(cx)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	sawAwaiting := make(chan struct{})
	go func() {
		for ev := range server.Events() {
			if r := ev.GetSessionUpserted(); r != nil && r.Id == session.Id && r.Activity == domestiquev1.SessionActivity_SESSION_ACTIVITY_AWAITING_INPUT {
				close(sawAwaiting)
				return
			}
		}
	}()

	var asked *domestiquev1.ApprovalRequest
	turn, err := c.Prompt(cx, session.Id, "ask: delete build", client.PromptOptions{
		OnApproval: func(a *domestiquev1.ApprovalRequest) domestiquev1.Decision {
			asked = a
			select {
			case <-sawAwaiting:
			case <-time.After(5 * time.Second):
				t.Error("session never reported awaiting input")
			}
			return domestiquev1.Decision_DECISION_APPROVE
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if asked == nil || asked.Title != "Run rm -rf build?" {
		t.Fatalf("approval = %v", asked)
	}
	var final *domestiquev1.ApprovalRequest
	for _, it := range turn.Items {
		if a := it.GetApproval(); a != nil {
			final = a
		}
	}
	if final == nil || final.Resolution != domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED {
		t.Fatalf("final approval = %v", final)
	}
}

func TestTokensAndScopes(t *testing.T) {
	e := newEnv(t)
	admin := e.dial()
	cx := ctx(t)
	_, session := setup(t, e, admin)

	tcp := "ws://" + e.tcpAddr
	if _, err := client.Dial(cx, tcp, client.WithoutReconnect()); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		t.Fatalf("TCP without token: %v", err)
	}
	if _, err := client.Dial(cx, tcp, client.WithToken("dq_nope"), client.WithoutReconnect()); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		t.Fatalf("TCP with bad token: %v", err)
	}

	read, err := admin.CreateToken(cx, "watcher", domestiquev1.TokenScope_TOKEN_SCOPE_READ)
	if err != nil {
		t.Fatal(err)
	}
	rc, err := client.Dial(cx, tcp, client.WithToken(read.Secret), client.WithLogger(quietLog()))
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	if rc.Welcome().Scope != domestiquev1.TokenScope_TOKEN_SCOPE_READ {
		t.Fatalf("scope = %v", rc.Welcome().Scope)
	}
	if _, err := rc.Transcript(cx, session.Id); err != nil {
		t.Fatalf("read token should read transcripts: %v", err)
	}
	if err := rc.Send(cx, session.Id, "hi", nil); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("read token sending: %v", err)
	}

	trig, _ := admin.CreateToken(cx, "ci", domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER)
	tc, err := client.Dial(cx, tcp, client.WithToken(trig.Secret), client.WithLogger(quietLog()))
	if err != nil {
		t.Fatal(err)
	}
	defer tc.Close()
	if _, err := tc.Prompt(cx, session.Id, "from ci", client.PromptOptions{}); err != nil {
		t.Fatalf("trigger token prompting: %v", err)
	}
	if _, err := tc.CreateToken(cx, "x", domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("trigger token minting tokens: %v", err)
	}
	if err := tc.DeleteWorkspace(cx, "nope", false); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("trigger token deleting a workspace: %v", err)
	}
	// Import is a trigger-level request (this one fails on the missing repository, not the scope).
	if _, err := tc.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{Workspace: &domestiquev1.Workspace{Id: "w", RepositoryId: "nope", Name: "x"}}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("trigger token importing: %v", err)
	}

	if err := admin.RevokeToken(cx, read.Info.Id); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Dial(cx, tcp, client.WithToken(read.Secret), client.WithoutReconnect()); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		t.Fatalf("revoked token: %v", err)
	}
}

func TestIdempotentCreate(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	repo, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath})
	if err != nil {
		t.Fatal(err)
	}
	a, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id}, client.Idempotent("job-42"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id}, client.Idempotent("job-42"))
	if err != nil {
		t.Fatal(err)
	}
	if a.Id != b.Id {
		t.Fatalf("retry created a second workspace: %s vs %s", a.Id, b.Id)
	}
	if _, err := c.WaitWorkspace(cx, a.Id); err != nil {
		t.Fatal(err)
	}
}

// proxy forwards TCP and can sever every connection, to simulate a network drop.
type proxy struct {
	l     net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func newProxy(t *testing.T, target string) *proxy {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &proxy{l: l}
	go func() {
		for {
			in, err := l.Accept()
			if err != nil {
				return
			}
			out, err := net.Dial("tcp", target)
			if err != nil {
				in.Close()
				continue
			}
			p.mu.Lock()
			p.conns = append(p.conns, in, out)
			p.mu.Unlock()
			go func() { io.Copy(out, in); out.Close() }()
			go func() { io.Copy(in, out); in.Close() }()
		}
	}()
	t.Cleanup(func() { l.Close(); p.sever() })
	return p
}

func (p *proxy) sever() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.conns {
		c.Close()
	}
	p.conns = nil
}

func TestReconnectResumesSubscription(t *testing.T) {
	e := newEnv(t)
	admin := e.dial()
	cx := ctx(t)
	_, session := setup(t, e, admin)
	tok, _ := admin.CreateToken(cx, "phone", domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE)

	p := newProxy(t, e.tcpAddr)
	c, err := client.Dial(cx, "ws://"+p.l.Addr().String(), client.WithToken(tok.Secret), client.WithLogger(quietLog()), client.WithMaxBackoff(200*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sub, err := c.SubscribeSession(cx, session.Id, client.SessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()

	// Prompt over the admin connection; the watcher's connection drops mid-stream.
	if err := admin.Send(cx, session.Id, "slow: "+strings.Repeat("x", 200), nil); err != nil {
		t.Fatal(err)
	}
	tr := client.NewTranscript()
	severed := false
	waitFor(t, sub, tr, func(ev *domestiquev1.Event) bool {
		if !severed && ev.GetAppendText() != nil {
			severed = true
			p.sever()
		}
		return hasTurnSummary(tr)
	})
	if !severed {
		t.Fatal("never severed")
	}
	want, err := admin.Transcript(cx, session.Id)
	if err != nil {
		t.Fatal(err)
	}
	if got, exp := tr.Item("msg-1").GetAssistant(), want.Item("msg-1").GetAssistant(); got != exp || !strings.HasPrefix(got, "echo: slow: ") {
		t.Fatalf("after reconnect the folded text differs:\n got %q\nwant %q", got, exp)
	}
}

func TestRestartSettlesInFlightWork(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	_, session := setup(t, e, c)
	sub, err := c.SubscribeSession(cx, session.Id, client.SessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Send(cx, session.Id, "ask: something", nil); err != nil {
		t.Fatal(err)
	}
	tr := client.NewTranscript()
	waitFor(t, sub, tr, func(ev *domestiquev1.Event) bool {
		a := ev.GetItemUpserted().GetApproval()
		return a != nil && a.Resolution == domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING
	})
	c.Close()

	// Simulate a crash: the store remembers an active session with a pending approval.
	e.cancel()
	<-e.done
	e.st.Close() // don't Shutdown the server: an orderly shutdown isn't a crash
	e.cancel = nil
	e.start()

	c2 := e.dial()
	full, err := c2.Transcript(cx, session.Id)
	if err != nil {
		t.Fatal(err)
	}
	ap := full.Item("approval-req-1").GetApproval()
	if ap == nil || ap.Resolution != domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED {
		t.Fatalf("pending approval after restart = %v", ap)
	}
	sessions, _ := c2.Sessions(cx, "")
	if len(sessions) != 1 || sessions[0].Activity != domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE {
		t.Fatalf("sessions after restart = %v", sessions)
	}
	// And the session resumes the provider session on the next message.
	if _, err := c2.Prompt(cx, session.Id, "again", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
}

// ---- helpers

func waitFor(t *testing.T, sub *client.Subscription, tr *client.Transcript, done func(*domestiquev1.Event) bool) {
	t.Helper()
	timeout := time.After(15 * time.Second)
	for {
		select {
		case ev, ok := <-sub.Events():
			if !ok {
				t.Fatalf("subscription ended: %v", sub.Err())
			}
			tr.Apply(ev)
			if done(ev) {
				return
			}
		case <-timeout:
			t.Fatalf("timed out; transcript has %d items", len(tr.Items))
		}
	}
}

func hasTurnSummary(tr *client.Transcript) bool {
	for _, it := range tr.Items {
		if it.GetTurnSummary() != nil {
			return true
		}
	}
	return false
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func TestClientChosenIDs(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	const repoID, wsID, sessionID = "6f1c1b3e-0000-4000-8000-000000000001", "6f1c1b3e-0000-4000-8000-000000000002", "6f1c1b3e-0000-4000-8000-000000000003"

	repo, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath, Id: repoID})
	if err != nil || repo.Id != repoID {
		t.Fatalf("repo = %v, %v", repo, err)
	}
	// Already registered: the id is ignored and the existing repository returned.
	if again, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath, Id: "other"}); err != nil || again.Id != repoID {
		t.Fatalf("re-add = %v, %v", again, err)
	}
	other := filepath.Join(e.dir, "other")
	git(t, e.dir, "clone", filepath.Join(e.dir, "origin.git"), other)
	if _, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: other, Id: repoID}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("taken repo id: %v", err)
	}

	// A session but no prompt: the session is opened anyway, with our id. Setup's script is skipped
	// (the client runs it) but its copies still happen. The branch is ours.
	ws, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{
		RepositoryId: repo.Id, Id: wsID, Branch: "feature/custom", SkipSetup: true,
		Session: &domestiquev1.OpenSession{Id: sessionID, Title: "Mine", WorkspaceId: "ignored"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ws.Id != wsID || ws.Branch != "feature/custom" {
		t.Fatalf("workspace = %v", ws)
	}
	sessions, err := c.Sessions(cx, wsID)
	if err != nil || len(sessions) != 1 || sessions[0].Id != sessionID || sessions[0].Title != "Mine" || sessions[0].WorkspaceId != wsID {
		t.Fatalf("sessions = %v, %v", sessions, err)
	}
	if ws, err = c.WaitWorkspace(cx, wsID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(ws.Path, ".port")); !os.IsNotExist(err) {
		t.Fatalf("skip_setup still ran the setup script: %v", err)
	}
	if env, _ := os.ReadFile(filepath.Join(ws.Path, ".env")); string(env) != "SECRET=1\n" {
		t.Fatalf("skip_setup should still copy files, .env = %q", env)
	}
	if got := git(t, ws.Path, "rev-parse", "--abbrev-ref", "HEAD"); got != "feature/custom" {
		t.Fatalf("worktree branch = %q", got)
	}
	if tr, err := c.Transcript(cx, sessionID); err != nil || len(tr.Items) != 0 {
		t.Fatalf("no prompt was given, transcript = %v, %v", tr, err)
	}

	// Ids already in use are refused, and a refused create leaves nothing behind.
	if _, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id, Id: wsID}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("taken workspace id: %v", err)
	}
	if _, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id, Session: &domestiquev1.OpenSession{Id: sessionID}}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("taken session id in create: %v", err)
	}
	if _, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: wsID, Id: sessionID}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("taken session id: %v", err)
	}
	if _, err := c.CreateWorkspace(cx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id, Branch: "bad..branch"}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("invalid branch: %v", err)
	}
	if all, _ := c.Workspaces(cx, "", true); len(all) != 1 {
		t.Fatalf("refused creates left workspaces behind: %v", all)
	}

	// The session works like any other.
	turn, err := c.Prompt(cx, sessionID, "hi", client.PromptOptions{})
	if err != nil || turn.Text != "echo: hi" {
		t.Fatalf("turn = %+v, %v", turn, err)
	}
}

func TestReopenClosedSessionID(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	ws, _ := setup(t, e, c)
	const id = "9a7d2c10-0000-4000-8000-00000000000a"
	r, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id, Id: id})
	if err != nil || r.Id != id {
		t.Fatalf("session = %v, %v", r, err)
	}
	if _, err := c.Prompt(cx, id, "before", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := c.CloseSession(cx, id); err != nil {
		t.Fatal(err)
	}
	r, err = c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id, Id: id, Title: "Again"})
	if err != nil || r.Id != id || r.LastSeq != 0 || r.ProviderSessionId != "" {
		t.Fatalf("reopened = %v, %v", r, err)
	}
	if tr, err := c.Transcript(cx, id); err != nil || len(tr.Items) != 0 {
		t.Fatalf("reopened session inherited a transcript: %v, %v", tr.Items, err)
	}
	turn, err := c.Prompt(cx, id, "after", client.PromptOptions{})
	if err != nil || turn.Text != "echo: after" {
		t.Fatalf("turn = %+v, %v", turn, err)
	}
	tr, err := c.Transcript(cx, id)
	if err != nil || len(tr.Items) != 4 || tr.Items[0].GetUser() != "after" {
		t.Fatalf("transcript after reopening = %v, %v", tr.Items, err)
	}
}

func TestCloseKeepingHistoryThenReopen(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	ws, _ := setup(t, e, c)
	const id = "9a7d2c10-0000-4000-8000-00000000000b"
	if _, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id, Id: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Prompt(cx, id, "before", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := c.CloseSessionKeepingHistory(cx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Transcript(cx, id); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("closed session is still open: %v", err)
	}
	// Closed sessions stay closed, and reopenable, across a restart.
	e.stop()
	e.start()
	c = e.dial()
	if _, err := c.Transcript(cx, id); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("closed session came back after a restart: %v", err)
	}
	r, err := c.ReopenSession(cx, id)
	if err != nil || r.ClosedAtMs != 0 || r.LastSeq == 0 || r.ProviderSessionId == "" {
		t.Fatalf("reopened = %v, %v", r, err)
	}
	if tr, err := c.Transcript(cx, id); err != nil || len(tr.Items) != 4 || tr.Items[0].GetUser() != "before" {
		t.Fatalf("reopened transcript = %v, %v", tr, err)
	}
	if err := c.CloseSessionKeepingHistory(cx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := c.ArchiveWorkspaceWith(cx, &domestiquev1.ArchiveWorkspace{WorkspaceId: ws.Id, SkipArchiveScript: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.ReopenSession(cx, id); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("closed session survived archiving: %v", err)
	}
}

func TestDeleteWorkspace(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	ws, session := setup(t, e, c)
	if _, err := c.Prompt(cx, session.Id, "hello", client.PromptOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := c.DeleteWorkspace(cx, ws.Id, false); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("deleting a live workspace: %v", err)
	}
	if _, err := c.ArchiveWorkspaceWith(cx, &domestiquev1.ArchiveWorkspace{WorkspaceId: ws.Id, SkipArchiveScript: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(ws.Path), "archived-"+ws.Name)); !os.IsNotExist(err) {
		t.Fatalf("skip_archive_script still ran the archive script: %v", err)
	}
	if out := git(t, e.repoPath, "branch", "--list", ws.Branch); out == "" {
		t.Fatal("archive without delete_branch deleted the branch")
	}

	server, err := c.SubscribeServer(cx)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	if ev := <-server.Events(); ev.GetServerSnapshot() == nil {
		t.Fatalf("first event = %v", ev)
	}
	if err := c.DeleteWorkspace(cx, ws.Id, true); err != nil {
		t.Fatal(err)
	}
	var removed []string
	timeout := time.After(10 * time.Second)
	for len(removed) < 2 {
		select {
		case ev := <-server.Events():
			if id := ev.GetSessionRemoved(); id != "" {
				removed = append(removed, "session "+id)
			}
			if id := ev.GetWorkspaceRemoved(); id != "" {
				removed = append(removed, "workspace "+id)
			}
		case <-timeout:
			t.Fatalf("removals seen: %v", removed)
		}
	}
	if want := []string{"session " + session.Id, "workspace " + ws.Id}; strings.Join(removed, ",") != strings.Join(want, ",") {
		t.Fatalf("removals = %v, want %v", removed, want)
	}
	if out := git(t, e.repoPath, "branch", "--list", ws.Branch); out != "" {
		t.Fatalf("branch not deleted: %q", out)
	}
	if _, err := c.Transcript(cx, session.Id); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("transcript of a deleted session: %v", err)
	}
	if it, err := e.st.Item(session.Id, "msg-1"); it != nil || err != nil {
		t.Fatalf("transcript rows survived: %v %v", it, err)
	}
	if err := c.DeleteWorkspace(cx, ws.Id, false); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("deleting twice: %v", err)
	}

	// Gone for good: not reloaded after a restart.
	c.Close()
	e.stop()
	e.start()
	c = e.dial()
	if all, err := c.Workspaces(cx, "", true); err != nil || len(all) != 0 {
		t.Fatalf("workspaces after restart = %v, %v", all, err)
	}
	if sessions, err := c.Sessions(cx, ""); err != nil || len(sessions) != 0 {
		t.Fatalf("sessions after restart = %v, %v", sessions, err)
	}
}

func TestImportWorkspace(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	cx := ctx(t)
	repo, err := c.AddRepository(cx, &domestiquev1.AddRepository{Path: e.repoPath})
	if err != nil {
		t.Fatal(err)
	}
	// A worktree some client made before it used a server.
	path := filepath.Join(e.dir, "legacy", "tourmalet")
	git(t, e.repoPath, "worktree", "add", "-b", "old/tourmalet", path, "origin/main")
	const wsID, r1, r2 = "11111111-0000-4000-8000-000000000001", "11111111-0000-4000-8000-0000000000a1", "11111111-0000-4000-8000-0000000000a2"
	user := func(id, text string) *domestiquev1.TranscriptItem {
		return &domestiquev1.TranscriptItem{Id: id, TimestampMs: 1000, Kind: &domestiquev1.TranscriptItem_User{User: text}}
	}
	// Ids deliberately not in sort order: display order must come from the request.
	items := []*domestiquev1.TranscriptItem{
		user("z-user", "old question"),
		{Id: "a-reply", TimestampMs: 2000, Kind: &domestiquev1.TranscriptItem_Assistant{Assistant: "old answer"}},
		{Id: "m-tool", TimestampMs: 3000, Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{Name: "Bash", Status: domestiquev1.ToolStatus_TOOL_STATUS_RUNNING}}},
		user("b-user", "second question"),
	}
	req := &domestiquev1.ImportWorkspace{
		Workspace: &domestiquev1.Workspace{
			Id: wsID, RepositoryId: repo.Id, Name: "tourmalet", Branch: "old/tourmalet", Path: path,
			BaseBranch: "main", PortBase: 50000, State: domestiquev1.WorkspaceState_WORKSPACE_STATE_SETTING_UP, CreatedAtMs: 123,
		},
		Sessions: []*domestiquev1.ImportSession{
			{Session: &domestiquev1.Session{Id: r1, Title: "Old chat", Provider: domestiquev1.Provider_PROVIDER_CLAUDE, ProviderSessionId: "sess-old",
				CreatedAtMs: 100, Activity: domestiquev1.SessionActivity_SESSION_ACTIVITY_RUNNING}, Items: items},
			{Session: &domestiquev1.Session{Id: r2, Title: "Empty"}},
		},
	}

	server, err := c.SubscribeServer(cx)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	<-server.Events() // snapshot

	ws, err := c.ImportWorkspace(cx, req)
	if err != nil {
		t.Fatal(err)
	}
	if ws.Id != wsID || ws.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_READY || ws.PortBase != 50000 || ws.CreatedAtMs != 123 || ws.Path != path || ws.Branch != "old/tourmalet" {
		t.Fatalf("imported = %v", ws)
	}
	var published []string
	timeout := time.After(10 * time.Second)
	for len(published) < 3 {
		select {
		case ev := <-server.Events():
			if w := ev.GetWorkspaceUpserted(); w != nil {
				published = append(published, "workspace "+w.Id)
			}
			if r := ev.GetSessionUpserted(); r != nil {
				published = append(published, "session "+r.Id)
			}
		case <-timeout:
			t.Fatalf("published: %v", published)
		}
	}
	if want := []string{"workspace " + wsID, "session " + r1, "session " + r2}; strings.Join(published, ",") != strings.Join(want, ",") {
		t.Fatalf("published = %v, want %v", published, want)
	}

	sessions, err := c.Sessions(cx, wsID)
	if err != nil || len(sessions) != 2 || sessions[0].Id != r1 || sessions[1].Id != r2 {
		t.Fatalf("sessions = %v, %v", sessions, err)
	}
	if m := sessions[0]; m.Title != "Old chat" || m.ProviderSessionId != "sess-old" || m.CreatedAtMs != 100 || m.LastSeq != 4 ||
		m.Activity != domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE || m.PermissionMode != domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS {
		t.Fatalf("imported session = %v", m)
	}
	ids := func(tr *client.Transcript) string {
		var out []string
		for _, it := range tr.Items {
			out = append(out, it.Id)
		}
		return strings.Join(out, " ")
	}
	tr, err := c.Transcript(cx, r1)
	if err != nil || ids(tr) != "z-user a-reply m-tool b-user" {
		t.Fatalf("transcript order = %q, %v", ids(tr), err)
	}
	if tr.Item("z-user").TimestampMs != 1000 || tr.Item("m-tool").GetTool().Status != domestiquev1.ToolStatus_TOOL_STATUS_FAILED {
		t.Fatalf("imported items = %v", tr.Items)
	}
	// A session subscription replays them in the same order.
	sub, err := c.SubscribeSession(cx, r1, client.SessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	replay := client.NewTranscript()
	waitFor(t, sub, replay, func(ev *domestiquev1.Event) bool { return ev.GetReplayDone() != nil })
	sub.Close()
	if ids(replay) != "z-user a-reply m-tool b-user" {
		t.Fatalf("replay order = %q", ids(replay))
	}

	// Idempotent: the existing workspace comes back unchanged and sessions aren't touched.
	again, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{
		Workspace: &domestiquev1.Workspace{Id: wsID, RepositoryId: repo.Id, Name: "renamed"},
		Sessions:  []*domestiquev1.ImportSession{{Session: &domestiquev1.Session{Id: "11111111-0000-4000-8000-0000000000a3"}}},
	})
	if err != nil || again.Name != "tourmalet" || again.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_READY {
		t.Fatalf("re-import = %v, %v", again, err)
	}
	if sessions, _ := c.Sessions(cx, wsID); len(sessions) != 2 {
		t.Fatalf("re-import touched sessions: %v", sessions)
	}

	// The imported session carries on its provider session, after the imported items.
	turn, err := c.Prompt(cx, r1, "carry on", client.PromptOptions{})
	if err != nil || turn.Text != "echo: carry on" {
		t.Fatalf("turn = %+v, %v", turn, err)
	}
	tr, _ = c.Transcript(cx, r1)
	if !strings.HasPrefix(ids(tr), "z-user a-reply m-tool b-user ") || tr.Items[4].GetUser() != "carry on" {
		t.Fatalf("transcript after a prompt = %q", ids(tr))
	}
	if sessions, _ := c.Sessions(cx, wsID); sessions[0].ProviderSessionId != "sess-old" {
		t.Fatalf("provider session = %q", sessions[0].ProviderSessionId)
	}

	// Archived stays archived, even when its worktree is long gone; FAILED keeps its failure.
	const archivedID, r4 = "22222222-0000-4000-8000-000000000001", "22222222-0000-4000-8000-0000000000a4"
	arch, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{
		Workspace: &domestiquev1.Workspace{Id: archivedID, RepositoryId: repo.Id, Name: "gavia", Branch: "old/gavia",
			Path: filepath.Join(e.dir, "does", "not", "exist"), State: domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED},
		Sessions: []*domestiquev1.ImportSession{{Session: &domestiquev1.Session{Id: r4, Provider: domestiquev1.Provider_PROVIDER_CODEX}, Items: []*domestiquev1.TranscriptItem{user("u", "archived chat")}}},
	})
	if err != nil || arch.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		t.Fatalf("archived import = %v, %v", arch, err)
	}
	if live, _ := c.Workspaces(cx, repo.Id, false); len(live) != 1 {
		t.Fatalf("archived import is listed as live: %v", live)
	}
	if tr, err := c.Transcript(cx, r4); err != nil || len(tr.Items) != 1 || tr.Items[0].GetUser() != "archived chat" {
		t.Fatalf("archived transcript = %v, %v", tr, err)
	}
	if _, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: archivedID}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("opening a session in an archived import: %v", err)
	}
	failed, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{Workspace: &domestiquev1.Workspace{
		Id: "33333333-0000-4000-8000-000000000001", RepositoryId: repo.Id, Name: "stelvio",
		State: domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED, Failure: "setup script failed"}})
	if err != nil || failed.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED || failed.Failure != "setup script failed" {
		t.Fatalf("failed import = %v, %v", failed, err)
	}

	// Refusals: unknown repository, a session id in use, duplicate item ids. Nothing is registered.
	if _, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{Workspace: &domestiquev1.Workspace{Id: "x1", RepositoryId: "nope", Name: "x"}}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("unknown repository: %v", err)
	}
	if _, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{Workspace: &domestiquev1.Workspace{Id: "x2", RepositoryId: repo.Id, Name: "x"},
		Sessions: []*domestiquev1.ImportSession{{Session: &domestiquev1.Session{Id: r1}}}}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("session id in use: %v", err)
	}
	if _, err := c.ImportWorkspace(cx, &domestiquev1.ImportWorkspace{Workspace: &domestiquev1.Workspace{Id: "x3", RepositoryId: repo.Id, Name: "x"},
		Sessions: []*domestiquev1.ImportSession{{Session: &domestiquev1.Session{Id: "fresh"}, Items: []*domestiquev1.TranscriptItem{user("d", "1"), user("d", "2")}}}}); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("duplicate item ids: %v", err)
	}
	if all, _ := c.Workspaces(cx, "", true); len(all) != 3 {
		t.Fatalf("workspaces = %v", all)
	}

	// Imports survive a restart, ids and order intact; an archived import can then be deleted.
	c.Close()
	e.stop()
	e.start()
	c = e.dial()
	tr, err = c.Transcript(cx, r1)
	if err != nil || !strings.HasPrefix(ids(tr), "z-user a-reply m-tool b-user ") {
		t.Fatalf("after restart = %q, %v", ids(tr), err)
	}
	if err := c.DeleteWorkspace(cx, archivedID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Transcript(cx, r4); client.Code(err) != domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("deleted archived import's session: %v", err)
	}
}

func TestServerInfoCountsLocalClients(t *testing.T) {
	e := newEnv(t)
	cx := ctx(t)
	first, other := e.dial(), e.dial()
	info, err := first.ServerInfo(cx)
	if err != nil || info.LocalClients != 2 {
		t.Fatalf("with two clients: %v, %v", info, err)
	}
	other.Close()
	deadline := time.Now().Add(5 * time.Second)
	for {
		info, err = first.ServerInfo(cx)
		if err == nil && info.LocalClients == 1 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("after one hung up: %v, %v", info, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
