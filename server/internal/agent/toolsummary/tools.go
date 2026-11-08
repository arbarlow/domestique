// Package toolsummary turns provider-specific tool calls and items into the normalised the Domestique protocol
// transcript types (port of AgentKit's ToolSummaries), plus the shared helpers the provider
// packages need: a loose JSON view and rate-limit window labelling.
package toolsummary

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

// NowMs is the transcript timestamp clock (Unix ms). Tests may replace it.
var NowMs = func() int64 { return time.Now().UnixMilli() }

// prefix returns at most n runes of s.
func prefix(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// ClaudeTool summarises a Claude tool_use block.
func ClaudeTool(name string, input JSON) *domestiquev1.ToolCall {
	s := func(key string) (string, bool) { return input.Get(key).Str() }
	or := func(key, fallback string) string {
		if v, ok := s(key); ok {
			return v
		}
		return fallback
	}
	displayName := name
	var summary string
	switch name {
	case "Bash":
		summary = or("command", "")
	case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
		p, ok := s("file_path")
		if !ok {
			p = or("notebook_path", "")
		}
		summary = ShortPath(p)
	case "Grep":
		var parts []string
		if v, ok := s("pattern"); ok {
			parts = append(parts, `"`+v+`"`)
		}
		if v, ok := s("path"); ok {
			parts = append(parts, ShortPath(v))
		}
		if v, ok := s("glob"); ok {
			parts = append(parts, v)
		}
		summary = strings.Join(parts, " in ")
	case "Glob":
		summary = or("pattern", "")
	case "WebFetch":
		summary = or("url", "")
	case "WebSearch":
		summary = or("query", "")
	case "Task", "Agent":
		displayName = "Agent"
		if v, ok := s("description"); ok {
			summary = v
		} else if v, ok := s("prompt"); ok {
			summary = prefix(v, 80)
		}
	case "TodoWrite":
		displayName = "Todos"
		var lines []string
		for _, t := range input.Get("todos").Arr() {
			mark := "○"
			switch t.Get("status").S() {
			case "completed":
				mark = "✓"
			case "in_progress":
				mark = "→"
			}
			lines = append(lines, mark+" "+t.Get("content").S())
		}
		summary = strings.Join(lines, "\n")
	case "Skill":
		if v, ok := s("skill"); ok {
			summary = v
		} else {
			summary = or("command", "")
		}
	default:
		if strings.HasPrefix(name, "mcp__") {
			var parts []string
			for _, p := range strings.Split(name, "_") {
				if p != "" {
					parts = append(parts, p)
				}
			}
			displayName = "MCP"
			summary = strings.Join(parts[1:], ".")
		} else if v, ok := FirstString(input); ok {
			summary = v
		}
	}
	inputText := input.Pretty()
	description := ""
	if name == "Bash" {
		if v, ok := s("command"); ok {
			inputText = v
		}
		description, _ = s("description")
	}
	return &domestiquev1.ToolCall{
		Name:        displayName,
		Summary:     summary,
		Input:       inputText,
		Status:      domestiquev1.ToolStatus_TOOL_STATUS_RUNNING,
		Description: description,
	}
}

// FirstString is the first string member (by sorted key) of an object, truncated to 120 runes.
func FirstString(v JSON) (string, bool) {
	o := v.Obj()
	if o == nil {
		return "", false
	}
	keys := make([]string, 0, len(o))
	for k := range o {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if s, ok := o[k].Str(); ok {
			return prefix(s, 120), true
		}
	}
	return "", false
}

// ShortPath abbreviates the home directory to "~".
func ShortPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if strings.HasPrefix(path, home) {
		return "~" + path[len(home):]
	}
	return path
}

// FlattenToolResult renders a tool_result content value as text.
func FlattenToolResult(content JSON) string {
	if !content.Exists() {
		return ""
	}
	if s, ok := content.Str(); ok {
		return s
	}
	if content.IsArray() {
		var parts []string
		for _, block := range content.Arr() {
			switch block.Get("type").S() {
			case "text":
				if t, ok := block.Get("text").Str(); ok {
					parts = append(parts, t)
				}
			case "image":
				parts = append(parts, "[image]")
			}
		}
		return strings.Join(parts, "\n")
	}
	return content.Pretty()
}

