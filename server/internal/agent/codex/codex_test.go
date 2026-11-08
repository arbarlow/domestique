package codex

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
	"github.com/arbarlow/domestique/server/internal/agent/lineproc"
	ts "github.com/arbarlow/domestique/server/internal/agent/toolsummary"
)

// fakeServer plays `codex app-server`: it records every message written to it and answers
// requests through handler.
type fakeServer struct {
	mu       sync.Mutex
	written  []ts.JSON
	lines    *lineproc.Queue[[]byte]
	done     chan struct{}
	doneOnce sync.Once
	status   int
	stderr   string
	turns    int
	handler  func(f *fakeServer, method string, params ts.JSON) (result string, rpcErr string)
}

func (f *fakeServer) WriteJSON(v any) error {
	data, err := lineproc.MarshalJSON(v)
	if err != nil {
		return err
	}
	j, _ := ts.ParseJSON(data)
	f.mu.Lock()
	f.written = append(f.written, j)
	h := f.handler
	f.mu.Unlock()
	method, isReq := j.Get("method").Str()
	if id, ok := j.Get("id").Int(); ok && isReq {
		result, rpcErr := `{}`, ""
		if method == "initialize" {
			result = `{"userAgent":"codex"}`
		} else if h != nil {
			result, rpcErr = h(f, method, j.Get("params"))
		}
		if rpcErr != "" {
			f.feed(fmt.Sprintf(`{"id":%d,"error":{"code":-32000,"message":%q}}`, id, rpcErr))
		} else {
			f.feed(fmt.Sprintf(`{"id":%d,"result":%s}`, id, result))
		}
	}
	return nil
}
func (f *fakeServer) CloseInput() {}
func (f *fakeServer) Terminate()  { f.exit(0, "") }
func (f *fakeServer) Running() bool {
	select {
	case <-f.done:
		return false
	default:
		return true
	}
}
func (f *fakeServer) Lines() <-chan []byte  { return f.lines.Out() }
func (f *fakeServer) Done() <-chan struct{} { return f.done }
func (f *fakeServer) ExitStatus() int       { f.mu.Lock(); defer f.mu.Unlock(); return f.status }
func (f *fakeServer) StderrTail() string    { f.mu.Lock(); defer f.mu.Unlock(); return f.stderr }
func (f *fakeServer) feed(lines ...string) {
	for _, l := range lines {
		f.lines.Push([]byte(l))
	}
}
func (f *fakeServer) exit(status int, stderr string) {
	f.doneOnce.Do(func() {
		f.mu.Lock()
		f.status, f.stderr = status, stderr
		f.mu.Unlock()
		f.lines.Close()
		close(f.done)
	})
}

// requests lists "method params" for every request/notification written (initialize excluded).
func (f *fakeServer) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, j := range f.written {
		m, ok := j.Get("method").Str()
		if !ok || m == "initialize" || m == "initialized" {
			continue
		}
		out = append(out, m+" "+j.Get("params").Compact())
	}
	return out
}

// responses lists the replies written to server requests.
func (f *fakeServer) responses() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, j := range f.written {
		if !j.Get("method").Exists() {
			out = append(out, j.Compact())
		}
	}
	return out
}

func newFake(handler func(f *fakeServer, method string, params ts.JSON) (string, string)) (*AppServer, *[]*fakeServer) {
	var mu sync.Mutex
	var spawned []*fakeServer
	srv := newAppServer(func() (proc, error) {
		f := &fakeServer{lines: lineproc.NewQueue[[]byte](), done: make(chan struct{}), handler: handler}
		mu.Lock()
		spawned = append(spawned, f)
		mu.Unlock()
		return f, nil
	})
	return srv, &spawned
}

// standard answers thread/start, thread/resume and turn/start like the real server.
func standard(f *fakeServer, method string, params ts.JSON) (string, string) {
	switch method {
	case "thread/start":
		return `{"thread":{"id":"thr_1"},"model":"gpt-5.5-codex"}`, ""
	case "thread/resume":
		return `{"thread":{"id":"` + params.Get("threadId").S() + `","model":"gpt-5"}}`, ""
	case "turn/start":
		f.mu.Lock()
		f.turns++
		n := f.turns
		f.mu.Unlock()
		return fmt.Sprintf(`{"turn":{"id":"turn_%d","status":"inProgress"}}`, n), ""
	}
	return `{}`, ""
}

