package claude

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

// fakeProc stands in for the claude process.
type fakeProc struct {
	mu       sync.Mutex
	args     []string
	written  []ts.JSON
	lines    *lineproc.Queue[[]byte]
	done     chan struct{}
	doneOnce sync.Once
	status   int
	stderr   string
	onWrite  func(ts.JSON)
}

func newFakeProc(args []string) *fakeProc {
	return &fakeProc{args: args, lines: lineproc.NewQueue[[]byte](), done: make(chan struct{})}
}

func (f *fakeProc) WriteJSON(v any) error {
	data, err := lineproc.MarshalJSON(v)
	if err != nil {
		return err
	}
	j, _ := ts.ParseJSON(data)
	f.mu.Lock()
	f.written = append(f.written, j)
	cb := f.onWrite
	f.mu.Unlock()
	if cb != nil {
		cb(j)
	}
	return nil
}
func (f *fakeProc) CloseInput() {}
func (f *fakeProc) Terminate()  { f.exit(130, "") }
func (f *fakeProc) Running() bool {
	select {
	case <-f.done:
		return false
	default:
		return true
	}
}
func (f *fakeProc) Lines() <-chan []byte  { return f.lines.Out() }
func (f *fakeProc) Done() <-chan struct{} { return f.done }
func (f *fakeProc) ExitStatus() int       { f.mu.Lock(); defer f.mu.Unlock(); return f.status }
func (f *fakeProc) StderrTail() string    { f.mu.Lock(); defer f.mu.Unlock(); return f.stderr }
func (f *fakeProc) feed(lines ...string) {
	for _, l := range lines {
		f.lines.Push([]byte(l))
	}
}
func (f *fakeProc) exit(status int, stderr string) {
	f.doneOnce.Do(func() {
		f.mu.Lock()
		f.status, f.stderr = status, stderr
		f.mu.Unlock()
		f.lines.Close()
		close(f.done)
	})
}
func (f *fakeProc) writes() []ts.JSON {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.written)
}

// describe renders an event compactly for assertions.
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
			out += fmt.Sprintf(" in=%d", *s.InputTokens)
		}
		if s.OutputTokens != nil {
			out += fmt.Sprintf(" out=%d", *s.OutputTokens)
		}
		if s.DurationMs != nil {
			out += fmt.Sprintf(" ms=%d", *s.DurationMs)
		}
		if s.CostUsd != nil {
			out += fmt.Sprintf(" cost=%g", *s.CostUsd)
		}
		return out
	case agent.Status:
		return fmt.Sprintf("status %q", e.Text)
	case agent.Models:
		var ids []string
		for _, m := range e.Models {
			ids = append(ids, m.Id+"="+m.DisplayName)
		}
		return "models " + strings.Join(ids, ",")
	case agent.Exited:
		return fmt.Sprintf("exited %q", e.Message)
	case agent.RateLimit:
		return fmt.Sprintf("rateLimit %s %.2f %d", e.Info.Window, e.Info.UsedFraction, e.Info.ResetsAtMs)
	case agent.Task:
		t := e.Task
		var steps []string
		for _, s := range t.Steps {
			steps = append(steps, s.Name+":"+s.Summary)
		}
		return fmt.Sprintf("task %s tool=%s %q %s bg=%v uses=%d tokens=%d act=%q out=%q sum=%q steps=%v ended=%v",
			t.Id, t.ToolUseId, t.Description, strings.TrimPrefix(t.Status.String(), "AGENT_TASK_STATUS_"), t.IsBackground,
			t.ToolUses, t.TotalTokens, t.Activity, t.Output, t.Summary, steps, t.EndedAtMs != 0)
	case agent.AutoTurnStarted:
		return fmt.Sprintf("autoTurn %q", e.Reason)
	}
	return fmt.Sprintf("%T", e)
}

