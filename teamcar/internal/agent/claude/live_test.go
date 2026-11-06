package claude

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent"
)

// TestLivePong talks to the real CLI. Run with TEAMCAR_LIVE=1 (needs the CLI installed and logged in).
func TestLivePong(t *testing.T) {
	if os.Getenv("TEAMCAR_LIVE") != "1" {
		t.Skip("set TEAMCAR_LIVE=1 to run against the installed CLI")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()

	models, err := ProbeModels(ctx, "")
	if err != nil || len(models) == 0 {
		t.Fatalf("models: %v %v", models, err)
	}
	t.Logf("%d models, first %s (%s)", len(models), models[0].Id, models[0].DisplayName)

	s, err := New(agent.Config{Cwd: t.TempDir(), Mode: radiov1.PermissionMode_PERMISSION_MODE_BYPASS})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Shutdown()
	if err := s.Send(ctx, "Reply with the single word pong and nothing else. Do not use any tools.", nil); err != nil {
		t.Fatal(err)
	}
	texts := map[string]string{}
	var started string
	for {
		select {
		case <-ctx.Done():
			t.Fatalf("timed out; assistant text so far: %v", texts)
		case e, ok := <-s.Events():
			if !ok {
				t.Fatal("events closed before the turn ended")
			}
			switch e := e.(type) {
			case agent.Started:
				started = e.SessionID
				t.Logf("started %s model=%q", e.SessionID, e.Model)
			case agent.Upsert:
				if a, ok := e.Item.Kind.(*radiov1.TranscriptItem_Assistant); ok {
					texts[e.Item.Id] = a.Assistant
				}
				if e.Item.TimestampMs < time.Now().Add(-time.Hour).UnixMilli() {
					t.Errorf("bad timestamp %d", e.Item.TimestampMs)
				}
			case agent.AppendText:
				if _, ok := texts[e.ItemID]; ok {
					texts[e.ItemID] += e.Delta
				}
			case agent.RateLimit:
				t.Logf("rate limit %s %.2f", e.Info.Window, e.Info.UsedFraction)
			case agent.Exited:
				t.Fatalf("exited: %s", e.Message)
			case agent.TurnEnded:
				t.Logf("turn ended: %v", e.Summary)
				if e.Summary.IsError {
					t.Fatalf("turn failed: %s", e.Summary.Message)
				}
				all := ""
				for _, v := range texts {
					all += v
				}
				if !strings.Contains(strings.ToLower(all), "pong") {
					t.Fatalf("no pong in assistant text: %v", texts)
				}
				if started == "" {
					t.Error("no Started event")
				}
				t.Logf("assistant: %q", all)
				s.Shutdown()
				for range s.Events() {
				}
				return
			}
		}
	}
}