func describe(e agent.Event) string {
	switch e := e.(type) {
	case agent.Started:
		return fmt.Sprintf("started %s %s", e.SessionID, e.Model)
	case agent.Upsert:
		return "upsert " + describeItem(e.Item)
	case agent.AppendText:
		return fmt.Sprintf("append %s %q", e.ItemID, e.Delta)
	case agent.TurnStarted:
		return "turnStarted"
	case agent.TurnEnded:
		s := e.Summary
		out := fmt.Sprintf("turnEnded error=%v", s.IsError)
		if s.Message != "" {
			out += fmt.Sprintf(" msg=%q", s.Message)
		}
		if s.InputTokens != nil {
			out += fmt.Sprintf(" in=%d out=%d", *s.InputTokens, *s.OutputTokens)
		}
		if s.DurationMs != nil {
			out += fmt.Sprintf(" ms=%d", *s.DurationMs)
		}
		return out
	case agent.Status:
		return fmt.Sprintf("status %q", e.Text)
	case agent.Exited:
		return fmt.Sprintf("exited %q", e.Message)
	case agent.RateLimit:
		return fmt.Sprintf("rateLimit %s %.2f %d", e.Info.Window, e.Info.UsedFraction, e.Info.ResetsAtMs)
	}
	return fmt.Sprintf("%T", e)
}

func describeItem(it *domestiquev1.TranscriptItem) string {
	id := it.Id
	if i := strings.Index(id, "-"); i > 0 && len(id)-i-1 == 36 {
		id = id[:i] + "-*"
	}
	switch k := it.Kind.(type) {
	case *domestiquev1.TranscriptItem_Assistant:
		return fmt.Sprintf("%s assistant %q", id, k.Assistant)
	case *domestiquev1.TranscriptItem_Reasoning:
		return fmt.Sprintf("%s reasoning %q", id, k.Reasoning)
	case *domestiquev1.TranscriptItem_Notice:
		return fmt.Sprintf("%s notice %q", id, k.Notice)
	case *domestiquev1.TranscriptItem_Error:
		return fmt.Sprintf("%s error %q", id, k.Error)
	case *domestiquev1.TranscriptItem_Tool:
		return fmt.Sprintf("%s tool %s %q %s", id, k.Tool.Name, k.Tool.Summary, strings.TrimPrefix(k.Tool.Status.String(), "TOOL_STATUS_"))
	case *domestiquev1.TranscriptItem_Approval:
		a := k.Approval
		out := fmt.Sprintf("%s approval %q %q %s", id, a.Title, a.Detail, strings.TrimPrefix(a.Resolution.String(), "APPROVAL_RESOLUTION_"))
		for _, q := range a.Questions {
			out += fmt.Sprintf(" q[%s %q %d]", q.Id, q.Question, len(q.Options))
		}
		if len(a.Answers) > 0 {
			out += fmt.Sprintf(" answers=%v", a.Answers)
		}
		return out
	}
	return id
}

func collect(t *testing.T, s agent.Session) []string {
	t.Helper()
	var out []string
	for {
		select {
		case e, ok := <-s.Events():
			if !ok {
				return out
			}
			out = append(out, describe(e))
		case <-time.After(150 * time.Millisecond):
			return out
		}
	}
}

func expect(t *testing.T, what string, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("%s:\n  got:\n    %s\n  want:\n    %s", what, strings.Join(got, "\n    "), strings.Join(want, "\n    "))
	}
}