// ClaudeFileChanges turns Claude's tool_use_result for Edit/Write (a structuredPatch, or a created
// file's content) into a unified diff.
func ClaudeFileChanges(toolName, input string, result JSON) []*domestiquev1.FileChange {
	path, ok := result.Get("filePath").Str()
	if !ok {
		return nil
	}
	if hunks := result.Get("structuredPatch").Arr(); len(hunks) > 0 {
		var b strings.Builder
		for _, h := range hunks {
			i := func(k string) int64 { n, _ := h.Get(k).Int(); return n }
			fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@\n", i("oldStart"), i("oldLines"), i("newStart"), i("newLines"))
			for _, line := range h.Get("lines").Arr() {
				b.WriteString(line.S())
				b.WriteString("\n")
			}
		}
		return []*domestiquev1.FileChange{{Path: path, Diff: b.String()}}
	}
	if result.Get("type").S() == "create" {
		if content, ok := result.Get("content").Str(); ok {
			lines := strings.Split(content, "\n")
			var b strings.Builder
			fmt.Fprintf(&b, "@@ -0,0 +1,%d @@\n", len(lines))
			for _, l := range lines {
				b.WriteString("+" + l + "\n")
			}
			return []*domestiquev1.FileChange{{Path: path, Diff: b.String()}}
		}
	}
	return nil
}

// MARK: Codex

// CodexItem maps a Codex ThreadItem to a transcript item (id = the Codex item id, timestamp now).
// Returns nil for items that aren't shown (user messages, hook prompts, unknown types) or that
// have no id.
func CodexItem(item JSON) *domestiquev1.TranscriptItem {
	id, ok := item.Get("id").Str()
	if !ok {
		return nil
	}
	typ, ok := item.Get("type").Str()
	if !ok {
		return nil
	}
	out := &domestiquev1.TranscriptItem{Id: id, TimestampMs: NowMs()}
	tool := func(c *domestiquev1.ToolCall) *domestiquev1.TranscriptItem {
		out.Kind = &domestiquev1.TranscriptItem_Tool{Tool: c}
		return out
	}
	status := CodexStatus(item.Get("status").S())
	switch typ {
	case "userMessage", "hookPrompt":
		return nil
	case "agentMessage", "plan":
		out.Kind = &domestiquev1.TranscriptItem_Assistant{Assistant: item.Get("text").S()}
	case "reasoning":
		summary := joinStrings(item.Get("summary"), "\n\n")
		if summary == "" {
			summary = joinStrings(item.Get("content"), "\n\n")
		}
		out.Kind = &domestiquev1.TranscriptItem_Reasoning{Reasoning: summary}
	case "commandExecution":
		raw := item.Get("command").S()
		action := item.Get("commandActions").At(0)
		display, ok := action.Get("command").Str()
		if !ok {
			display = UnwrapShell(raw)
		}
		call := &domestiquev1.ToolCall{
			Name: "Bash", Summary: display, Input: raw, Output: item.Get("aggregatedOutput").S(), Status: status,
		}
		if code, ok := item.Get("exitCode").Int(); ok && code != 0 && call.Status == domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED {
			call.Status = domestiquev1.ToolStatus_TOOL_STATUS_FAILED
		}
		if p, ok := action.Get("path").Str(); ok && action.Get("type").S() == "read" {
			call.Name = "Read"
			call.Summary = ShortPath(p)
		}
		return tool(call)
	case "fileChange":
		var changes []*domestiquev1.FileChange
		var paths []string
		for _, c := range item.Get("changes").Arr() {
			p := c.Get("path").S()
			changes = append(changes, &domestiquev1.FileChange{
				Path: p, Diff: NormalizeCodexDiff(c.Get("diff").S(), c.Path("kind", "type").S()),
			})
			paths = append(paths, ShortPath(p))
		}
		return tool(&domestiquev1.ToolCall{
			Name: "Edit", Summary: strings.Join(paths, ", "), Status: status, FileChanges: changes,
		})
	case "mcpToolCall":
		server, t := item.Get("server").S(), item.Get("tool").S()
		output := ""
		if result := item.Get("result"); result.Exists() {
			var texts []string
			for _, c := range result.Get("content").Arr() {
				if s, ok := c.Get("text").Str(); ok {
					texts = append(texts, s)
				}
			}
			output = strings.Join(texts, "\n")
			if output == "" {
				output = result.Pretty()
			}
		}
		if msg, ok := item.Path("error", "message").Str(); ok {
			output = msg
		}
		input := ""
		if a := item.Get("arguments"); a.Exists() {
			input = a.Pretty()
		}
		return tool(&domestiquev1.ToolCall{
			Name: "MCP", Summary: server + "." + t, Input: input, Output: output, Status: status,
		})
	case "dynamicToolCall":
		name, ok := item.Get("tool").Str()
		if !ok {
			name = "Tool"
		}
		summary, _ := FirstString(item.Get("arguments"))
		input := ""
		if a := item.Get("arguments"); a.Exists() {
			input = a.Pretty()
		}
		return tool(&domestiquev1.ToolCall{Name: name, Summary: summary, Input: input, Status: status})
	case "webSearch":
		q, ok := item.Get("query").Str()
		if !ok {
			q = item.Path("action", "query").S()
		}
		return tool(&domestiquev1.ToolCall{Name: "WebSearch", Summary: q, Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED})
	case "collabAgentToolCall", "subAgentActivity":
		summary := typ
		if p, ok := item.Get("prompt").Str(); ok {
			summary = prefix(p, 80)
		}
		return tool(&domestiquev1.ToolCall{Name: "Agent", Summary: summary, Status: status})
	case "contextCompaction":
		out.Kind = &domestiquev1.TranscriptItem_Notice{Notice: "Context compacted"}
	case "imageView":
		return tool(&domestiquev1.ToolCall{
			Name: "Image", Summary: ShortPath(item.Get("path").S()), Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED,
		})
	case "enteredReviewMode":
		out.Kind = &domestiquev1.TranscriptItem_Notice{Notice: "Entered review mode"}
	case "exitedReviewMode":
		out.Kind = &domestiquev1.TranscriptItem_Assistant{Assistant: item.Get("review").S()}
	default:
		return nil
	}
	return out
}

