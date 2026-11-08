// Package mcp is server's MCP servers: what agents should connect to, and the secrets to do it
// with. They live in the server's database, so a server on a Linux server (no Keychain) works the same
// as the one on a Mac.
package mcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/sandbox"
	"github.com/arbarlow/domestique/server/internal/store"
)

var (
	serverName = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	envName    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	headerName = regexp.MustCompile("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
)

type Manager struct {
	store *store.Store
	// Serializes Save's read-modify-write of a server's secrets.
	mu sync.Mutex
}

func New(st *store.Store) *Manager { return &Manager{store: st} }

// public is a server as clients see it: which secrets exist, never their values.
func public(s store.StoredMcpServer) *domestiquev1.McpServer {
	out := proto.Clone(s.Server).(*domestiquev1.McpServer)
	out.EnvNames, out.HeaderNames = sortedKeys(s.Env), sortedKeys(s.Headers)
	return out
}

func sortedKeys(m map[string]string) []string {
	if len(m) == 0 {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func (m *Manager) List() ([]*domestiquev1.McpServer, error) {
	stored, err := m.store.McpServers()
	if err != nil {
		return nil, err
	}
	out := make([]*domestiquev1.McpServer, len(stored))
	for i, s := range stored {
		out[i] = public(s)
	}
	return out, nil
}

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", sandbox.ErrInvalid, fmt.Sprintf(format, a...))
}

func validate(s *domestiquev1.McpServer) error {
	if s == nil {
		return invalid("server is required")
	}
	if _, err := uuid.Parse(s.Id); err != nil {
		return invalid("server id must be a UUID")
	}
	if !serverName.MatchString(s.Name) {
		return invalid("server names can only use letters, digits, - and _")
	}
	switch s.Transport {
	case domestiquev1.McpTransport_MCP_TRANSPORT_STDIO:
		if strings.TrimSpace(s.Command) == "" {
			return invalid("%s needs a command", s.Name)
		}
	case domestiquev1.McpTransport_MCP_TRANSPORT_HTTP, domestiquev1.McpTransport_MCP_TRANSPORT_SSE:
		u, err := url.Parse(s.Url)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return invalid("%s needs an http or https URL", s.Name)
		}
	default:
		return invalid("%s needs a transport", s.Name)
	}
	return nil
}

// Save creates or replaces a server. Secrets the request doesn't mention keep their values.
func (m *Manager) Save(req *domestiquev1.SaveMcpServer) (*domestiquev1.McpServer, error) {
	if err := validate(req.GetServer()); err != nil {
		return nil, err
	}
	for k := range req.SetEnv {
		if !envName.MatchString(k) {
			return nil, invalid("%q isn't a valid environment variable name", k)
		}
	}
	for k := range req.SetHeaders {
		if !headerName.MatchString(k) {
			return nil, invalid("%q isn't a valid header name", k)
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	all, err := m.store.McpServers()
	if err != nil {
		return nil, err
	}
	id := strings.ToLower(req.Server.Id)
	next := store.StoredMcpServer{Env: map[string]string{}, Headers: map[string]string{}}
	for _, s := range all {
		if s.Server.Id == id {
			if s.Env != nil {
				next.Env = s.Env
			}
			if s.Headers != nil {
				next.Headers = s.Headers
			}
		} else if s.Server.Name == req.Server.Name {
			return nil, invalid("there's already a server called %s", s.Server.Name)
		}
	}
	apply(next.Env, req.SetEnv, req.RemoveEnv)
	apply(next.Headers, req.SetHeaders, req.RemoveHeaders)

	next.Server = proto.Clone(req.Server).(*domestiquev1.McpServer)
	next.Server.Id = id
	next.Server.EnvNames, next.Server.HeaderNames = nil, nil
	if err := m.store.PutMcpServer(next); err != nil {
		return nil, err
	}
	return public(next), nil
}

func apply(values, set map[string]string, remove []string) {
	for _, k := range remove {
		delete(values, k)
	}
	for k, v := range set {
		values[k] = v
	}
}

func (m *Manager) Remove(id string) error {
	if err := m.store.DeleteMcpServer(strings.ToLower(id)); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return fmt.Errorf("%w: MCP server %s", sandbox.ErrNotFound, id)
		}
		return err
	}
	return nil
}

// Entry is one server in Claude's config format.
type entry struct {
	Type    string            `json:"type"`
	Command string            `json:"command,omitempty"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	URL     string            `json:"url,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
}

// Render builds a Claude --mcp-config file from the enabled servers, secrets included.
// everywhereOnly limits it to the servers meant for the server's own worktrees.
func (m *Manager) Render(everywhereOnly bool) (config []byte, count int, err error) {
	stored, err := m.store.McpServers()
	if err != nil {
		return nil, 0, err
	}
	servers := map[string]entry{}
	for _, s := range stored {
		if !s.Server.Enabled || (everywhereOnly && !s.Server.Everywhere) {
			continue
		}
		switch s.Server.Transport {
		case domestiquev1.McpTransport_MCP_TRANSPORT_STDIO:
			servers[s.Server.Name] = entry{Type: "stdio", Command: s.Server.Command, Args: s.Server.Args, Env: s.Env}
		case domestiquev1.McpTransport_MCP_TRANSPORT_HTTP:
			servers[s.Server.Name] = entry{Type: "http", URL: s.Server.Url, Headers: s.Headers}
		case domestiquev1.McpTransport_MCP_TRANSPORT_SSE:
			servers[s.Server.Name] = entry{Type: "sse", URL: s.Server.Url, Headers: s.Headers}
		}
	}
	config, err = json.Marshal(map[string]any{"mcpServers": servers})
	return config, len(servers), err
}

// WriteFile writes the config for this server's own worktrees to path (0600, atomically, since sessions
// start concurrently) and returns path. With no servers it removes the file and returns "".
func (m *Manager) WriteFile(path string) (string, error) {
	config, n, err := m.Render(true)
	if err != nil {
		return "", err
	}
	if n == 0 {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		return "", nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".mcp-*.json")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	// CreateTemp makes it 0600.
	if _, err := tmp.Write(config); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	return path, os.Rename(tmp.Name(), path)
}