func TestTurnLifecycle(t *testing.T) {
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w", Model: "gpt-5.5-codex", Effort: "high", AppendSystemPrompt: "be brief"}, srv)
	defer s.Shutdown()
	ctx := context.Background()
	if err := s.Send(ctx, "hi", nil); err != nil {
		t.Fatal(err)
	}
	f := (*spawned)[0]
	f.feed(
		`{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_1"}}}`,
		`{"method":"item/started","params":{"threadId":"thr_1","item":{"type":"userMessage","id":"u1"}}}`,
		`{"method":"item/started","params":{"threadId":"thr_1","item":{"type":"reasoning","id":"rs_1","summary":[]}}}`,
		`{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thr_1","itemId":"rs_1","delta":"Thinking"}}`,
		`{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"thr_1","itemId":"rs_1"}}`,
		`{"method":"item/started","params":{"threadId":"thr_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc ls","status":"inProgress"}}}`,
		`{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_1","itemId":"call_1","delta":"a.txt\n"}}`,
		`{"method":"item/completed","params":{"threadId":"thr_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc ls","status":"completed","exitCode":0}}}`,
		`{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","itemId":"msg_1","delta":"po"}}`,
		`{"method":"item/completed","params":{"threadId":"thr_1","item":{"type":"agentMessage","id":"msg_1","text":"pong"}}}`,
		`{"method":"item/completed","params":{"threadId":"other","item":{"type":"agentMessage","id":"x","text":"not ours"}}}`,
		`{"method":"thread/tokenUsage/updated","params":{"threadId":"thr_1","tokenUsage":{"last":{"inputTokens":120,"outputTokens":7},"total":{"inputTokens":999}}}}`,
		`{"method":"error","params":{"threadId":"thr_1","error":{"message":"stream disconnected"},"willRetry":true}}`,
		`{"method":"error","params":{"threadId":"thr_1","error":{"message":"fatal"},"willRetry":false}}`,
		`{"method":"model/rerouted","params":{"threadId":"thr_1","toModel":"gpt-5-mini"}}`,
		`{"method":"thread/compacted","params":{"threadId":"thr_1"}}`,
		`{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"completed","durationMs":4200}}}`,
	)
	expect(t, "events", collect(t, s), []string{
		"started thr_1 gpt-5.5-codex",
		"turnStarted",
		`upsert rs_1 reasoning ""`,
		`append rs_1 "Thinking"`,
		`append rs_1 "\n\n"`,
		`upsert call_1 tool Bash "ls" RUNNING`,
		`append call_1 "a.txt\n"`,
		`upsert call_1 tool Bash "ls" COMPLETED`,
		`append msg_1 "po"`,
		`upsert msg_1 assistant "pong"`,
		`status "stream disconnected — retrying"`,
		`upsert error-* error "fatal"`,
		`upsert notice-* notice "Model rerouted to gpt-5-mini"`,
		`upsert notice-* notice "Context compacted"`,
		`status ""`,
		"turnEnded error=false in=120 out=7 ms=4200",
	})
	expect(t, "requests", f.requests(), []string{
		`thread/start {"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/w","developerInstructions":"be brief","model":"gpt-5.5-codex","sandbox":"danger-full-access"}`,
		`turn/start {"approvalPolicy":"never","approvalsReviewer":"user","effort":"high","input":[{"text":"hi","text_elements":[],"type":"text"}],"model":"gpt-5.5-codex","sandboxPolicy":{"type":"dangerFullAccess"},"threadId":"thr_1"}`,
	})

	// Interrupted / failed turns.
	if err := s.Send(ctx, "again", nil); err != nil {
		t.Fatal(err)
	}
	s.Interrupt(ctx)
	f.feed(`{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_2","status":"interrupted"}}}`)
	expect(t, "interrupted", collect(t, s), []string{"turnStarted", `status ""`, `turnEnded error=false msg="Interrupted" in=120 out=7`})
	s.Interrupt(ctx) // no turn: no request
	reqs := f.requests()
	if last := reqs[len(reqs)-1]; last != `turn/interrupt {"threadId":"thr_1","turnId":"turn_2"}` {
		t.Errorf("interrupt request %s", last)
	}
	if err := s.Send(ctx, "third", nil); err != nil {
		t.Fatal(err)
	}
	f.feed(`{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_3","status":"failed","error":{"message":"usage limit"}}}}`)
	expect(t, "failed", collect(t, s), []string{"turnStarted", `status ""`, `turnEnded error=true msg="usage limit" in=120 out=7`})
}

