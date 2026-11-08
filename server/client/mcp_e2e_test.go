package client_test

import (
	"context"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/core"
	"github.com/arbarlow/domestique/server/internal/mcp"
	"github.com/arbarlow/domestique/server/internal/rpc"
	"github.com/arbarlow/domestique/server/internal/store"
)

func TestMcpServersOverRadio(t *testing.T) {
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	server, err := core.New(core.Options{Name: "mcp-server", Version: "test", Store: st, Log: quietLog(),
		WorkspacesRoot: filepath.Join(dir, "ws"), ReposRoot: filepath.Join(dir, "repos")})
	if err != nil {
		t.Fatal(err)
	}
	srv := rpc.NewServer(server, st, quietLog())
	srv.SetMcp(mcp.New(st))
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	serveCtx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = srv.Serve(serveCtx, l, false); close(done) }()
	t.Cleanup(func() { cancel(); <-done; server.Shutdown(); st.Close() })
	url := "ws://" + l.Addr().String()

	cx := ctx(t)
	admin := dialScope(t, url, st, domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN)
	s := &domestiquev1.McpServer{Id: uuid.NewString(), Name: "api", Transport: domestiquev1.McpTransport_MCP_TRANSPORT_HTTP, Url: "https://x.dev/mcp", Enabled: true}
	if _, err := admin.SaveMcpServer(cx, &domestiquev1.SaveMcpServer{Server: s, SetHeaders: map[string]string{"Authorization": "Bearer s3cret"}}); err != nil {
		t.Fatal(err)
	}

	operate := dialScope(t, url, st, domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE)
	if _, err := operate.SaveMcpServer(cx, &domestiquev1.SaveMcpServer{Server: s}); err == nil {
		t.Fatal("OPERATE saved a server")
	}
	list, err := operate.McpServers(cx)
	if err != nil || len(list) != 1 || list[0].HeaderNames[0] != "Authorization" || strings.Contains(list[0].String(), "s3cret") {
		t.Fatalf("list = %v, %v", list, err)
	}
	config, err := operate.ResolveMcpConfig(cx)
	if err != nil || config.ServerCount != 1 || !strings.Contains(config.Json, "Bearer s3cret") {
		t.Fatalf("config = %v, %v", config, err)
	}

	trigger := dialScope(t, url, st, domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER)
	if _, err := trigger.ResolveMcpConfig(cx); err == nil {
		t.Fatal("TRIGGER read the secrets")
	}
}