func describeItem(it *domestiquev1.TranscriptItem) string {
	switch k := it.Kind.(type) {
	case *domestiquev1.TranscriptItem_Assistant:
		return fmt.Sprintf("%s assistant %q", it.Id, k.Assistant)
	case *domestiquev1.TranscriptItem_Reasoning:
		return fmt.Sprintf("%s reasoning %q", it.Id, k.Reasoning)
	case *domestiquev1.TranscriptItem_Notice:
		return fmt.Sprintf("%s notice %q", idPrefix(it.Id), k.Notice)
	case *domestiquev1.TranscriptItem_Error:
		return fmt.Sprintf("%s error %q", idPrefix(it.Id), k.Error)
	case *domestiquev1.TranscriptItem_Tool:
		c := k.Tool
		out := fmt.Sprintf("%s tool %s %q %s", it.Id, c.Name, c.Summary, strings.TrimPrefix(c.Status.String(), "TOOL_STATUS_"))
		if c.Output != "" {
			out += fmt.Sprintf(" out=%q", c.Output)
		}
		for _, f := range c.FileChanges {
			out += fmt.Sprintf(" diff[%s]=%q", f.Path, f.Diff)
		}
		return out
	case *domestiquev1.TranscriptItem_Approval:
		a := k.Approval
		out := fmt.Sprintf("%s approval %q %q %s", it.Id, a.Title, a.Detail, strings.TrimPrefix(a.Resolution.String(), "APPROVAL_RESOLUTION_"))
		for _, q := range a.Questions {
			var opts []string
			for _, o := range q.Options {
				opts = append(opts, o.Label)
			}
			out += fmt.Sprintf(" q[%s %q %q multi=%v %v]", q.Id, q.Header, q.Question, q.MultiSelect, opts)
		}
		if len(a.Answers) > 0 {
			out += fmt.Sprintf(" answers=%v", a.Answers)
		}
		return out
	}
	return it.Id
}

// idPrefix strips the random UUID from generated ids ("compact-<uuid>" -> "compact-*").
func idPrefix(id string) string {
	if i := strings.Index(id, "-"); i > 0 && len(id)-i-1 == 36 {
		return id[:i] + "-*"
	}
	return id
}

// collect reads events until none arrive for a short while.
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

func expectEvents(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("events:\n  got:\n    %s\n  want:\n    %s", strings.Join(got, "\n    "), strings.Join(want, "\n    "))
	}
}

// testSession returns a session whose process is a fakeProc already "running" a user turn.
func testSession(t *testing.T, turnRunning bool) (*Session, *fakeProc) {
	t.Helper()
	fp := newFakeProc(nil)
	s := newSession(agent.Config{Cwd: "/tmp"}, func(args []string) (proc, error) { return fp, nil })
	s.mu.Lock()
	s.proc = fp
	s.turnRunning = turnRunning
	s.mu.Unlock()
	t.Cleanup(s.Shutdown)
	return s, fp
}

func feed(s *Session, lines ...string) {
	for _, l := range lines {
		s.mu.Lock()
		s.handleLocked(ts.MustJSON(l))
		s.mu.Unlock()
	}
}