func TestSteerAndQueue(t *testing.T) {
	steerFails := false
	srv, spawned := newFake(func(f *fakeServer, method string, params ts.JSON) (string, string) {
		if method == "turn/steer" && steerFails {
			return "", "no active turn"
		}
		return standard(f, method, params)
	})
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w"}, srv)
	defer s.Shutdown()
	ctx := context.Background()
	if err := s.Send(ctx, "one", nil); err != nil {
		t.Fatal(err)
	}
	if err := s.Send(ctx, "two", nil); err != nil {
		t.Fatal(err)
	}
	f := (*spawned)[0]
	reqs := f.requests()
	if len(reqs) != 3 || reqs[2] != `turn/steer {"expectedTurnId":"turn_1","input":[{"text":"two","text_elements":[],"type":"text"}],"threadId":"thr_1"}` {
		t.Fatalf("requests %q", reqs)
	}
	// The turn ended under us: the steer is rejected and the message starts a new turn.
	steerFails = true
	if err := s.Send(ctx, "three", nil); err != nil {
		t.Fatal(err)
	}
	reqs = f.requests()
	if len(reqs) != 5 || !strings.HasPrefix(reqs[3], "turn/steer") || !strings.HasPrefix(reqs[4], "turn/start") || !strings.Contains(reqs[4], `"three"`) {
		t.Fatalf("requests %q", reqs)
	}
	// A completion that races ahead of the turn/start response must not leave a stale turn id.
	s.handleNotification("turn/completed", ts.MustJSON(`{"turn":{"id":"turn_2","status":"completed"}}`))
	s.handleNotification("turn/started", ts.MustJSON(`{"turn":{"id":"turn_2"}}`))
	s.mu.Lock()
	stale := s.turnID
	s.mu.Unlock()
	if stale != "" {
		t.Errorf("stale turn id %q", stale)
	}
}

func TestPermissionModes(t *testing.T) {
	cases := []struct {
		mode                      domestiquev1.PermissionMode
		policy, sandbox, reviewer string
		sandboxPolicy             string
	}{
		{domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS, "never", "danger-full-access", "user", `{"type":"dangerFullAccess"}`},
		{domestiquev1.PermissionMode_PERMISSION_MODE_UNSPECIFIED, "never", "danger-full-access", "user", `{"type":"dangerFullAccess"}`},
		{domestiquev1.PermissionMode_PERMISSION_MODE_AUTO, "on-request", "workspace-write", "auto_review",
			`{"excludeSlashTmp":false,"excludeTmpdirEnvVar":false,"networkAccess":true,"type":"workspaceWrite","writableRoots":["/w","/repo/.git"]}`},
		{domestiquev1.PermissionMode_PERMISSION_MODE_ASK, "on-request", "workspace-write", "user",
			`{"excludeSlashTmp":false,"excludeTmpdirEnvVar":false,"networkAccess":true,"type":"workspaceWrite","writableRoots":["/w","/repo/.git"]}`},
	}
	for _, c := range cases {
		if ApprovalPolicy(c.mode) != c.policy || SandboxMode(c.mode) != c.sandbox || Reviewer(c.mode) != c.reviewer {
			t.Errorf("%v: %s %s %s", c.mode, ApprovalPolicy(c.mode), SandboxMode(c.mode), Reviewer(c.mode))
		}
		got := ts.Of(SandboxPolicy(agent.Config{Cwd: "/w", Mode: c.mode, ExtraWritableRoots: []string{"/repo/.git"}})).Compact()
		if got != c.sandboxPolicy {
			t.Errorf("%v sandboxPolicy %s", c.mode, got)
		}
	}

	// Mode changes apply on the next turn/start.
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w"}, srv)
	defer s.Shutdown()
	ctx := context.Background()
	s.SetPermissionMode(ctx, domestiquev1.PermissionMode_PERMISSION_MODE_ASK)
	s.SetModel(ctx, "o5")
	s.SetEffort(ctx, "low")
	if err := s.Send(ctx, "x", nil); err != nil {
		t.Fatal(err)
	}
	reqs := (*spawned)[0].requests()
	if !strings.Contains(reqs[0], `"approvalPolicy":"on-request"`) || !strings.Contains(reqs[1], `"effort":"low"`) || !strings.Contains(reqs[1], `"model":"o5"`) || !strings.Contains(reqs[1], `"workspaceWrite"`) {
		t.Errorf("requests %q", reqs)
	}
}

