package mcp_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/mcp"
	"github.com/arbarlow/domestique/server/internal/sandbox"
	"github.com/arbarlow/domestique/server/internal/store"
)

func newManager(t *testing.T) *mcp.Manager {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return mcp.New(st)
}

func stdio(name string) *domestiquev1.McpServer {
	return &domestiquev1.McpServer{Id: uuid.NewString(), Name: name, Transport: domestiquev1.McpTransport_MCP_TRANSPORT_STDIO, Command: "npx", Args: []string{"-y", "pg"}, Enabled: true}
}

func TestSecretsAreKeptAndOnlyResolveReturnsThem(t *testing.T) {
	m := newManager(t)
	s := stdio("postgres")
	if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: s, SetEnv: map[string]string{"DB_URL": "s3cret", "OLD": "x"}}); err != nil {
		t.Fatal(err)
	}
	// Saving again without DB_URL keeps it; OLD is removed.
	if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: s, RemoveEnv: []string{"OLD"}}); err != nil {
		t.Fatal(err)
	}
	list, err := m.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || strings.Join(list[0].EnvNames, ",") != "DB_URL" {
		t.Fatalf("list = %v", list)
	}
	if strings.Contains(list[0].String(), "s3cret") {
		t.Fatal("List leaked a secret")
	}
	config, n, err := m.Render(false)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		McpServers map[string]struct {
			Type string
			Env  map[string]string
		}
	}
	if err := json.Unmarshal(config, &got); err != nil {
		t.Fatal(err)
	}
	pg := got.McpServers["postgres"]
	if n != 1 || pg.Type != "stdio" || pg.Env["DB_URL"] != "s3cret" || len(pg.Env) != 1 {
		t.Fatalf("config = %s", config)
	}
}

func TestRenderRespectsEnabledAndEverywhere(t *testing.T) {
	m := newManager(t)
	off, sandboxOnly, all := stdio("off"), stdio("sandbox-only"), stdio("all")
	off.Enabled = false
	all.Everywhere = true
	for _, s := range []*domestiquev1.McpServer{off, sandboxOnly, all} {
		if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: s}); err != nil {
			t.Fatal(err)
		}
	}
	if _, n, _ := m.Render(false); n != 2 {
		t.Fatalf("sandbox servers = %d", n)
	}
	if _, n, _ := m.Render(true); n != 1 {
		t.Fatalf("everywhere servers = %d", n)
	}
}

func TestValidation(t *testing.T) {
	m := newManager(t)
	bad := []*domestiquev1.SaveMcpServer{
		{Server: stdio("has space")},
		{Server: &domestiquev1.McpServer{Id: uuid.NewString(), Name: "x", Transport: domestiquev1.McpTransport_MCP_TRANSPORT_HTTP, Url: "ftp://a"}},
		{Server: &domestiquev1.McpServer{Id: uuid.NewString(), Name: "x", Transport: domestiquev1.McpTransport_MCP_TRANSPORT_STDIO}},
		{Server: stdio("x"), SetEnv: map[string]string{"1BAD": "v"}},
		{Server: stdio("x"), SetHeaders: map[string]string{"Bad Header": "v"}},
	}
	for i, req := range bad {
		if _, err := m.Save(req); !errors.Is(err, sandbox.ErrInvalid) {
			t.Errorf("case %d: err = %v", i, err)
		}
	}
	if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: stdio("dup")}); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: stdio("dup")}); !errors.Is(err, sandbox.ErrInvalid) {
		t.Errorf("duplicate name: err = %v", err)
	}
	if err := m.Remove(uuid.NewString()); !errors.Is(err, sandbox.ErrNotFound) {
		t.Errorf("remove missing: err = %v", err)
	}
}

func TestWriteFileIsPrivateAndRemovedWhenEmpty(t *testing.T) {
	m := newManager(t)
	path := filepath.Join(t.TempDir(), "mcp.json")
	s := stdio("all")
	s.Everywhere = true
	if _, err := m.Save(&domestiquev1.SaveMcpServer{Server: s}); err != nil {
		t.Fatal(err)
	}
	got, err := m.WriteFile(path)
	if err != nil || got != path {
		t.Fatalf("WriteFile = %q, %v", got, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	if err := m.Remove(s.Id); err != nil {
		t.Fatal(err)
	}
	if got, err := m.WriteFile(path); err != nil || got != "" {
		t.Fatalf("WriteFile = %q, %v", got, err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("file still there: %v", err)
	}
}
