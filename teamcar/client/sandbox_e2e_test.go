package client_test

import (
	"context"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/arbarlow/domestique/teamcar/client"
	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/core"
	"github.com/arbarlow/domestique/teamcar/internal/radio"
	"github.com/arbarlow/domestique/teamcar/internal/sandbox"
	"github.com/arbarlow/domestique/teamcar/internal/sandbox/sandboxtest"
	"github.com/arbarlow/domestique/teamcar/internal/store"
)

// sandboxCar is a Team Car whose sandbox providers talk to a fake boat.dev, on TCP (tokens apply).
func sandboxCar(t *testing.T, boat *sandboxtest.Boat, fixed ...sandbox.Configured) (addr string, st *store.Store) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	car, err := core.New(core.Options{Name: "sandbox-car", Version: "test", Store: st, Log: quietLog(),
		WorkspacesRoot: filepath.Join(dir, "ws"), ReposRoot: filepath.Join(dir, "repos")})
	if err != nil {
		t.Fatal(err)
	}
	m, err := sandbox.New(sandbox.Options{Store: st, Configured: fixed, BoatURL: boat.URL(),
		Getenv: func(string) string { return "" }, BoatCLIConfigs: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	srv := radio.NewServer(car, st, quietLog())
	srv.SetSandboxes(m)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = srv.Serve(cx, l, false); close(done) }()
	t.Cleanup(func() { cancel(); <-done; car.Shutdown(); st.Close() })
	return "ws://" + l.Addr().String(), st
}