func TestResume(t *testing.T) {
	t.Run("resumes the thread", func(t *testing.T) {
		srv, spawned := newFake(standard)
		defer srv.Shutdown()
		s := newSession(agent.Config{Cwd: "/w", ResumeSessionID: "thr_old"}, srv)
		defer s.Shutdown()
		if err := s.Send(context.Background(), "x", nil); err != nil {
			t.Fatal(err)
		}
		reqs := (*spawned)[0].requests()
		if reqs[0] != `thread/resume {"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/w","excludeTurns":true,"sandbox":"danger-full-access","threadId":"thr_old"}` {
			t.Errorf("resume %s", reqs[0])
		}
		expect(t, "events", collect(t, s), []string{"started thr_old gpt-5", "turnStarted"})
	})
	t.Run("starts fresh when the thread is gone", func(t *testing.T) {
		srv, spawned := newFake(func(f *fakeServer, method string, params ts.JSON) (string, string) {
			if method == "thread/resume" {
				return "", "thread not found"
			}
			return standard(f, method, params)
		})
		defer srv.Shutdown()
		s := newSession(agent.Config{Cwd: "/w", ResumeSessionID: "thr_old"}, srv)
		defer s.Shutdown()
		if err := s.Send(context.Background(), "x", nil); err != nil {
			t.Fatal(err)
		}
		reqs := (*spawned)[0].requests()
		if !strings.HasPrefix(reqs[1], "thread/start") || strings.Contains(reqs[1], "thr_old") || strings.Contains(reqs[1], "excludeTurns") {
			t.Errorf("fallback %q", reqs)
		}
		expect(t, "events", collect(t, s), []string{
			`upsert notice-* notice "Couldn't resume previous Codex thread; starting a new one."`,
			"started thr_1 gpt-5.5-codex",
			"turnStarted",
		})
	})
	t.Run("turn/start failure ends the turn", func(t *testing.T) {
		srv, _ := newFake(func(f *fakeServer, method string, params ts.JSON) (string, string) {
			if method == "turn/start" {
				return "", "model not supported"
			}
			return standard(f, method, params)
		})
		defer srv.Shutdown()
		s := newSession(agent.Config{Cwd: "/w"}, srv)
		defer s.Shutdown()
		if err := s.Send(context.Background(), "x", nil); err == nil {
			t.Fatal("expected error")
		}
		expect(t, "events", collect(t, s), []string{"started thr_1 gpt-5.5-codex", "turnStarted", `turnEnded error=true msg="model not supported"`})
	})
}