func TestStreamParsing(t *testing.T) {
	cases := []struct {
		name        string
		turnRunning bool
		lines       []string
		want        []string
	}{
		{
			name:        "streamed text and thinking keep their ids",
			turnRunning: true,
			lines: []string{
				`{"type":"system","subtype":"init","session_id":"sess-1","model":"claude-opus-5-5"}`,
				`{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{"id":"msg_1"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"po"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ng"}}}`,
				`{"type":"stream_event","event":{"type":"content_block_delta","index":7,"delta":{"type":"text_delta","text":"lost"}}}`,
				`{"type":"stream_event","parent_tool_use_id":"toolu_x","event":{"type":"message_start","message":{"id":"sub"}}}`,
				`{"type":"assistant","message":{"id":"msg_1","content":[{"type":"thinking","thinking":"hmm"}]}}`,
				`{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"pong"}]}}`,
				`{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"extra"}]}}`,
				`{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"total_cost_usd":0.01,"usage":{"input_tokens":3,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5},"result":"pong"}`,
			},
			want: []string{
				"started sess-1 claude-opus-5-5",
				`status ""`,
				`upsert msg_1-0 reasoning ""`,
				`append msg_1-0 "hmm"`,
				`upsert msg_1-1 assistant ""`,
				`append msg_1-1 "po"`,
				`append msg_1-1 "ng"`,
				`upsert msg_1-0 reasoning "hmm"`,
				`upsert msg_1-1 assistant "pong"`,
				`upsert msg_1-t1 assistant "extra"`,
				`status ""`,
				"turnEnded error=false in=123 out=5 ms=1234 cost=0.01",
			},
		},
		{
			name:        "unstreamed assistant blocks get positional ids; empty thinking is skipped",
			turnRunning: true,
			lines: []string{
				`{"type":"assistant","message":{"id":"m2","content":[{"type":"thinking","thinking":""},{"type":"thinking","thinking":"deep"},{"type":"text","text":"a"},{"type":"text","text":"b"}]}}`,
			},
			want: []string{
				`upsert m2-r1 reasoning "deep"`,
				`upsert m2-t0 assistant "a"`,
				`upsert m2-t1 assistant "b"`,
			},
		},
		{
			name:        "tools, results and structured patches",
			turnRunning: true,
			lines: []string{
				`{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`,
				`{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"/x/a.py"}}]}}`,
				`{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"toolu_3","name":"Grep","input":{"pattern":"x"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a\nb"}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"ok"}]}]},"tool_use_result":{"filePath":"/x/a.py","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a","+b"]}]}}`,
				`{"type":"user","parent_tool_use_id":"toolu_9","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"sub"}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"unknown","content":"x"}]}}`,
				`{"type":"result","subtype":"success","usage":{}}`,
			},
			want: []string{
				`upsert toolu_1 tool Bash "ls" RUNNING`,
				`upsert toolu_2 tool Edit "/x/a.py" RUNNING`,
				`upsert toolu_3 tool Grep "\"x\"" RUNNING`,
				`upsert toolu_1 tool Bash "ls" COMPLETED out="a\nb"`,
				`upsert toolu_2 tool Edit "/x/a.py" COMPLETED out="ok" diff[/x/a.py]="@@ -1,1 +1,1 @@\n-a\n+b\n"`,
				// The result closes tools that never got a tool_result.
				`upsert toolu_3 tool Grep "\"x\"" COMPLETED`,
				`status ""`,
				"turnEnded error=false in=0",
			},
		},
		{
			name:        "tool error result",
			turnRunning: true,
			lines: []string{
				`{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/nope"}}]}}`,
				`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"ENOENT"}]}}`,
			},
			want: []string{
				`upsert t1 tool Read "/nope" RUNNING`,
				`upsert t1 tool Read "/nope" FAILED out="ENOENT"`,
			},
		},
		{
			name:        "error result",
			turnRunning: true,
			lines:       []string{`{"type":"result","subtype":"error_max_turns","is_error":true,"usage":{"input_tokens":1}}`},
			want:        []string{`status ""`, `turnEnded error=true msg="error_max_turns" in=1`},
		},
		{
			name:        "status lines",
			turnRunning: true,
			lines: []string{
				`{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"error":"rate_limit"}`,
				`{"type":"system","subtype":"status","status":"compacting"}`,
				`{"type":"system","subtype":"status","status":null}`,
				`{"type":"system","subtype":"compact_boundary"}`,
			},
			want: []string{
				`status "API rate limit — retrying (2/10)"`,
				`status "Compacting context…"`,
				`status ""`,
				`upsert compact-* notice "Context compacted"`,
			},
		},
		{
			name: "rate limits keep every window and report the worst",
			lines: []string{
				`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.15,"resetsAt":4102444800},"five_hour":{"utilization":0.42,"resetsAt":4102444000}}}}`,
				`{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.6,"resetsAt":4102444800}}}}`,
				`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}`,
			},
			want: []string{
				"rateLimit Current session 0.42 4102444000000",
				"rateLimit Weekly · all models 0.60 4102444800000",
			},
		},
		{
			name: "subagents and the automatic turn their completion triggers",
			lines: []string{
				`{"type":"system","subtype":"task_started","task_id":"task_1","tool_use_id":"toolu_a","description":"Explore repo","subagent_type":"Explore","prompt":"look around","is_backgrounded":true}`,
				`{"type":"assistant","parent_tool_use_id":"toolu_a","message":{"id":"s1","content":[{"type":"tool_use","id":"x","name":"Glob","input":{"pattern":"*.go"}},{"type":"text","text":"found"}]}}`,
				`{"type":"assistant","parent_tool_use_id":"toolu_unknown","message":{"id":"s2","content":[{"type":"text","text":"ignored"}]}}`,
				`{"type":"system","subtype":"task_progress","task_id":"task_1","description":"Running Glob","usage":{"tool_uses":1,"total_tokens":900}}`,
				`{"type":"system","subtype":"task_updated","task_id":"task_1","patch":{"is_backgrounded":false}}`,
				`{"type":"system","subtype":"task_notification","task_id":"task_1","status":"completed","summary":"All done"}`,
				`{"type":"stream_event","event":{"type":"message_start","message":{"id":"auto1"}}}`,
				`{"type":"result","subtype":"success","usage":{}}`,
				`{"type":"assistant","message":{"id":"auto2","content":[{"type":"text","text":"again"}]}}`,
			},
			want: []string{
				`task task_1 tool=toolu_a "Explore repo" RUNNING bg=true uses=0 tokens=0 act="" out="" sum="" steps=[] ended=false`,
				`task task_1 tool=toolu_a "Explore repo" RUNNING bg=true uses=0 tokens=0 act="" out="found" sum="" steps=[Glob:*.go] ended=false`,
				`task task_1 tool=toolu_a "Explore repo" RUNNING bg=true uses=1 tokens=900 act="Running Glob" out="found" sum="" steps=[Glob:*.go] ended=false`,
				`task task_1 tool=toolu_a "Explore repo" RUNNING bg=false uses=1 tokens=900 act="Running Glob" out="found" sum="" steps=[Glob:*.go] ended=false`,
				`task task_1 tool=toolu_a "Explore repo" COMPLETED bg=false uses=1 tokens=900 act="Running Glob" out="found" sum="All done" steps=[Glob:*.go] ended=true`,
				`autoTurn "Agent “Explore repo” finished"`,
				`status ""`,
				`status ""`,
				"turnEnded error=false in=0",
				`autoTurn "Continuing in the background"`,
				`upsert auto2-t0 assistant "again"`,
			},
		},
		{
			name: "task status mapping",
			lines: []string{
				`{"type":"system","subtype":"task_notification","task_id":"t9","status":"killed"}`,
				`{"type":"system","subtype":"task_updated","task_id":"t8","patch":{"status":"failed"}}`,
			},
			want: []string{
				`task t9 tool= "Agent" STOPPED bg=false uses=0 tokens=0 act="" out="" sum="" steps=[] ended=true`,
				`task t8 tool= "Agent" FAILED bg=false uses=0 tokens=0 act="" out="" sum="" steps=[] ended=true`,
			},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, _ := testSession(t, c.turnRunning)
			feed(s, c.lines...)
			expectEvents(t, collect(t, s), c.want)
		})
	}
}

