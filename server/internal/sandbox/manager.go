// Package sandbox is server's sandbox providers: accounts on a sandbox service (boat.dev) whose
// keys and defaults live on this server. Clients never see a key; they ask the server to create,
// resume, stop and open sandboxes.
//
// Providers come from two places: server.toml (fixed, read-only over the Domestique protocol) and the store
// (saved with SaveSandboxProvider, e.g. from the Mac app's settings).
package sandbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/store"
)

var (
	ErrNotFound     = errors.New("not found")
	ErrInvalid      = errors.New("invalid argument")
	ErrPrecondition = errors.New("failed precondition")
)

// Configured is a provider from server.toml.
type Configured struct {
	Provider *domestiquev1.SandboxProvider
	// Exactly one may be set; neither falls back to BOAT_API_KEY, then `boat login`.
	APIKeyEnv  string
	APIKeyFile string
}

type Options struct {
	Store      *store.Store
	Configured []Configured
	// Defaults: boat.dev and a 60s client. Tests point these at a fake.
	BoatURL    string
	HTTPClient *http.Client
	// Environment lookup (os.Getenv by default).
	Getenv func(string) string
	// Where `boat login` keeps its session (defaults to the platform's paths).
	BoatCLIConfigs []string
}

type Manager struct {
	opts Options

	mu     sync.Mutex
	config map[string]Configured
	order  []string
}

func New(opts Options) (*Manager, error) {
	if opts.Getenv == nil {
		opts.Getenv = os.Getenv
	}
	if opts.BoatCLIConfigs == nil {
		opts.BoatCLIConfigs = defaultCLIConfigs()
	}
	m := &Manager{opts: opts, config: map[string]Configured{}}
	for _, c := range opts.Configured {
		p := c.Provider
		if err := validate(p); err != nil {
			return nil, fmt.Errorf("server.toml sandbox provider %q: %w", p.Name, err)
		}
		p.Id = strings.ToLower(p.Id)
		if _, dup := m.config[p.Id]; dup {
			return nil, fmt.Errorf("server.toml: two sandbox providers have id %s", p.Id)
		}
		if c.APIKeyEnv != "" && c.APIKeyFile != "" {
			return nil, fmt.Errorf("server.toml sandbox provider %q: set api_key_env or api_key_file, not both", p.Name)
		}
		m.config[p.Id] = c
		m.order = append(m.order, p.Id)
	}
	return m, nil
}

func defaultCLIConfigs() []string {
	home, _ := os.UserHomeDir()
	out := []string{filepath.Join(home, ".config", "ascii", "boat", "config.json")}
	if runtime.GOOS == "darwin" {
		out = append([]string{filepath.Join(home, "Library", "Application Support", "ascii", "boat", "config.json")}, out...)
	}
	return out
}

func validate(p *domestiquev1.SandboxProvider) error {
	if p == nil {
		return fmt.Errorf("%w: provider is required", ErrInvalid)
	}
	if _, err := uuid.Parse(p.Id); err != nil {
		return fmt.Errorf("%w: provider id must be a UUID", ErrInvalid)
	}
	if strings.TrimSpace(p.Name) == "" {
		return fmt.Errorf("%w: provider name is required", ErrInvalid)
	}
	if p.Kind != domestiquev1.SandboxKind_SANDBOX_KIND_BOAT {
		return fmt.Errorf("%w: unsupported sandbox kind %v", ErrInvalid, p.Kind)
	}
	return nil
}

// entry is a resolved provider and its key.
type entry struct {
	p   *domestiquev1.SandboxProvider
	key string
}

// all returns every provider (config first, then stored) with credential_source filled in.
func (m *Manager) all() ([]entry, error) {
	stored, err := m.opts.Store.SandboxProviders()
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	order := slices.Clone(m.order)
	config := m.config
	m.mu.Unlock()

	var out []entry
	for _, id := range order {
		c := config[id]
		p := proto.Clone(c.Provider).(*domestiquev1.SandboxProvider)
		p.FromConfig = true
		key, src := m.configKey(c)
		if key == "" {
			key, src = m.fallbackKey()
		}
		p.CredentialSource = src
		out = append(out, entry{p, key})
	}
	for _, s := range stored {
		if _, shadowed := config[s.Provider.Id]; shadowed {
			continue
		}
		p := proto.Clone(s.Provider).(*domestiquev1.SandboxProvider)
		p.FromConfig, p.Account = false, nil
		key, src := s.APIKey, domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_STORED
		if key == "" {
			key, src = m.fallbackKey()
		}
		p.CredentialSource = src
		out = append(out, entry{p, key})
	}
	return out, nil
}

func (m *Manager) configKey(c Configured) (string, domestiquev1.SandboxCredentialSource) {
	src := domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_CONFIG
	if c.APIKeyEnv != "" {
		return strings.TrimSpace(m.opts.Getenv(c.APIKeyEnv)), src
	}
	if c.APIKeyFile != "" {
		b, err := os.ReadFile(expandHome(c.APIKeyFile))
		if err != nil {
			return "", src
		}
		return strings.TrimSpace(string(b)), src
	}
	return "", src
}