func TestApprovals(t *testing.T) {
	approve := agent.Decision{Kind: domestiquev1.Decision_DECISION_APPROVE}
	session := agent.Decision{Kind: domestiquev1.Decision_DECISION_APPROVE_FOR_SESSION}
	deny := agent.Decision{Kind: domestiquev1.Decision_DECISION_DENY, Message: "not now"}
	cases := []struct {
		name    string
		method  string
		params  string
		answer  func(s *Session, id string)
		pending string
		final   string
		result  string
	}{
		{
			name: "command accept for session", method: "item/commandExecution/requestApproval",
			params:  `{"threadId":"thr_1","itemId":"call_1","command":"/bin/zsh -lc \"rm -rf x\"","reason":"needs write"}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, session) },
			pending: `approval-codex-1-call_1 approval "Run command?" "rm -rf x\n\nneeds write" PENDING`,
			final:   `approval-codex-1-call_1 approval "Run command?" "rm -rf x\n\nneeds write" APPROVED_FOR_SESSION`,
			result:  `{"decision":"acceptForSession"}`,
		},
		{
			name: "file change decline", method: "item/fileChange/requestApproval",
			params:  `{"threadId":"thr_1","itemId":"fc_1","reason":"edit outside workspace"}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, deny) },
			pending: `approval-codex-1-fc_1 approval "Apply file changes?" "edit outside workspace" PENDING`,
			final:   `approval-codex-1-fc_1 approval "Apply file changes?" "edit outside workspace" DENIED`,
			result:  `{"decision":"decline"}`,
		},
		{
			name: "legacy exec approval with argv", method: "execCommandApproval",
			params:  `{"threadId":"thr_1","command":["git","push"]}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, approve) },
			pending: `approval-codex-1- approval "Run command?" "git push" PENDING`,
			final:   `approval-codex-1- approval "Run command?" "git push" APPROVED`,
			result:  `{"decision":"approved"}`,
		},
		{
			name: "legacy patch denial carries the reason", method: "applyPatchApproval",
			params:  `{"threadId":"thr_1"}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, deny) },
			pending: `approval-codex-1- approval "Apply file changes?" "" PENDING`,
			final:   `approval-codex-1- approval "Apply file changes?" "" DENIED`,
			result:  `{"decision":{"denied":{"rejection":"not now"}}}`,
		},
		{
			name: "permissions granted for the session", method: "item/permissions/requestApproval",
			params:  `{"threadId":"thr_1","itemId":"p","reason":"network","permissions":{"network":true}}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, session) },
			pending: `approval-codex-1-p approval "Grant extra permissions?" "network\n\n{\n  \"network\": true\n}" PENDING`,
			final:   `approval-codex-1-p approval "Grant extra permissions?" "network\n\n{\n  \"network\": true\n}" APPROVED`,
			result:  `{"permissions":{"network":true},"scope":"session"}`,
		},
		{
			name: "permissions denied", method: "item/permissions/requestApproval",
			params:  `{"threadId":"thr_1","itemId":"p"}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, deny) },
			pending: `approval-codex-1-p approval "Grant extra permissions?" "" PENDING`,
			final:   `approval-codex-1-p approval "Grant extra permissions?" "" DENIED`,
			result:  `{"permissions":{},"scope":"turn"}`,
		},
		{
			name: "question answered", method: "item/tool/requestUserInput",
			params:  `{"threadId":"thr_1","itemId":"ui","questions":[{"id":"color","header":"Pick","question":"Which colour?","options":[{"label":"Red"},{"label":"Blue","description":"calm"}]}]}`,
			answer:  func(s *Session, id string) { s.Answer(context.Background(), id, map[string]string{"color": "Blue"}) },
			pending: `approval-codex-1-ui approval "Codex has a question" "" PENDING q[color "Which colour?" 2]`,
			final:   `approval-codex-1-ui approval "Codex has a question" "" ANSWERED q[color "Which colour?" 2] answers=map[color:Blue]`,
			result:  `{"answers":{"color":{"answers":["Blue"]}}}`,
		},
		{
			name: "question dismissed", method: "item/tool/requestUserInput",
			params:  `{"threadId":"thr_1","itemId":"ui","questions":[{"id":"q","question":"?"}]}`,
			answer:  func(s *Session, id string) { s.Respond(context.Background(), id, deny) },
			pending: `approval-codex-1-ui approval "Codex has a question" "" PENDING q[q "?" 0]`,
			final:   `approval-codex-1-ui approval "Codex has a question" "" DENIED q[q "?" 0]`,
			result:  `{"answers":{}}`,
		},
		{
			name: "answers to a yes/no approval decline it", method: "item/commandExecution/requestApproval",
			params:  `{"threadId":"thr_1","itemId":"c","command":"ls"}`,
			answer:  func(s *Session, id string) { s.Answer(context.Background(), id, map[string]string{"x": "y"}) },
			pending: `approval-codex-1-c approval "Run command?" "ls" PENDING`,
			final:   `approval-codex-1-c approval "Run command?" "ls" DENIED`,
			result:  `{"decision":"decline"}`,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv, spawned := newFake(standard)
			defer srv.Shutdown()
			s := newSession(agent.Config{Cwd: "/w"}, srv)
			defer s.Shutdown()
			if err := s.Send(context.Background(), "go", nil); err != nil {
				t.Fatal(err)
			}
			collect(t, s)
			f := (*spawned)[0]
			f.feed(fmt.Sprintf(`{"id":77,"method":%q,"params":%s}`, c.method, c.params))
			expect(t, "pending", collect(t, s), []string{"upsert " + c.pending})
			c.answer(s, strings.TrimPrefix(strings.Fields(c.pending)[0], "approval-"))
			expect(t, "final", collect(t, s), []string{"upsert " + c.final})
			want := fmt.Sprintf(`{"id":77,"result":%s}`, c.result)
			if got := f.responses(); len(got) != 1 || got[0] != want {
				t.Errorf("responses %q\nwant %s", got, want)
			}
		})
	}
}