func joinStrings(v JSON, sep string) string {
	var parts []string
	for _, e := range v.Arr() {
		if s, ok := e.Str(); ok {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, sep)
}

// NormalizeCodexDiff: Codex sends whole-file content (not a unified diff) for added/deleted files.
func NormalizeCodexDiff(diff, kind string) string {
	if (kind != "add" && kind != "delete") || strings.Contains(diff, "@@") {
		return diff
	}
	lines := strings.Split(diff, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	sign := "-"
	header := fmt.Sprintf("@@ -1,%d +0,0 @@", len(lines))
	if kind == "add" {
		sign = "+"
		header = fmt.Sprintf("@@ -0,0 +1,%d @@", len(lines))
	}
	out := []string{header}
	for _, l := range lines {
		out = append(out, sign+l)
	}
	return strings.Join(out, "\n") + "\n"
}

// CodexStatus maps a Codex item status.
func CodexStatus(s string) domestiquev1.ToolStatus {
	switch s {
	case "completed":
		return domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED
	case "failed":
		return domestiquev1.ToolStatus_TOOL_STATUS_FAILED
	case "declined":
		return domestiquev1.ToolStatus_TOOL_STATUS_DECLINED
	default:
		return domestiquev1.ToolStatus_TOOL_STATUS_RUNNING
	}
}

// UnwrapShell turns `/bin/zsh -lc "foo"` into `foo`.
func UnwrapShell(command string) string {
	for _, p := range []string{"/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "} {
		if !strings.HasPrefix(command, p) {
			continue
		}
		rest := command[len(p):]
		if len(rest) >= 2 && ((rest[0] == '"' && rest[len(rest)-1] == '"') || (rest[0] == '\'' && rest[len(rest)-1] == '\'')) {
			rest = rest[1 : len(rest)-1]
		}
		return rest
	}
	return command
}