// fallbackKey: BOAT_API_KEY, then the `boat login` session of the server's user.
func (m *Manager) fallbackKey() (string, domestiquev1.SandboxCredentialSource) {
	if k := strings.TrimSpace(m.opts.Getenv("BOAT_API_KEY")); k != "" {
		return k, domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_ENVIRONMENT
	}
	for _, path := range m.opts.BoatCLIConfigs {
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var cfg struct {
			Token string `json:"token"`
		}
		if json.Unmarshal(b, &cfg) == nil && cfg.Token != "" {
			return cfg.Token, domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_CLI
		}
	}
	return "", domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_NONE
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}

// Providers lists every provider. checkAccount also reads each account (one call per provider).
func (m *Manager) Providers(ctx context.Context, checkAccount bool) ([]*domestiquev1.SandboxProvider, error) {
	es, err := m.all()
	if err != nil {
		return nil, err
	}
	out := make([]*domestiquev1.SandboxProvider, len(es))
	var wg sync.WaitGroup
	for i, e := range es {
		out[i] = e.p
		if !checkAccount {
			continue
		}
		if e.key == "" {
			e.p.Account = &domestiquev1.SandboxAccount{Error: "No API key. Add one to this provider, set BOAT_API_KEY or run `boat login` on the server."}
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			e.p.Account = m.client(e.key).account(ctx)
		}()
	}
	wg.Wait()
	return out, nil
}

func (m *Manager) lookup(id string) (entry, error) {
	es, err := m.all()
	if err != nil {
		return entry{}, err
	}
	for _, e := range es {
		if strings.EqualFold(e.p.Id, id) {
			if e.key == "" {
				return e, fmt.Errorf("%w: %s has no API key on this server", ErrPrecondition, e.p.Name)
			}
			return e, nil
		}
	}
	return entry{}, fmt.Errorf("%w: sandbox provider %s", ErrNotFound, id)
}

func (m *Manager) client(key string) *boatClient {
	return newBoatClient(m.opts.BoatURL, key, m.opts.HTTPClient)
}

// Save creates or replaces a stored provider. apiKey nil keeps the stored key.
func (m *Manager) Save(p *domestiquev1.SandboxProvider, apiKey *string) (*domestiquev1.SandboxProvider, error) {
	if err := validate(p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	_, fixed := m.config[strings.ToLower(p.Id)]
	m.mu.Unlock()
	if fixed {
		return nil, fmt.Errorf("%w: %s is set in server.toml; change it there", ErrPrecondition, p.Name)
	}
	p = proto.Clone(p).(*domestiquev1.SandboxProvider)
	p.Id = strings.ToLower(p.Id)
	p.Account, p.FromConfig, p.CredentialSource = nil, false, domestiquev1.SandboxCredentialSource_SANDBOX_CREDENTIAL_SOURCE_UNSPECIFIED
	if p.Defaults == nil {
		p.Defaults = &domestiquev1.SandboxDefaults{}
	}
	if apiKey != nil {
		k := strings.TrimSpace(*apiKey)
		apiKey = &k
	}
	if err := m.opts.Store.PutSandboxProvider(p, apiKey); err != nil {
		return nil, err
	}
	e, err := m.lookup(p.Id)
	if err != nil && !errors.Is(err, ErrPrecondition) {
		return nil, err
	}
	return e.p, nil
}

func (m *Manager) Remove(id string) error {
	id = strings.ToLower(id)
	m.mu.Lock()
	_, fixed := m.config[id]
	m.mu.Unlock()
	if fixed {
		return fmt.Errorf("%w: this provider is set in server.toml; remove it there", ErrPrecondition)
	}
	if err := m.opts.Store.DeleteSandboxProvider(id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return fmt.Errorf("%w: sandbox provider %s", ErrNotFound, id)
		}
		return err
	}
	return nil
}

func (m *Manager) List(ctx context.Context, providerID string) ([]*domestiquev1.Sandbox, error) {
	e, err := m.lookup(providerID)
	if err != nil {
		return nil, err
	}
	bs, err := m.client(e.key).list(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]*domestiquev1.Sandbox, len(bs))
	for i, b := range bs {
		out[i] = b.proto(providerID)
	}
	return out, nil
}

func (m *Manager) Get(ctx context.Context, providerID, sandboxID string) (*domestiquev1.Sandbox, error) {
	e, err := m.lookup(providerID)
	if err != nil {
		return nil, err
	}
	b, err := m.client(e.key).sandbox(ctx, sandboxID)
	if err != nil {
		return nil, err
	}
	return b.proto(providerID), nil
}