func TestUnsupportedServerRequests(t *testing.T) {
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w"}, srv)
	defer s.Shutdown()
	if err := s.Send(context.Background(), "go", nil); err != nil {
		t.Fatal(err)
	}
	f := (*spawned)[0]
	f.feed(`{"id":"a","method":"item/tool/call","params":{"threadId":"thr_1"}}`,
		`{"id":5,"method":"item/commandExecution/requestApproval","params":{"threadId":"nobody"}}`)
	time.Sleep(100 * time.Millisecond)
	got := f.responses()
	slices.Sort(got)
	want := []string{
		`{"error":{"code":-32601,"message":"Unsupported by Domestique"},"id":"a"}`,
		`{"error":{"code":-32601,"message":"Unsupported by Domestique"},"id":5}`,
	}
	if !slices.Equal(got, want) {
		t.Errorf("responses %q", got)
	}
}

func TestServerExitAndRestart(t *testing.T) {
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w"}, srv)
	defer s.Shutdown()
	ctx := context.Background()
	if err := s.Send(ctx, "go", nil); err != nil {
		t.Fatal(err)
	}
	f := (*spawned)[0]
	f.feed(`{"id":9,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","itemId":"c","command":"ls"}}`)
	collect(t, s)
	f.exit(1, "panic: thread 'main'\n")
	expect(t, "exit", collect(t, s), []string{
		`turnEnded error=true msg="Codex exited"`,
		`exited "panic: thread 'main'"`,
		`upsert approval-codex-1-c approval "Run command?" "ls" CANCELLED`,
	})
	// Next send starts a new app-server and resumes the thread.
	if err := s.Send(ctx, "again", nil); err != nil {
		t.Fatal(err)
	}
	if len(*spawned) != 2 {
		t.Fatalf("spawned %d", len(*spawned))
	}
	reqs := (*spawned)[1].requests()
	if !strings.HasPrefix(reqs[0], `thread/resume`) || !strings.Contains(reqs[0], `"threadId":"thr_1"`) {
		t.Errorf("restart %q", reqs)
	}
}

func TestRateLimitsAndModels(t *testing.T) {
	srv, spawned := newFake(func(f *fakeServer, method string, params ts.JSON) (string, string) {
		if method == "model/list" {
			return `{"data":[
			  {"id":"gpt-5.5-codex","model":"gpt-5.5-codex","displayName":"GPT-5.5 Codex","description":"Best for code","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}],"defaultReasoningEffort":"high","isDefault":true},
			  {"model":"gpt-5-mini","supportedReasoningEfforts":[]},
			  {"id":"secret","hidden":true}
			]}`, ""
		}
		return standard(f, method, params)
	})
	defer srv.Shutdown()
	ctx := context.Background()
	models, err := srv.ListModels(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].Id != "gpt-5.5-codex" || !models[0].IsDefault || models[0].DefaultEffort != "high" ||
		!slices.Equal(models[0].Efforts, []string{"low", "high"}) || models[1].Id != "gpt-5-mini" || models[1].DisplayName != "gpt-5-mini" {
		t.Errorf("models %v", models)
	}
	if _, err := srv.ListModels(ctx); err != nil || len((*spawned)[0].requests()) != 1 {
		t.Error("model list not cached")
	}

	a := newSession(agent.Config{Cwd: "/a"}, srv)
	defer a.Shutdown()
	if err := a.Send(ctx, "x", nil); err != nil {
		t.Fatal(err)
	}
	collect(t, a)
	f := (*spawned)[0]
	f.feed(`{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":4102444800},"secondary":{"usedPercent":75,"windowDurationMins":10080},"planType":"pro"}}}`)
	expect(t, "rate limit", collect(t, a), []string{"rateLimit Weekly 0.75 0"})
	// A session attaching later gets the latest account usage straight away.
	b := newSession(agent.Config{Cwd: "/b"}, srv)
	defer b.Shutdown()
	if err := b.Send(ctx, "y", nil); err != nil {
		t.Fatal(err)
	}
	got := collect(t, b)
	if !slices.Contains(got, "rateLimit Weekly 0.75 0") {
		t.Errorf("late session events %q", got)
	}

	info, ok := RateLimit(ts.MustJSON(`{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":5,"windowDurationMins":10080},"planType":"plus"}`))
	if !ok || info.Windows[0].Label != "Current session" || info.Windows[0].Duration != "5 hours" || info.Windows[1].Label != "Weekly" || info.Windows[1].Duration != "7 days" || info.Plan != "plus" {
		t.Errorf("info %+v", info)
	}
	if _, ok := RateLimit(ts.MustJSON(`{}`)); ok {
		t.Error("empty limits reported")
	}
}

