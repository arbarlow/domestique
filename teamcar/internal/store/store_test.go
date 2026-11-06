package store

import (
	"path/filepath"
	"testing"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

func open(t *testing.T) *Store {
	s, err := Open(filepath.Join(t.TempDir(), "t.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func item(id, text string) *radiov1.TranscriptItem {
	return &radiov1.TranscriptItem{Id: id, Kind: &radiov1.TranscriptItem_Assistant{Assistant: text}}
}

func TestTranscriptSeqAndPosition(t *testing.T) {
	s := open(t)
	seq, err := s.PutItems("r", 0, []*radiov1.TranscriptItem{item("a", "1"), item("b", "2")})
	if err != nil || seq != 2 {
		t.Fatalf("seq %d err %v", seq, err)
	}
	// Rewriting "a" moves its seq forward but not its position.
	seq, _ = s.PutItems("r", seq, []*radiov1.TranscriptItem{item("a", "1+")})
	if seq != 3 {
		t.Fatalf("seq %d", seq)
	}
	after, _ := s.ItemsAfter("r", 1, 0)
	if len(after) != 2 || after[0].Item.Id != "b" || after[1].Item.Id != "a" || after[1].Item.GetAssistant() != "1+" {
		t.Fatalf("by seq: %v", after)
	}
	inOrder, _ := s.ItemsAfterInOrder("r", 0)
	if len(inOrder) != 2 || inOrder[0].Item.Id != "a" || inOrder[0].Position != 1 || inOrder[0].Seq != 3 {
		t.Fatalf("in order: %v", inOrder)
	}
	if last, _ := s.LastSeq("r"); last != 3 {
		t.Fatalf("last %d", last)
	}
	if other, _ := s.ItemsAfter("other", 0, 0); len(other) != 0 {
		t.Fatal("riders leak into each other")
	}
}

func TestTokens(t *testing.T) {
	s := open(t)
	info, secret, err := s.CreateToken("ci", radiov1.TokenScope_TOKEN_SCOPE_TRIGGER)
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Authenticate(secret)
	if err != nil || got.Id != info.Id || got.Scope != radiov1.TokenScope_TOKEN_SCOPE_TRIGGER {
		t.Fatalf("auth: %v %v", got, err)
	}
	if _, err := s.Authenticate(secret + "x"); err != ErrNotFound {
		t.Fatalf("wrong secret: %v", err)
	}
	if _, _, err := s.CreateToken("x", radiov1.TokenScope_TOKEN_SCOPE_UNSPECIFIED); err == nil {
		t.Fatal("unscoped token allowed")
	}
	if err := s.RevokeToken(info.Id); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(secret); err != ErrNotFound {
		t.Fatalf("revoked: %v", err)
	}
}

func TestImportAndDeleteWorkspace(t *testing.T) {
	s := open(t)
	ws := &radiov1.Workspace{Id: "w", RepositoryId: "repo"}
	other := &radiov1.Workspace{Id: "w2", RepositoryId: "repo"}
	last, err := s.ImportWorkspace(ws, []ImportedRider{
		{Rider: &radiov1.Rider{Id: "r1", WorkspaceId: "w"}, Items: []*radiov1.TranscriptItem{item("z", "1"), item("a", "2"), item("m", "3")}},
		{Rider: &radiov1.Rider{Id: "r2", WorkspaceId: "w"}},
	})
	if err != nil || len(last) != 2 || last[0] != 3 || last[1] != 0 {
		t.Fatalf("last %v err %v", last, err)
	}
	if _, err := s.ImportWorkspace(other, []ImportedRider{{Rider: &radiov1.Rider{Id: "r3", WorkspaceId: "w2"}, Items: []*radiov1.TranscriptItem{item("k", "x")}}}); err != nil {
		t.Fatal(err)
	}
	inOrder, _ := s.ItemsAfterInOrder("r1", 0)
	if len(inOrder) != 3 || inOrder[0].Item.Id != "z" || inOrder[1].Item.Id != "a" || inOrder[2].Item.Id != "m" || inOrder[2].Position != 3 {
		t.Fatalf("in order: %v", inOrder)
	}
	riders, _ := s.Riders()
	if len(riders) != 3 || riders[0].LastSeq != 3 {
		t.Fatalf("riders %v", riders)
	}
	// Importing the same workspace id twice fails (the caller checks first).
	if _, err := s.ImportWorkspace(ws, nil); err == nil {
		t.Fatal("duplicate import succeeded")
	}

	if err := s.DeleteWorkspace("w"); err != nil {
		t.Fatal(err)
	}
	wss, _ := s.Workspaces()
	riders, _ = s.Riders()
	if len(wss) != 1 || wss[0].Id != "w2" || len(riders) != 1 || riders[0].Id != "r3" {
		t.Fatalf("after delete: %v %v", wss, riders)
	}
	if n, _ := s.LastSeq("r1"); n != 0 {
		t.Fatalf("r1 transcript survived: %d", n)
	}
	if n, _ := s.LastSeq("r3"); n != 1 {
		t.Fatalf("other workspace's transcript deleted: %d", n)
	}
}
