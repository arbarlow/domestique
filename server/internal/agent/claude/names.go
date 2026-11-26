package claude

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/arbarlow/domestique/server/internal/agent/lineproc"
)

const namePrompt = `You name pieces of coding work. Read the user's request and reply with JSON only, no prose or code fences: {"workspace": "...", "chat": "..."}.
workspace: 2-5 words naming the overall piece of work, sentence case, no trailing period.
chat: 2-6 words naming this conversation, sentence case, no trailing period.
Be specific (name the feature, bug or area), not generic ("Code changes", "Help request"). No quotes, emoji or branch-style slugs.`

// maxNameInput caps how much of the prompt is sent for naming; the start says what the work is.
const maxNameInput = 4000

// Names asks a small, fast model for a workspace name and a chat name from a first prompt. It runs
// the Claude CLI once, without tools, MCP servers or the user's settings, outside any repository.
func Names(ctx context.Context, executable, prompt string) (workspace, chat string, err error) {
	exe, err := lineproc.LookPath(executable, "claude")
	if err != nil {
		return "", "", err
	}
	if r := []rune(prompt); len(r) > maxNameInput {
		prompt = string(r[:maxNameInput])
	}
	cmd := exec.CommandContext(ctx, exe,
		"-p", "--model", "haiku", "--output-format", "text", "--tools", "", "--no-session-persistence",
		"--strict-mcp-config", "--setting-sources", "", "--system-prompt", namePrompt)
	cmd.Dir = os.TempDir()
	cmd.Env = lineproc.Environ(map[string]string{"CLAUDE_CODE_ENTRYPOINT": Entrypoint})
	cmd.Stdin = strings.NewReader(prompt)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", "", fmt.Errorf("claude naming: %w: %s", err, suffix(strings.TrimSpace(stderr.String()), 300))
	}
	return ParseNames(out.String())
}

// ParseNames reads the {"workspace", "chat"} reply, tolerating code fences or text around it.
func ParseNames(reply string) (workspace, chat string, err error) {
	start, end := strings.Index(reply, "{"), strings.LastIndex(reply, "}")
	if start < 0 || end < start {
		return "", "", fmt.Errorf("claude naming: no JSON in reply %q", suffix(reply, 200))
	}
	var v struct{ Workspace, Chat string }
	if err := json.Unmarshal([]byte(reply[start:end+1]), &v); err != nil {
		return "", "", fmt.Errorf("claude naming: %w", err)
	}
	return CleanName(v.Workspace, 48), CleanName(v.Chat, 48), nil
}

// CleanName trims a model-written name to one short line without wrapping quotes or a final period.
func CleanName(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	s = strings.Trim(s, "\"'`“”‘’")
	s = strings.TrimSuffix(s, ".")
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > max {
		s = strings.TrimSpace(string(r[:max-1])) + "…"
	}
	return s
}