func TestSubagentStepsAreCapped(t *testing.T) {
	s, _ := testSession(t, true)
	feed(s, `{"type":"system","subtype":"task_started","task_id":"t","tool_use_id":"a","description":"d"}`)
	for i := 0; i < 45; i++ {
		feed(s, fmt.Sprintf(`{"type":"assistant","parent_tool_use_id":"a","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"c%d"}}]}}`, i))
	}
	s.mu.Lock()
	steps := s.tasks["t"].steps
	s.mu.Unlock()
	if len(steps) != 40 || steps[0].Summary != "c5" || steps[39].Summary != "c44" {
		t.Fatalf("steps: %d first=%s", len(steps), steps[0].Summary)
	}
}

func TestApprovals(t *testing.T) {
	t.Run("approve for session", func(t *testing.T) {
		s, fp := testSession(t, true)
		feed(s, `{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"toolu_9","decision_reason":"\u001b[1mDangerous\u001b[0m command","display_name":"Bash"}}`)
		s.Respond(context.Background(), "req-1", agent.Decision{Kind: domestiquev1.Decision_DECISION_APPROVE_FOR_SESSION})
		s.Respond(context.Background(), "req-1", agent.Decision{Kind: domestiquev1.Decision_DECISION_DENY}) // already answered: no-op
		expectEvents(t, collect(t, s), []string{
			`upsert approval-req-1 approval "Allow Bash?" "rm -rf build\n\nDangerous command" PENDING`,
			`upsert approval-req-1 approval "Allow Bash?" "rm -rf build\n\nDangerous command" APPROVED_FOR_SESSION`,
		})
		w := fp.writes()
		if len(w) != 1 {
			t.Fatalf("writes: %d", len(w))
		}
		want := `{"response":{"request_id":"req-1","response":{"behavior":"allow","toolUseID":"toolu_9","updatedInput":{"command":"rm -rf build"},"updatedPermissions":[{"behavior":"allow","destination":"session","rules":[{"toolName":"Bash"}],"type":"addRules"}]},"subtype":"success"},"type":"control_response"}`
		if got := w[0].Compact(); got != want {
			t.Errorf("wrote %s\nwant  %s", got, want)
		}
	})
	t.Run("deny with title and default message", func(t *testing.T) {
		s, fp := testSession(t, true)
		feed(s, `{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Write","title":"Claude wants to write a.txt","input":{"file_path":"/a.txt"}}}`)
		s.Respond(context.Background(), "r2", agent.Decision{Kind: domestiquev1.Decision_DECISION_DENY})
		expectEvents(t, collect(t, s), []string{
			`upsert approval-r2 approval "Claude wants to write a.txt" "/a.txt" PENDING`,
			`upsert approval-r2 approval "Claude wants to write a.txt" "/a.txt" DENIED`,
		})
		want := `{"response":{"request_id":"r2","response":{"behavior":"deny","message":"The user denied this action."},"subtype":"success"},"type":"control_response"}`
		if got := fp.writes()[0].Compact(); got != want {
			t.Errorf("wrote %s", got)
		}
	})
	t.Run("approve once", func(t *testing.T) {
		s, fp := testSession(t, true)
		feed(s, `{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"WebFetch","input":{"url":"https://x"}}}`)
		s.Respond(context.Background(), "r3", agent.Decision{Kind: domestiquev1.Decision_DECISION_APPROVE})
		collect(t, s)
		want := `{"response":{"request_id":"r3","response":{"behavior":"allow","updatedInput":{"url":"https://x"}},"subtype":"success"},"type":"control_response"}`
		if got := fp.writes()[0].Compact(); got != want {
			t.Errorf("wrote %s", got)
		}
	})
	t.Run("AskUserQuestion answers are keyed by question text", func(t *testing.T) {
		s, fp := testSession(t, true)
		feed(s, `{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"header":"Lang","question":"Which language?","options":[{"label":"Go","description":"fast"},{"label":"Rust"}],"multiSelect":false},{"header":"DB","question":"Which DBs?","options":[{"label":"PG"}],"multiSelect":true}]}}}`)
		s.Answer(context.Background(), "q1", map[string]string{"q0": "Go", "q1": "PG"})
		expectEvents(t, collect(t, s), []string{
			`upsert approval-q1 approval "Claude has a question" "" PENDING q[q0 "Lang" "Which language?" multi=false [Go Rust]] q[q1 "DB" "Which DBs?" multi=true [PG]]`,
			`upsert approval-q1 approval "Claude has a question" "" ANSWERED q[q0 "Lang" "Which language?" multi=false [Go Rust]] q[q1 "DB" "Which DBs?" multi=true [PG]] answers=map[q0:Go q1:PG]`,
		})
		resp := fp.writes()[0].Path("response", "response")
		if got := resp.Get("updatedInput").Get("answers").Compact(); got != `{"Which DBs?":"PG","Which language?":"Go"}` {
			t.Errorf("answers %s", got)
		}
		if len(resp.Path("updatedInput", "questions").Arr()) != 2 || resp.Get("behavior").S() != "allow" {
			t.Errorf("updatedInput lost the questions: %s", resp.Compact())
		}
	})
	t.Run("cancel and unsupported requests", func(t *testing.T) {
		s, fp := testSession(t, true)
		feed(s,
			`{"type":"control_request","request_id":"c1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"x"}}}`,
			`{"type":"control_cancel_request","request_id":"c1"}`,
			`{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}`,
		)
		s.Respond(context.Background(), "c1", agent.Decision{Kind: domestiquev1.Decision_DECISION_APPROVE})
		expectEvents(t, collect(t, s), []string{
			`upsert approval-c1 approval "Allow Bash?" "x" PENDING`,
			`upsert approval-c1 approval "Allow Bash?" "x" CANCELLED`,
		})
		w := fp.writes()
		if len(w) != 1 || w[0].Compact() != `{"response":{"error":"Not supported by this client","request_id":"h1","subtype":"error"},"type":"control_response"}` {
			t.Errorf("writes %v", w)
		}
	})
}

