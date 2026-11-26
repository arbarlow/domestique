package claude

import "testing"

func TestParseNames(t *testing.T) {
	for _, tc := range []struct{ in, ws, chat string }{
		{`{"workspace": "Auto-name worktrees", "chat": "Name chats from prompts"}`, "Auto-name worktrees", "Name chats from prompts"},
		{"```json\n{\"workspace\": \"\\\"Fix login.\\\"\", \"chat\": \"  Flaky   login test. \"}\n```", "Fix login", "Flaky login test"},
	} {
		ws, chat, err := ParseNames(tc.in)
		if err != nil || ws != tc.ws || chat != tc.chat {
			t.Fatalf("ParseNames(%q) = %q, %q, %v", tc.in, ws, chat, err)
		}
	}
	if _, _, err := ParseNames("sorry, I can't"); err == nil {
		t.Fatal("expected an error without JSON")
	}
	if got := CleanName("A very long name that keeps going and going past the limit", 20); len([]rune(got)) != 20 {
		t.Fatalf("CleanName = %q", got)
	}
}
