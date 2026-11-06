package sandbox_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/sandbox"
	"github.com/arbarlow/domestique/teamcar/internal/sandbox/sandboxtest"
	"github.com/arbarlow/domestique/teamcar/internal/store"
)

func openStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

func newManager(t *testing.T, st *store.Store, boat *sandboxtest.Boat, env map[string]string, fixed ...sandbox.Configured) *sandbox.Manager {
	t.Helper()
	m, err := sandbox.New(sandbox.Options{
		Store: st, Configured: fixed, BoatURL: boat.URL(),
		Getenv:         func(k string) string { return env[k] },
		BoatCLIConfigs: []string{filepath.Join(t.TempDir(), "none.json")},
	})
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func boatProvider(name string) *radiov1.SandboxProvider {
	return &radiov1.SandboxProvider{Id: uuid.NewString(), Name: name, Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT, Defaults: &radiov1.SandboxDefaults{}}
}

func ptr[T any](v T) *T { return &v }

func TestSavedProviderKeepsKeyAndNeverReturnsIt(t *testing.T) {
	ctx := context.Background()
	boat := sandboxtest.New(t, "k1")
	st := openStore(t)
	m := newManager(t, st, boat, nil)

	p := boatProvider("boat · large")
	p.Defaults.MachineType = "large"
	saved, err := m.Save(p, ptr("  k1 \n"))
	if err != nil {
		t.Fatal(err)
	}
	if saved.CredentialSource != radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_STORED {
		t.Fatalf("credential source = %v", saved.CredentialSource)
	}
	// Renaming without api_key keeps the stored key.
	p.Name = "boat · big"
	if _, err := m.Save(p, nil); err != nil {
		t.Fatal(err)
	}
	ps, err := m.Providers(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 1 || ps[0].Name != "boat · big" || ps[0].Defaults.MachineType != "large" {
		t.Fatalf("providers = %v", ps)
	}
	if a := ps[0].Account; a == nil || a.Error != "" || a.Login != "rider" || !a.CanStart {
		t.Fatalf("account = %v", a)
	}

	// An empty key deletes it: the provider then has no credential.
	if _, err := m.Save(p, ptr("")); err != nil {
		t.Fatal(err)
	}
	ps, _ = m.Providers(ctx, false)
	if ps[0].CredentialSource != radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_NONE {
		t.Fatalf("after clearing: %v", ps[0].CredentialSource)
	}
	if _, err := m.List(ctx, p.Id); !errors.Is(err, sandbox.ErrPrecondition) {
		t.Fatalf("list without key: %v", err)
	}

	if err := m.Remove(p.Id); err != nil {
		t.Fatal(err)
	}
	if err := m.Remove(p.Id); !errors.Is(err, sandbox.ErrNotFound) {
		t.Fatalf("second remove: %v", err)
	}
}

func TestConfigProvidersAreReadOnlyAndResolveKeys(t *testing.T) {
	ctx := context.Background()
	boat := sandboxtest.New(t, "from-file")
	st := openStore(t)
	keyFile := filepath.Join(t.TempDir(), "key")
	os.WriteFile(keyFile, []byte("from-file\n"), 0o600)

	envP := boatProvider("env")
	fileP := boatProvider("file")
	fallbackP := boatProvider("fallback")
	m := newManager(t, st, boat, map[string]string{"STRIDE_BOAT": "from-env", "BOAT_API_KEY": "from-fallback"},
		sandbox.Configured{Provider: envP, APIKeyEnv: "STRIDE_BOAT"},
		sandbox.Configured{Provider: fileP, APIKeyFile: keyFile},
		sandbox.Configured{Provider: fallbackP},
	)
	ps, err := m.Providers(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]radiov1.SandboxCredentialSource{
		"env":      radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_CONFIG,
		"file":     radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_CONFIG,
		"fallback": radiov1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_ENVIRONMENT,
	}
	for _, p := range ps {
		if !p.FromConfig || p.CredentialSource != want[p.Name] {
			t.Errorf("%s: from_config=%v source=%v", p.Name, p.FromConfig, p.CredentialSource)
		}
		// Only the file's key is the fake's key.
		if ok := p.Account.GetError() == ""; ok != (p.Name == "file") {
			t.Errorf("%s: account error %q", p.Name, p.Account.GetError())
		}
	}
	if _, err := m.Save(fileP, ptr("x")); !errors.Is(err, sandbox.ErrPrecondition) {
		t.Fatalf("saving a config provider: %v", err)
	}
	if err := m.Remove(fileP.Id); !errors.Is(err, sandbox.ErrPrecondition) {
		t.Fatalf("removing a config provider: %v", err)
	}
}

func TestBadConfig(t *testing.T) {
	st := openStore(t)
	for name, c := range map[string]sandbox.Configured{
		"no uuid":  {Provider: &radiov1.SandboxProvider{Id: "x", Name: "a", Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT}},
		"no name":  {Provider: &radiov1.SandboxProvider{Id: uuid.NewString(), Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT}},
		"two keys": {Provider: boatProvider("a"), APIKeyEnv: "A", APIKeyFile: "/b"},
	} {
		if _, err := sandbox.New(sandbox.Options{Store: st, Configured: []sandbox.Configured{c}}); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

func TestSandboxLifecycle(t *testing.T) {
	ctx := context.Background()
	boat := sandboxtest.New(t, "k")
	st := openStore(t)
	m := newManager(t, st, boat, nil)
	p := boatProvider("boat")
	p.Defaults = &radiov1.SandboxDefaults{MachineType: "large", Environment: "base", FromSnapshot: "stride", AutoStopMinutes: ptr(uint32(120))}
	if _, err := m.Save(p, ptr("k")); err != nil {
		t.Fatal(err)
	}

	// Defaults apply; the idempotency key reaches boat, so a retry returns the same machine.
	s, err := m.Create(ctx, &radiov1.CreateSandbox{ProviderId: p.Id, Name: "stride · galibier", Labels: map[string]string{"domestique": "1"}}, "ws-1")
	if err != nil {
		t.Fatal(err)
	}
	again, err := m.Create(ctx, &radiov1.CreateSandbox{ProviderId: p.Id, Name: "stride · galibier"}, "ws-1")
	if err != nil || again.Id != s.Id {
		t.Fatalf("retry = %v, %v (first %s)", again, err, s.Id)
	}
	c := boat.Creates[0]
	if c["type"] != "large" || c["environment"] != "base" || c["from"] != "stride" || c["ttlSeconds"] != float64(7200) {
		t.Fatalf("create body = %v", c)
	}
	if s.Phase != radiov1.SandboxPhase_SANDBOX_PHASE_STARTING || s.ProviderId != p.Id || s.CreatedAtMs == 0 {
		t.Fatalf("created = %v", s)
	}

	// Overrides win; disable_auto_stop sends ttlSeconds: null.
	if _, err := m.Create(ctx, &radiov1.CreateSandbox{ProviderId: p.Id, MachineType: "small", DisableAutoStop: true}, ""); err != nil {
		t.Fatal(err)
	}
	if c := boat.Creates[2]; c["type"] != "small" {
		t.Fatalf("override body = %v", c)
	} else if v, ok := c["ttlSeconds"]; !ok || v != nil {
		t.Fatalf("ttlSeconds = %v (present %v), want null", v, ok)
	}

	change := func(a radiov1.SandboxAction, ttl *int32) {
		t.Helper()
		if err := m.Change(ctx, &radiov1.ChangeSandbox{ProviderId: p.Id, SandboxId: s.Id, Action: a, TtlSeconds: ttl}); err != nil {
			t.Fatalf("%v: %v", a, err)
		}
	}
	change(radiov1.SandboxAction_SANDBOX_ACTION_STOP, nil)
	if got, _ := m.Get(ctx, p.Id, s.Id); got.Phase != radiov1.SandboxPhase_SANDBOX_PHASE_STOPPED {
		t.Fatalf("after stop: %v", got.Phase)
	}
	change(radiov1.SandboxAction_SANDBOX_ACTION_RESUME, ptr(int32(600)))
	got, _ := m.Get(ctx, p.Id, s.Id)
	if got.Phase != radiov1.SandboxPhase_SANDBOX_PHASE_RUNNING || got.TtlSeconds == nil || *got.TtlSeconds != 600 {
		t.Fatalf("after resume: %v", got)
	}
	change(radiov1.SandboxAction_SANDBOX_ACTION_SET_AUTO_STOP, nil)
	if got, _ := m.Get(ctx, p.Id, s.Id); got.TtlSeconds != nil {
		t.Fatalf("auto-stop off: ttl = %v", *got.TtlSeconds)
	}
	if err := m.Change(ctx, &radiov1.ChangeSandbox{ProviderId: p.Id, SandboxId: s.Id, Action: radiov1.SandboxAction_SANDBOX_ACTION_RENAME}); !errors.Is(err, sandbox.ErrInvalid) {
		t.Fatalf("rename without a name: %v", err)
	}

	a, err := m.Access(ctx, &radiov1.OpenSandboxAccess{ProviderId: p.Id, SandboxId: s.Id, Kind: &radiov1.OpenSandboxAccess_SshPublicKey{SshPublicKey: "ssh-ed25519 AAAAme"}})
	if err != nil || a.HostKey == "" || a.SshUser != "user" || boat.SSHKeys[s.Id][0] != "ssh-ed25519 AAAAme" {
		t.Fatalf("ssh access = %v, %v", a, err)
	}
	a, err = m.Access(ctx, &radiov1.OpenSandboxAccess{ProviderId: p.Id, SandboxId: s.Id, Kind: &radiov1.OpenSandboxAccess_Desktop{Desktop: &radiov1.DesktopAccess{Dark: ptr(true)}}})
	if err != nil || a.Url == "" {
		t.Fatalf("desktop = %v, %v", a, err)
	}
	a, err = m.Access(ctx, &radiov1.OpenSandboxAccess{ProviderId: p.Id, SandboxId: s.Id, Kind: &radiov1.OpenSandboxAccess_Port{Port: &radiov1.PortAccess{Port: 41000}}})
	if err != nil || a.Url == "" {
		t.Fatalf("port = %v, %v", a, err)
	}

	list, err := m.List(ctx, p.Id)
	if err != nil || len(list) != 2 {
		t.Fatalf("list = %v, %v", list, err)
	}
	change(radiov1.SandboxAction_SANDBOX_ACTION_DELETE, nil)
	_, err = m.Get(ctx, p.Id, s.Id)
	var api *sandbox.APIError
	if !errors.As(err, &api) || api.Status != 404 {
		t.Fatalf("get after delete: %v", err)
	}
}

func TestWrongKeyIsAnAPIError(t *testing.T) {
	boat := sandboxtest.New(t, "right")
	st := openStore(t)
	m := newManager(t, st, boat, nil)
	p := boatProvider("boat")
	m.Save(p, ptr("wrong"))
	_, err := m.List(context.Background(), p.Id)
	var api *sandbox.APIError
	if !errors.As(err, &api) || api.Status != 401 {
		t.Fatalf("err = %v", err)
	}
}

// Swift sends UUIDs upper-case; Go and teamcar.toml usually lower-case. Either finds the provider.
func TestProviderIDsIgnoreCase(t *testing.T) {
	boat := sandboxtest.New(t, "k")
	m := newManager(t, openStore(t), boat, nil)
	id := uuid.New()
	p := &radiov1.SandboxProvider{Id: strings.ToUpper(id.String()), Name: "mac", Kind: radiov1.SandboxKind_SANDBOX_KIND_BOAT}
	saved, err := m.Save(p, ptr("k"))
	if err != nil || saved.Id != id.String() {
		t.Fatalf("saved = %v, %v", saved, err)
	}
	for _, q := range []string{id.String(), strings.ToUpper(id.String())} {
		if _, err := m.List(context.Background(), q); err != nil {
			t.Fatalf("list %s: %v", q, err)
		}
	}
	if err := m.Remove(strings.ToUpper(id.String())); err != nil {
		t.Fatal(err)
	}
}

func TestUnreachableServiceIsRetryable(t *testing.T) {
	m, err := sandbox.New(sandbox.Options{Store: openStore(t), BoatURL: "http://127.0.0.1:9/api/v1",
		Getenv: func(string) string { return "" }, BoatCLIConfigs: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	p := boatProvider("boat")
	m.Save(p, ptr("k"))
	_, err = m.List(context.Background(), p.Id)
	var api *sandbox.APIError
	if !errors.As(err, &api) || api.Status != 0 {
		t.Fatalf("err = %v", err)
	}
}