func TestFullLifecycle(t *testing.T) {
	var spawned []*fakeProc
	var mu sync.Mutex
	cfg := agent.Config{
		Cwd: "/w", Model: "opus", Effort: "high", Mode: domestiquev1.PermissionMode_PERMISSION_MODE_ASK,
		ResumeSessionID: "old-sess", AppendSystemPrompt: "be brief", ExtraWritableRoots: []string{"/repo/.git"},
	}
	s := newSession(cfg, func(args []string) (proc, error) {
		fp := newFakeProc(args)
		fp.onWrite = func(j ts.JSON) {
			// Answer control requests like the CLI.
			if j.Get("type").S() != "control_request" {
				return
			}
			id := j.Get("request_id").S()
			switch j.Path("request", "subtype").S() {
			case "initialize":
				fp.feed(`{"type":"control_response","response":{"subtype":"success","request_id":"` + id + `","response":{"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best"},{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5"}]}}}`)
			case "set_model":
				fp.feed(`{"type":"control_response","response":{"subtype":"error","request_id":"` + id + `","error":"nope"}}`)
			default:
				fp.feed(`{"type":"control_response","response":{"subtype":"success","request_id":"` + id + `"}}`)
			}
		}
		mu.Lock()
		spawned = append(spawned, fp)
		mu.Unlock()
		return fp, nil
	})
	defer s.Shutdown()
	ctx := context.Background()

	// Settings before the process exists only change the config.
	s.SetModel(ctx, "sonnet")
	if err := s.Send(ctx, "hello", []agent.Attachment{{Data: []byte("PNG"), MediaType: "image/png", Filename: "a.png"}, {Data: []byte("x"), MediaType: "text/plain"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Send(ctx, "and also", nil); err != nil { // queued into the running turn
		t.Fatal(err)
	}
	fp := spawned[0]
	wantArgs := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
		"--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default",
		"--allow-dangerously-skip-permissions", "--model", "sonnet", "--effort", "high", "--resume", "old-sess",
		"--append-system-prompt", "be brief", "--add-dir", "/repo/.git"}
	if !slices.Equal(fp.args, wantArgs) {
		t.Errorf("args %q", fp.args)
	}
	w := fp.writes()
	if w[0].Path("request", "subtype").S() != "initialize" || w[0].Get("request_id").S() != "dq_1" {
		t.Errorf("first write %s", w[0].Compact())
	}
	if got := w[1].Compact(); got != `{"message":{"content":[{"source":{"data":"UE5H","media_type":"image/png","type":"base64"},"type":"image"},{"text":"hello","type":"text"}],"role":"user"},"parent_tool_use_id":null,"session_id":"old-sess","type":"user"}` {
		t.Errorf("user message %s", got)
	}
	s.SetPermissionMode(ctx, domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS)
	s.SetEffort(ctx, "")
	s.SetModel(ctx, "default") // the fake CLI rejects this one; the session shrugs it off
	s.Interrupt(ctx)
	fp.feed(
		`{"type":"system","subtype":"init","session_id":"new-sess","model":"claude-sonnet"}`,
		`{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 100"}}]}}`,
		`{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"sleep 100"}}}`,
		`{"type":"result","subtype":"error_during_execution","is_error":true,"usage":{}}`,
	)
	time.Sleep(50 * time.Millisecond)
	var reqs []string
	for _, j := range fp.writes()[2:] {
		reqs = append(reqs, j.Get("type").S()+":"+j.Path("request").Compact())
	}
	wantReqs := []string{
		`user:null`,
		`control_request:{"mode":"bypassPermissions","subtype":"set_permission_mode"}`,
		`control_request:{"settings":{"effortLevel":null},"subtype":"apply_flag_settings"}`,
		`control_request:{"model":null,"subtype":"set_model"}`,
		`control_request:{"subtype":"interrupt"}`,
	}
	if !slices.Equal(reqs, wantReqs) {
		t.Errorf("requests:\n%s", strings.Join(reqs, "\n"))
	}

	// A new turn on the same process, then the process dies mid-turn.
	if err := s.Send(ctx, "next", nil); err != nil {
		t.Fatal(err)
	}
	fp.feed(`{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/f"}}]}}`,
		`{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","tool_name":"Read","input":{"file_path":"/f"}}}`)
	time.Sleep(50 * time.Millisecond)
	fp.exit(1, "  boom: out of memory \n")

	expectEvents(t, collect(t, s), []string{
		"turnStarted",
		"models default=Opus 5.5,opus=Opus 5.5",
		"started new-sess claude-sonnet",
		`upsert t1 tool Bash "sleep 100" RUNNING`,
		`upsert approval-p1 approval "Allow Bash?" "sleep 100" PENDING`,
		`upsert t1 tool Bash "sleep 100" COMPLETED`,
		`status ""`,
		`turnEnded error=false msg="Interrupted" in=0`,
		"turnStarted",
		`upsert t2 tool Read "/f" RUNNING`,
		`upsert approval-p2 approval "Allow Read?" "/f" PENDING`,
		// Exit: pending approvals cancelled, running tools failed, turn ended, exit reported.
		`upsert approval-p1 approval "Allow Bash?" "sleep 100" CANCELLED`,
		`upsert approval-p2 approval "Allow Read?" "/f" CANCELLED`,
		`upsert t2 tool Read "/f" FAILED`,
		`turnEnded error=true msg="Claude exited"`,
		`exited "boom: out of memory"`,
	})

	// The next Send restarts and resumes the session the CLI reported.
	if err := s.Send(ctx, "again", nil); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	n := len(spawned)
	args := spawned[n-1].args
	mu.Unlock()
	if n != 2 || !slices.Contains(args, "new-sess") || !slices.Contains(args, "bypassPermissions") || slices.Contains(args, "--model") || slices.Contains(args, "--effort") {
		t.Errorf("restart: n=%d args=%q", n, args)
	}
	s.Shutdown()
	s.Shutdown()
	if err := s.Send(ctx, "x", nil); err == nil {
		t.Error("send after shutdown succeeded")
	}
	for range s.Events() {
	}
}

func TestExpectedExitIsSilent(t *testing.T) {
	s, fp := testSession(t, false)
	go s.readLoop(fp)
	fp.exit(130, "Interrupted")
	expectEvents(t, collect(t, s), []string{`exited ""`})
}

func TestShutdownClosesEventsWhileBusy(t *testing.T) {
	s, fp := testSession(t, true)
	go s.readLoop(fp)
	stop := make(chan struct{})
	go func() {
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			fp.feed(fmt.Sprintf(`{"type":"assistant","message":{"id":"m%d","content":[{"type":"text","text":"x"}]}}`, i))
		}
	}()
	time.Sleep(20 * time.Millisecond)
	s.Shutdown()
	close(stop)
	n := 0
	for range s.Events() {
		n++
	}
	if n == 0 {
		t.Error("no events delivered")
	}
}

func TestParseModels(t *testing.T) {
	resp := ts.MustJSON(`{"models":[
	  {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks","supportedEffortLevels":["low","high"]},
	  {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work"},
	  {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"},
	  {"value":"sonnet","displayName":"Sonnet (recommended)","supportedEffortLevels":["low","medium"]}
	]}`)
	models := ParseModels(resp)
	var names []string
	for _, m := range models {
		names = append(names, m.DisplayName)
	}
	if !slices.Equal(names, []string{"Opus 5.5", "Opus 5.5", "Haiku 4.5", "Sonnet"}) {
		t.Errorf("names %q", names)
	}
	if !models[0].IsDefault || models[0].Description != "Best for everyday, complex tasks" || models[0].DefaultEffort != "high" {
		t.Errorf("default %v", models[0])
	}
	if models[1].IsDefault || models[1].DefaultEffort != "" || models[3].DefaultEffort != "medium" {
		t.Errorf("efforts %v %v", models[1], models[3])
	}
	// Default without a matching sibling is named from its description.
	m := ParseModels(ts.MustJSON(`{"models":[{"value":"default","resolvedModel":"x","displayName":"Default","description":"Sonnet 5 · Fast"}]}`))
	if m[0].DisplayName != "Sonnet 5" || m[0].Description != "Fast" {
		t.Errorf("from description %v", m[0])
	}
}

func TestRateLimitKeepsEveryWindow(t *testing.T) {
	info, ok := RateLimit(ts.MustJSON(`{"status":"allowed","isUsingOverage":false,"overageStatus":"rejected","overageDisabledReason":"out_of_credits",
	  "unifiedWindows":{"seven_day":{"utilization":0.15,"resetsAt":1794344400,"status":"allowed"},
	                    "five_hour":{"utilization":0.42,"resetsAt":1794300000,"status":"allowed"},
	                    "seven_day_opus":{"utilization":0.3,"resetsAt":1794344400}}}`))
	if !ok {
		t.Fatal("no info")
	}
	var ids, labels []string
	for _, w := range info.Windows {
		ids = append(ids, w.ID)
		labels = append(labels, w.Label)
	}
	if !slices.Equal(ids, []string{"five_hour", "seven_day", "seven_day_opus"}) {
		t.Errorf("ids %q", ids)
	}
	if !slices.Equal(labels, []string{"Current session", "Weekly · all models", "Weekly · Opus"}) {
		t.Errorf("labels %q", labels)
	}
	if w, _ := info.Worst(); w.ID != "five_hour" {
		t.Errorf("worst %s", w.ID)
	}
	if info.OverageDisabledReason != "out_of_credits" || info.Windows[0].Duration != "5 hours" || info.Windows[1].Status != "allowed" {
		t.Errorf("info %+v", info)
	}
}

func TestCLIMode(t *testing.T) {
	for m, want := range map[domestiquev1.PermissionMode]string{
		domestiquev1.PermissionMode_PERMISSION_MODE_UNSPECIFIED: "bypassPermissions",
		domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS:      "bypassPermissions",
		domestiquev1.PermissionMode_PERMISSION_MODE_AUTO:        "auto",
		domestiquev1.PermissionMode_PERMISSION_MODE_ASK:         "default",
	} {
		if got := CLIMode(m); got != want {
			t.Errorf("CLIMode(%v) = %q", m, got)
		}
	}
}

func TestFallbackModelsAreFresh(t *testing.T) {
	a := FallbackModels()
	a[0].Efforts[0] = "mutated"
	if FallbackModels()[0].Efforts[0] != "low" {
		t.Error("fallback models share state")
	}
}

func TestRateLimitEventCarriesEveryWindow(t *testing.T) {
	s, _ := testSession(t, false)
	next := func() *domestiquev1.RateLimit {
		t.Helper()
		select {
		case e := <-s.Events():
			rl, ok := e.(agent.RateLimit)
			if !ok {
				t.Fatalf("event %s", describe(e))
			}
			return rl.Info
		case <-time.After(2 * time.Second):
			t.Fatal("no rate limit event")
		}
		return nil
	}
	// Recorded from Claude Code (resetsAt pushed into the future so nothing counts as expired).
	feed(s, `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":4102444000,"rateLimitType":"five_hour","utilization":0.91,
	  "isUsingOverage":true,"overageStatus":"allowed","overageResetsAt":4102444800,
	  "unifiedWindows":{"seven_day_opus":{"utilization":0.33,"resetsAt":4102444800},
	                    "five_hour":{"utilization":0.91,"resetsAt":4102444000,"status":"allowed_warning"},
	                    "seven_day":{"utilization":0.4,"resetsAt":4102444800,"status":"allowed"},
	                    "seven_day_oauth_apps":{"utilization":0.05,"resetsAt":4102444800}}},
	  "uuid":"0b2c","session_id":"sess"}`)
	rl := next()
	want := []*domestiquev1.RateLimitWindow{
		{Id: "five_hour", Label: "Current session", Duration: "5 hours", UsedFraction: 0.91, ResetsAtMs: 4102444000000, Status: "allowed_warning"},
		{Id: "seven_day", Label: "Weekly · all models", Duration: "7 days", UsedFraction: 0.4, ResetsAtMs: 4102444800000, Status: "allowed"},
		{Id: "seven_day_oauth_apps", Label: "Weekly · Oauth Apps", Duration: "7 days", UsedFraction: 0.05, ResetsAtMs: 4102444800000},
		{Id: "seven_day_opus", Label: "Weekly · Opus", Duration: "7 days", UsedFraction: 0.33, ResetsAtMs: 4102444800000},
	}
	if len(rl.Windows) != len(want) {
		t.Fatalf("windows %v", rl.Windows)
	}
	for i := range want {
		if !proto.Equal(rl.Windows[i], want[i]) {
			t.Errorf("window %d = %v, want %v", i, rl.Windows[i], want[i])
		}
	}
	if !rl.UsingOverage || rl.OverageStatus != "allowed" || rl.OverageDisabledReason != "" || rl.Plan != "" {
		t.Errorf("overage %v", rl)
	}
	if rl.Window != "Current session" || rl.UsedFraction != 0.91 || rl.ResetsAtMs != 4102444000000 {
		t.Errorf("legacy fields %v", rl)
	}

	// A partial update carries only its own windows; the legacy fields still see the merged state.
	feed(s, `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","isUsingOverage":false,"overageStatus":"rejected","overageDisabledReason":"out_of_credits",
	  "unifiedWindows":{"seven_day_opus":{"utilization":0.5,"resetsAt":4102444800}}}}`)
	rl = next()
	if len(rl.Windows) != 1 || rl.Windows[0].Id != "seven_day_opus" || rl.Windows[0].UsedFraction != 0.5 {
		t.Errorf("partial windows %v", rl.Windows)
	}
	if rl.UsingOverage || rl.OverageStatus != "rejected" || rl.OverageDisabledReason != "out_of_credits" {
		t.Errorf("partial overage %v", rl)
	}
	if rl.Window != "Current session" || rl.UsedFraction != 0.91 {
		t.Errorf("partial legacy %v", rl)
	}
}