func TestShutdown(t *testing.T) {
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	s := newSession(agent.Config{Cwd: "/w"}, srv)
	if err := s.Send(context.Background(), "go", nil); err != nil {
		t.Fatal(err)
	}
	f := (*spawned)[0]
	f.feed(`{"id":3,"method":"item/fileChange/requestApproval","params":{"threadId":"thr_1","itemId":"x"}}`)
	collect(t, s)
	s.Shutdown()
	s.Shutdown()
	for range s.Events() {
	}
	time.Sleep(100 * time.Millisecond)
	if got := f.responses(); len(got) != 1 || got[0] != `{"id":3,"result":{"decision":"decline"}}` {
		t.Errorf("pending approval not declined: %q", got)
	}
	reqs := f.requests()
	if reqs[len(reqs)-1] != `thread/unsubscribe {"threadId":"thr_1"}` {
		t.Errorf("no unsubscribe: %q", reqs)
	}
	if err := s.Send(context.Background(), "x", nil); err == nil {
		t.Error("send after shutdown")
	}
	// Notifications for the old thread no longer reach it.
	f.feed(`{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1"}}}`)
}

func TestRateLimitWindows(t *testing.T) {
	srv, spawned := newFake(standard)
	defer srv.Shutdown()
	ctx := context.Background()
	a := newSession(agent.Config{Cwd: "/a"}, srv)
	defer a.Shutdown()
	if err := a.Send(ctx, "x", nil); err != nil {
		t.Fatal(err)
	}
	collect(t, a)
	next := func(s agent.Session) *domestiquev1.RateLimit {
		t.Helper()
		timeout := time.After(2 * time.Second)
		for {
			select {
			case e := <-s.Events():
				if rl, ok := e.(agent.RateLimit); ok {
					return rl.Info
				}
			case <-timeout:
				t.Fatal("no rate limit event")
			}
		}
	}
	f := (*spawned)[0]
	// Recorded from codex app-server (resetsAt pushed into the future).
	f.feed(`{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":null,"limitName":null,
	  "primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":4102444000},
	  "secondary":{"usedPercent":61,"windowDurationMins":10080,"resetsAt":4102444800},
	  "credits":null,"planType":"pro"}}}`)
	rl := next(a)
	want := []*domestiquev1.RateLimitWindow{
		{Id: "primary", Label: "Current session", Duration: "5 hours", UsedFraction: 0.23, ResetsAtMs: 4102444000000},
		{Id: "secondary", Label: "Weekly", Duration: "7 days", UsedFraction: 0.61, ResetsAtMs: 4102444800000},
	}
	if len(rl.Windows) != 2 || !proto.Equal(rl.Windows[0], want[0]) || !proto.Equal(rl.Windows[1], want[1]) {
		t.Fatalf("windows %v", rl.Windows)
	}
	if rl.Plan != "pro" || rl.UsingOverage || rl.OverageStatus != "" {
		t.Errorf("plan/overage %v", rl)
	}
	if rl.Window != "Weekly" || rl.UsedFraction != 0.61 || rl.ResetsAtMs != 4102444800000 {
		t.Errorf("legacy %v", rl)
	}

	// A partial update (primary only) carries only that window.
	f.feed(`{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":90}}}}`)
	rl = next(a)
	if len(rl.Windows) != 1 || rl.Windows[0].Id != "primary" || rl.Windows[0].Label != "Current session" || rl.Windows[0].Duration != "90 min" || rl.Windows[0].ResetsAtMs != 0 {
		t.Fatalf("partial windows %v", rl.Windows)
	}
	if rl.Window != "Current session" || rl.UsedFraction != 0.9 {
		t.Errorf("partial legacy %v", rl)
	}

	// A session attaching later gets every window known so far.
	b := newSession(agent.Config{Cwd: "/b"}, srv)
	defer b.Shutdown()
	if err := b.Send(ctx, "y", nil); err != nil {
		t.Fatal(err)
	}
	rl = next(b)
	if len(rl.Windows) != 2 || rl.Windows[0].UsedFraction != 0.9 || rl.Windows[1].UsedFraction != 0.61 {
		t.Errorf("late session windows %v", rl.Windows)
	}
}