// Create starts a sandbox with the provider's defaults under the request's overrides.
func (m *Manager) Create(ctx context.Context, req *domestiquev1.CreateSandbox, idempotencyKey string) (*domestiquev1.Sandbox, error) {
	e, err := m.lookup(req.ProviderId)
	if err != nil {
		return nil, err
	}
	d := e.p.GetDefaults()
	bc := boatCreate{
		Name:        req.Name,
		Type:        firstNonEmpty(req.MachineType, d.GetMachineType()),
		Environment: firstNonEmpty(req.Environment, d.GetEnvironment()),
		From:        firstNonEmpty(req.FromSnapshot, d.GetFromSnapshot()),
		Labels:      req.Labels,
	}
	switch {
	case req.DisableAutoStop:
		bc.DisableAutoStop = true
	case req.AutoStopMinutes != nil:
		s := int64(*req.AutoStopMinutes) * 60
		bc.TTLSeconds = &s
	case d.AutoStopMinutes != nil:
		s := int64(*d.AutoStopMinutes) * 60
		bc.TTLSeconds = &s
	default:
		// The provider says "never".
		bc.DisableAutoStop = true
	}
	c := m.client(e.key)
	id, err := c.create(ctx, bc, idempotencyKey)
	if err != nil {
		return nil, err
	}
	b, err := c.sandbox(ctx, id)
	if err != nil {
		// Created but not readable yet: report it as starting.
		return &domestiquev1.Sandbox{Id: id, ProviderId: req.ProviderId, Name: req.Name, Phase: domestiquev1.SandboxPhase_SANDBOX_PHASE_STARTING}, nil
	}
	return b.proto(req.ProviderId), nil
}

func firstNonEmpty(a ...string) string {
	for _, s := range a {
		if s != "" {
			return s
		}
	}
	return ""
}

func (m *Manager) Change(ctx context.Context, req *domestiquev1.ChangeSandbox) error {
	e, err := m.lookup(req.ProviderId)
	if err != nil {
		return err
	}
	if req.SandboxId == "" {
		return fmt.Errorf("%w: sandbox_id is required", ErrInvalid)
	}
	c := m.client(e.key)
	switch req.Action {
	case domestiquev1.SandboxAction_SANDBOX_ACTION_RESUME:
		body := map[string]any{}
		if req.TtlSeconds != nil {
			body["ttlSeconds"] = *req.TtlSeconds
		}
		return c.post(ctx, req.SandboxId, "resume", body)
	case domestiquev1.SandboxAction_SANDBOX_ACTION_STOP:
		return c.post(ctx, req.SandboxId, "stop", nil)
	case domestiquev1.SandboxAction_SANDBOX_ACTION_SET_AUTO_STOP:
		var ttl any
		if req.TtlSeconds != nil {
			ttl = *req.TtlSeconds
		}
		return c.patch(ctx, req.SandboxId, map[string]any{"ttlSeconds": ttl})
	case domestiquev1.SandboxAction_SANDBOX_ACTION_RENAME:
		if strings.TrimSpace(req.Name) == "" {
			return fmt.Errorf("%w: name is required", ErrInvalid)
		}
		return c.patch(ctx, req.SandboxId, map[string]any{"name": req.Name})
	case domestiquev1.SandboxAction_SANDBOX_ACTION_DELETE:
		return c.delete(ctx, req.SandboxId)
	case domestiquev1.SandboxAction_SANDBOX_ACTION_RECOVER:
		return c.post(ctx, req.SandboxId, "recover", nil)
	}
	return fmt.Errorf("%w: action is required", ErrInvalid)
}

func (m *Manager) Access(ctx context.Context, req *domestiquev1.OpenSandboxAccess) (*domestiquev1.SandboxAccess, error) {
	e, err := m.lookup(req.ProviderId)
	if err != nil {
		return nil, err
	}
	c := m.client(e.key)
	switch k := req.Kind.(type) {
	case *domestiquev1.OpenSandboxAccess_SshPublicKey:
		if strings.TrimSpace(k.SshPublicKey) == "" {
			return nil, fmt.Errorf("%w: ssh_public_key is empty", ErrInvalid)
		}
		return c.sshKey(ctx, req.SandboxId, k.SshPublicKey)
	case *domestiquev1.OpenSandboxAccess_Desktop:
		u, err := c.desktop(ctx, req.SandboxId, k.Desktop.Dark)
		if err != nil {
			return nil, err
		}
		return &domestiquev1.SandboxAccess{Url: u}, nil
	case *domestiquev1.OpenSandboxAccess_Port:
		if k.Port.Port == 0 || k.Port.Port > 65535 {
			return nil, fmt.Errorf("%w: port must be 1-65535", ErrInvalid)
		}
		u, err := c.host(ctx, req.SandboxId, k.Port.Port, k.Port.Public, k.Port.Title)
		if err != nil {
			return nil, err
		}
		return &domestiquev1.SandboxAccess{Url: u}, nil
	}
	return nil, fmt.Errorf("%w: access kind is required", ErrInvalid)
}
