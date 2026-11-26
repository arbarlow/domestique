package client_test

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/arbarlow/domestique/server/client"
	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

func TestAutoNamesWorkspaceAndChats(t *testing.T) {
	e := newEnv(t)
	e.stop()
	var calls atomic.Int32
	e.namer = func(ctx context.Context, prompt string) (string, string, error) {
		n := calls.Add(1)
		if n == 1 {
			return "Dark mode toggle", "Add a dark mode toggle", nil
		}
		return "Should be ignored", "Fix the flaky test", nil
	}
	e.start()
	c := e.dial()
	cx := ctx(t)
	ws, first := setup(t, e, c)
	if ws.Title != "" {
		t.Fatalf("a new workspace has no title yet, got %q", ws.Title)
	}

	if err := c.Send(cx, first.Id, "please add a dark mode toggle to settings", nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, func() bool {
		w := findWorkspace(c, cx, ws.Id)
		s, _ := c.Sessions(cx, ws.Id)
		return w.GetTitle() == "Dark mode toggle" && len(s) == 1 && s[0].Title == "Add a dark mode toggle"
	})

	// A second chat gets its own name; the workspace keeps the first one.
	second, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Send(cx, second.Id, "the login test is flaky", nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, func() bool {
		for _, s := range must(c.Sessions(cx, ws.Id)) {
			if s.Id == second.Id {
				return s.Title == "Fix the flaky test"
			}
		}
		return false
	})
	if w := findWorkspace(c, cx, ws.Id); w.GetTitle() != "Dark mode toggle" {
		t.Fatalf("workspace title changed to %q", w.GetTitle())
	}

	// A chat renamed before the name arrives keeps the user's name.
	third, err := c.OpenSession(cx, &domestiquev1.OpenSession{WorkspaceId: ws.Id})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	e.stop()
	e.namer = func(ctx context.Context, prompt string) (string, string, error) {
		<-release
		return "", "Model name", nil
	}
	e.start()
	c = e.dial()
	if err := c.Send(cx, third.Id, "something", nil); err != nil {
		t.Fatal(err)
	}
	mine := "Mine"
	if _, err := c.UpdateSession(cx, &domestiquev1.UpdateSession{SessionId: third.Id, Title: &mine}); err != nil {
		t.Fatal(err)
	}
	close(release)
	time.Sleep(200 * time.Millisecond)
	for _, s := range must(c.Sessions(cx, ws.Id)) {
		if s.Id == third.Id && s.Title != "Mine" {
			t.Fatalf("user's rename was overwritten: %q", s.Title)
		}
	}
}

func findWorkspace(c *client.Client, cx context.Context, id string) *domestiquev1.Workspace {
	for _, w := range must(c.Workspaces(cx, "", false)) {
		if w.Id == id {
			return w
		}
	}
	return nil
}

func eventually(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}
