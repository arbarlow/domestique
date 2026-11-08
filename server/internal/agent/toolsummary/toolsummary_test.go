package toolsummary

import (
	"os"
	"testing"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"google.golang.org/protobuf/proto"
)

func TestUnwrapShell(t *testing.T) {
	cases := map[string]string{
		`/bin/zsh -lc "printf 'yo' > c.txt"`: `printf 'yo' > c.txt`,
		"ls -la":                             "ls -la",
		"bash -lc 'echo hi'":                 "echo hi",
		`zsh -lc "`:                          `"`,
	}
	for in, want := range cases {
		if got := UnwrapShell(in); got != want {
			t.Errorf("UnwrapShell(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNormalizeCodexDiff(t *testing.T) {
	cases := []struct{ diff, kind, want string }{
		{"a\nb\n", "add", "@@ -0,0 +1,2 @@\n+a\n+b\n"},
		{"a\nb\n", "delete", "@@ -1,2 +0,0 @@\n-a\n-b\n"},
		{"@@ -1 +1 @@\n-a\n+b\n", "update", "@@ -1 +1 @@\n-a\n+b\n"},
		{"@@ -0,0 +1 @@\n+a\n", "add", "@@ -0,0 +1 @@\n+a\n"},
	}
	for _, c := range cases {
		if got := NormalizeCodexDiff(c.diff, c.kind); got != c.want {
			t.Errorf("NormalizeCodexDiff(%q, %q) = %q, want %q", c.diff, c.kind, got, c.want)
		}
	}
}

func TestClaudeTool(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct {
		name, input           string
		wantName, wantSummary string
		wantInput             string
	}{
		{"Bash", `{"command":"git status"}`, "Bash", "git status", "git status"},
		{"Read", `{"file_path":"` + home + `/x/a.go"}`, "Read", "~/x/a.go", ""},
		{"NotebookEdit", `{"notebook_path":"/n.ipynb"}`, "NotebookEdit", "/n.ipynb", ""},
		{"Grep", `{"pattern":"foo","path":"/src","glob":"*.go"}`, "Grep", `"foo" in /src in *.go`, ""},
		{"Glob", `{"pattern":"**/*.swift"}`, "Glob", "**/*.swift", ""},
		{"WebFetch", `{"url":"https://x.dev"}`, "WebFetch", "https://x.dev", ""},
		{"WebSearch", `{"query":"go generics"}`, "WebSearch", "go generics", ""},
		{"Task", `{"description":"Find it","prompt":"long"}`, "Agent", "Find it", ""},
		{"Agent", `{"prompt":"` + string(make([]byte, 0)) + `abc"}`, "Agent", "abc", ""},
		{"TodoWrite", `{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"pending"},{"content":"c","status":"in_progress"}]}`, "Todos", "✓ a\n○ b\n→ c", ""},
		{"Skill", `{"skill":"pdf"}`, "Skill", "pdf", ""},
		{"mcp__linear__list_issues", `{}`, "MCP", "linear.list.issues", ""},
		{"Custom", `{"z":"last","a":"first","n":1}`, "Custom", "first", ""},
	}
	for _, c := range cases {
		call := ClaudeTool(c.name, MustJSON(c.input))
		if call.Name != c.wantName || call.Summary != c.wantSummary {
			t.Errorf("%s: got (%q, %q), want (%q, %q)", c.name, call.Name, call.Summary, c.wantName, c.wantSummary)
		}
		if c.wantInput != "" && call.Input != c.wantInput {
			t.Errorf("%s: input %q, want %q", c.name, call.Input, c.wantInput)
		}
		if call.Status != domestiquev1.ToolStatus_TOOL_STATUS_RUNNING {
			t.Errorf("%s: status %v", c.name, call.Status)
		}
	}
	if got := ClaudeTool("Bash", MustJSON(`{"command":"ls","description":"List files"}`)).Description; got != "List files" {
		t.Errorf("bash description = %q", got)
	}
	if got := ClaudeTool("Read", MustJSON(`{"file_path":"/a"}`)).Input; got != "{\n  \"file_path\": \"/a\"\n}" {
		t.Errorf("pretty input = %q", got)
	}
}

func TestClaudeFileChanges(t *testing.T) {
	patch := MustJSON(`{"filePath":"/x/a.py","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a","+b"]}]}`)
	want := []*domestiquev1.FileChange{{Path: "/x/a.py", Diff: "@@ -1,1 +1,1 @@\n-a\n+b\n"}}
	if got := ClaudeFileChanges("Edit", "", patch); !equalChanges(got, want) {
		t.Errorf("structured patch: %v", got)
	}
	create := MustJSON(`{"type":"create","filePath":"/x/n.txt","content":"one\ntwo"}`)
	want = []*domestiquev1.FileChange{{Path: "/x/n.txt", Diff: "@@ -0,0 +1,2 @@\n+one\n+two\n"}}
	if got := ClaudeFileChanges("Write", "", create); !equalChanges(got, want) {
		t.Errorf("create: %v", got)
	}
	if got := ClaudeFileChanges("Bash", "", MustJSON(`{"stdout":"x"}`)); got != nil {
		t.Errorf("no filePath: %v", got)
	}
}

func equalChanges(a, b []*domestiquev1.FileChange) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !proto.Equal(a[i], b[i]) {
			return false
		}
	}
	return true
}

func TestFlattenToolResult(t *testing.T) {
	cases := []struct {
		in   JSON
		want string
	}{
		{JSON{}, ""},
		{MustJSON(`"plain"`), "plain"},
		{MustJSON(`[{"type":"text","text":"a"},{"type":"image"},{"type":"other"},{"type":"text","text":"b"}]`), "a\n[image]\nb"},
		{MustJSON(`{"k":1}`), "{\n  \"k\": 1\n}"},
	}
	for _, c := range cases {
		if got := FlattenToolResult(c.in); got != c.want {
			t.Errorf("FlattenToolResult(%v) = %q, want %q", c.in.Raw(), got, c.want)
		}
	}
}

func TestCodexItem(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct {
		name string
		item string
		want *domestiquev1.TranscriptItem // TimestampMs ignored
	}{
		{"user message hidden", `{"type":"userMessage","id":"u"}`, nil},
		{"no id", `{"type":"agentMessage","text":"x"}`, nil},
		{"unknown", `{"type":"whatever","id":"w"}`, nil},
		{"agent message", `{"type":"agentMessage","id":"a","text":"hi"}`,
			&domestiquev1.TranscriptItem{Id: "a", Kind: &domestiquev1.TranscriptItem_Assistant{Assistant: "hi"}}},
		{"plan", `{"type":"plan","id":"p","text":"1. x"}`,
			&domestiquev1.TranscriptItem{Id: "p", Kind: &domestiquev1.TranscriptItem_Assistant{Assistant: "1. x"}}},
		{"reasoning summary", `{"type":"reasoning","id":"r","summary":["a","b"],"content":["c"]}`,
			&domestiquev1.TranscriptItem{Id: "r", Kind: &domestiquev1.TranscriptItem_Reasoning{Reasoning: "a\n\nb"}}},
		{"reasoning content", `{"type":"reasoning","id":"r","summary":[],"content":["c"]}`,
			&domestiquev1.TranscriptItem{Id: "r", Kind: &domestiquev1.TranscriptItem_Reasoning{Reasoning: "c"}}},
		{"command failed", `{"type":"commandExecution","id":"x","command":"/bin/zsh -lc \"npm test\"","status":"completed","exitCode":1,"aggregatedOutput":"boom","commandActions":[{"type":"unknown","command":"npm test"}]}`,
			&domestiquev1.TranscriptItem{Id: "x", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Bash", Summary: "npm test", Input: `/bin/zsh -lc "npm test"`, Output: "boom", Status: domestiquev1.ToolStatus_TOOL_STATUS_FAILED}}}},
		{"command read", `{"type":"commandExecution","id":"x","command":"cat ` + home + `/a","status":"inProgress","commandActions":[{"type":"read","command":"cat a","path":"` + home + `/a"}]}`,
			&domestiquev1.TranscriptItem{Id: "x", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Read", Summary: "~/a", Input: "cat " + home + "/a", Status: domestiquev1.ToolStatus_TOOL_STATUS_RUNNING}}}},
		{"command unwrap", `{"type":"commandExecution","id":"x","command":"bash -lc 'ls'","status":"declined"}`,
			&domestiquev1.TranscriptItem{Id: "x", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Bash", Summary: "ls", Input: "bash -lc 'ls'", Status: domestiquev1.ToolStatus_TOOL_STATUS_DECLINED}}}},
		{"file change", `{"type":"fileChange","id":"f","status":"completed","changes":[{"path":"/r/a.txt","kind":{"type":"add"},"diff":"x\n"},{"path":"/r/b.txt","kind":{"type":"update"},"diff":"@@ -1 +1 @@\n-a\n+b\n"}]}`,
			&domestiquev1.TranscriptItem{Id: "f", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Edit", Summary: "/r/a.txt, /r/b.txt", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED,
				FileChanges: []*domestiquev1.FileChange{{Path: "/r/a.txt", Diff: "@@ -0,0 +1,1 @@\n+x\n"}, {Path: "/r/b.txt", Diff: "@@ -1 +1 @@\n-a\n+b\n"}}}}}},
		{"mcp", `{"type":"mcpToolCall","id":"m","server":"linear","tool":"list","arguments":{"q":1},"status":"completed","result":{"content":[{"type":"text","text":"ok"}]}}`,
			&domestiquev1.TranscriptItem{Id: "m", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "MCP", Summary: "linear.list", Input: "{\n  \"q\": 1\n}", Output: "ok", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED}}}},
		{"mcp error", `{"type":"mcpToolCall","id":"m","server":"s","tool":"t","status":"failed","error":{"message":"nope"}}`,
			&domestiquev1.TranscriptItem{Id: "m", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "MCP", Summary: "s.t", Output: "nope", Status: domestiquev1.ToolStatus_TOOL_STATUS_FAILED}}}},
		{"dynamic", `{"type":"dynamicToolCall","id":"d","tool":"lookup","arguments":{"b":"two","a":"one"},"status":"inProgress"}`,
			&domestiquev1.TranscriptItem{Id: "d", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "lookup", Summary: "one", Input: "{\n  \"a\": \"one\",\n  \"b\": \"two\"\n}", Status: domestiquev1.ToolStatus_TOOL_STATUS_RUNNING}}}},
		{"web search", `{"type":"webSearch","id":"w","action":{"query":"golang"}}`,
			&domestiquev1.TranscriptItem{Id: "w", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "WebSearch", Summary: "golang", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED}}}},
		{"collab agent", `{"type":"collabAgentToolCall","id":"c","status":"completed"}`,
			&domestiquev1.TranscriptItem{Id: "c", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Agent", Summary: "collabAgentToolCall", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED}}}},
		{"compaction", `{"type":"contextCompaction","id":"k"}`,
			&domestiquev1.TranscriptItem{Id: "k", Kind: &domestiquev1.TranscriptItem_Notice{Notice: "Context compacted"}}},
		{"image view", `{"type":"imageView","id":"i","path":"/p.png"}`,
			&domestiquev1.TranscriptItem{Id: "i", Kind: &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{
				Name: "Image", Summary: "/p.png", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED}}}},
		{"review exit", `{"type":"exitedReviewMode","id":"e","review":"LGTM"}`,
			&domestiquev1.TranscriptItem{Id: "e", Kind: &domestiquev1.TranscriptItem_Assistant{Assistant: "LGTM"}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := time.Now().UnixMilli()
			got := CodexItem(MustJSON(c.item))
			if c.want == nil {
				if got != nil {
					t.Fatalf("got %v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatal("got nil")
			}
			if got.TimestampMs < before {
				t.Errorf("timestamp %d not set to now", got.TimestampMs)
			}
			got.TimestampMs = 0
			if !proto.Equal(got, c.want) {
				t.Errorf("got  %v\nwant %v", got, c.want)
			}
		})
	}
}

func TestWindowLabels(t *testing.T) {
	keys := map[string]string{
		"five_hour": "Current session", "seven_day": "Weekly · all models", "seven_day_opus": "Weekly · Opus",
		"seven_day_sonnet": "Weekly · Sonnet", "seven_day_oauth_apps": "Weekly · Oauth Apps", "other_thing": "Other Thing",
	}
	for k, want := range keys {
		if got := WindowLabelKey(k); got != want {
			t.Errorf("WindowLabelKey(%q) = %q, want %q", k, got, want)
		}
	}
	mins := []struct {
		m          int64
		known      bool
		label, dur string
	}{
		{0, false, "Usage", ""},
		{300, true, "Current session", "5 hours"},
		{10080, true, "Weekly", "7 days"},
		{1440, true, "24-hour", "1 day"},
		{60, true, "Current session", "1 hour"},
		{90, true, "Current session", "90 min"},
	}
	for _, c := range mins {
		if got := WindowLabelMinutes(c.m, c.known); got != c.label {
			t.Errorf("WindowLabelMinutes(%d) = %q, want %q", c.m, got, c.label)
		}
		if got := DurationMinutes(c.m, c.known); got != c.dur {
			t.Errorf("DurationMinutes(%d) = %q, want %q", c.m, got, c.dur)
		}
	}
}

func TestUsageTrackerMergesPartialUpdates(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	var u UsageTracker
	rl := u.Merge(RateLimitInfo{Windows: []RateLimitWindow{
		{ID: "seven_day", Label: "Weekly", UsedFraction: 0.2, ResetsAt: now.Add(time.Hour)},
		{ID: "five_hour", Label: "Current session", UsedFraction: 0.5, ResetsAt: now.Add(time.Hour)},
	}}, now)
	if rl.Window != "Current session" || rl.UsedFraction != 0.5 || rl.ResetsAtMs != now.Add(time.Hour).UnixMilli() {
		t.Fatalf("first: %v", rl)
	}
	// A partial update only mentions the weekly window; the session window is kept.
	rl = u.Merge(RateLimitInfo{Windows: []RateLimitWindow{{ID: "seven_day", Label: "Weekly", UsedFraction: 0.3}}}, now)
	if rl.Window != "Current session" || len(u.Windows) != 2 || u.Windows[0].ID != "five_hour" {
		t.Fatalf("partial: %v %v", rl, u.Windows)
	}
	// Once the session window has reset, it counts as empty.
	rl = u.Merge(RateLimitInfo{}, now.Add(2*time.Hour))
	if rl.Window != "Weekly" || rl.UsedFraction != 0.3 || rl.ResetsAtMs != 0 {
		t.Fatalf("expired: %v", rl)
	}
}

func TestJSON(t *testing.T) {
	j := MustJSON(`{"a":{"b":[1,"x",true,null,1.9]},"big":12345678901234}`)
	if n, ok := j.Path("a", "b").At(0).Int(); !ok || n != 1 {
		t.Error("int")
	}
	if n, _ := j.Path("a", "b").At(4).Int(); n != 1 {
		t.Errorf("truncation: %d", n)
	}
	if n, _ := j.Get("big").Int(); n != 12345678901234 {
		t.Errorf("big: %d", n)
	}
	if !j.Path("a", "b").At(3).IsNull() || !j.Path("a", "b").At(3).NullOrMissing() || !j.Get("zz").NullOrMissing() || j.Get("zz").Exists() {
		t.Error("null/missing")
	}
	if j.Get("a").Get("b").At(9).S() != "" || j.Get("a").At(0).Exists() {
		t.Error("out of range")
	}
	if u := UUID(); len(u) != 36 || u[14] != '4' {
		t.Errorf("uuid %q", u)
	}
}