func dialScope(t *testing.T, url string, st *store.Store, scope radiov1.TokenScope) *client.Client {
	t.Helper()
	_, secret, err := st.CreateToken(scope.String(), scope)
	if err != nil {
		t.Fatal(err)
	}
	cx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := client.Dial(cx, url, client.WithToken(secret), client.WithLogger(quietLog()), client.WithoutReconnect())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestSandboxProvidersOverRaceRadio(t *testing.T) {
	cx := ctx(t)
	boat := sandboxtest.New(t, "boat-key")
	fixedID := uuid.NewString()
	url, st := sandboxCar(t, boat, sandbox.Configured{
		Provider: &radiov1.SandboxProvider{Id: fixedID, Name: "from toml", Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT},
	})
	admin := dialScope(t, url, st, radiov1.TokenScope_TOKEN_SCOPE_ADMIN)
	trigger := dialScope(t, url, st, radiov1.TokenScope_TOKEN_SCOPE_TRIGGER)
	read := dialScope(t, url, st, radiov1.TokenScope_TOKEN_SCOPE_READ)

	// Only ADMIN saves providers.
	key := "boat-key"
	p := &radiov1.SandboxProvider{Id: uuid.NewString(), Name: "boat · large", Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT,
		Defaults: &radiov1.SandboxDefaults{MachineType: "large"}}
	if _, err := trigger.SaveSandboxProvider(cx, p, &key); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("trigger save: %v", err)
	}
	if _, err := admin.SaveSandboxProvider(cx, p, &key); err != nil {
		t.Fatal(err)
	}
	// teamcar.toml providers are read-only.
	if _, err := admin.SaveSandboxProvider(cx, &radiov1.SandboxProvider{Id: fixedID, Name: "x", Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT}, nil); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("saving a toml provider: %v", err)
	}

	// Everyone sees the providers (never a key) in ServerInfo.
	info, err := read.ServerInfo(cx)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(info.SandboxProviders); n != 2 {
		t.Fatalf("server info lists %d providers", n)
	}
	if got := info.SandboxProviders[0]; got.Id != fixedID || !got.FromConfig ||
		got.CredentialSource != radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_NONE {
		t.Fatalf("toml provider = %v", got)
	}
	ps, err := read.SandboxProviders(cx, true)
	if err != nil || ps[1].Account.GetLogin() != "rider" {
		t.Fatalf("providers = %v, %v", ps, err)
	}

	// READ can't create; TRIGGER can, and a retry with the same key is the same machine.
	if _, err := read.CreateSandbox(cx, &radiov1.CreateSandbox{ProviderId: p.Id}); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("read create: %v", err)
	}
	s, err := trigger.CreateSandbox(cx, &radiov1.CreateSandbox{ProviderId: p.Id, Name: "ws"}, client.Idempotent("ws-1"))
	if err != nil {
		t.Fatal(err)
	}
	s2, err := trigger.CreateSandbox(cx, &radiov1.CreateSandbox{ProviderId: p.Id, Name: "ws"}, client.Idempotent("ws-1"))
	if err != nil || s2.Id != s.Id || len(boat.Creates) != 1 {
		t.Fatalf("retry: %v %v (creates %d)", s2, err, len(boat.Creates))
	}
	if boat.Creates[0]["type"] != "large" {
		t.Fatalf("defaults not applied: %v", boat.Creates[0])
	}

	// TRIGGER stops and resumes; deleting and SSH access need OPERATE.
	if err := trigger.ChangeSandbox(cx, &radiov1.ChangeSandbox{ProviderId: p.Id, SandboxId: s.Id, Action: radiov1.SandboxAction_SANDBOX_ACTION_STOP}); err != nil {
		t.Fatal(err)
	}
	if got, _ := read.Sandbox(cx, p.Id, s.Id); got.GetPhase() != radiov1.SandboxPhase_SANDBOX_PHASE_STOPPED {
		t.Fatalf("after stop: %v", got)
	}
	if err := trigger.ChangeSandbox(cx, &radiov1.ChangeSandbox{ProviderId: p.Id, SandboxId: s.Id, Action: radiov1.SandboxAction_SANDBOX_ACTION_DELETE}); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("trigger delete: %v", err)
	}
	ssh := &radiov1.OpenSandboxAccess{ProviderId: p.Id, SandboxId: s.Id, Kind: &radiov1.OpenSandboxAccess_SshPublicKey{SshPublicKey: "ssh-ed25519 AAAA"}}
	if _, err := trigger.OpenSandboxAccess(cx, ssh); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED {
		t.Fatalf("trigger ssh: %v", err)
	}
	a, err := admin.OpenSandboxAccess(cx, ssh)
	if err != nil || a.HostKey == "" {
		t.Fatalf("ssh access: %v %v", a, err)
	}

	// Service errors keep their meaning: a missing sandbox is NOT_FOUND, a rejected key is never
	// UNAUTHENTICATED (that means a bad Team Car token to clients).
	if _, err := read.Sandbox(cx, p.Id, "bx_missing"); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("missing sandbox: %v", err)
	}
	bad := "wrong"
	if _, err := admin.SaveSandboxProvider(cx, p, &bad); err != nil {
		t.Fatal(err)
	}
	if _, err := read.Sandboxes(cx, p.Id); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("bad key: %v (%v)", client.Code(err), err)
	}
	// No key at all: FAILED_PRECONDITION, and nothing reaches boat.
	if _, err := read.Sandboxes(cx, fixedID); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION {
		t.Fatalf("no key: %v", err)
	}

	if err := admin.RemoveSandboxProvider(cx, p.Id); err != nil {
		t.Fatal(err)
	}
	if _, err := read.Sandboxes(cx, p.Id); !client.IsNotFound(err) {
		t.Fatalf("removed provider: %v", err)
	}
}

// A Team Car without a sandbox manager answers UNIMPLEMENTED instead of crashing.
func TestSandboxesWithoutManager(t *testing.T) {
	e := newEnv(t)
	c := e.dial()
	if _, err := c.SandboxProviders(ctx(t), false); client.Code(err) != radiov1.ErrorCode_ERROR_CODE_UNIMPLEMENTED {
		t.Fatalf("err = %v", err)
	}
}
