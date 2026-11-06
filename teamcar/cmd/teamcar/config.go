package main

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/BurntSushi/toml"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/sandbox"
)

// Config is teamcar.toml. Every field is optional.
type Config struct {
	// Listen addresses: "unix:///path/to.sock" or "tcp://host:port". Default: the Unix socket only.
	Listen []string `toml:"listen"`
	TLS    struct {
		Cert string `toml:"cert"`
		Key  string `toml:"key"`
	} `toml:"tls"`
	Name           string `toml:"name"`
	WorkspacesRoot string `toml:"workspaces_root"`
	ReposRoot      string `toml:"repos_root"`
	BranchPrefix   string `toml:"branch_prefix"`
	// Port blocks for workspaces, e.g. { start = 41000, end = 50999 } (the default).
	Ports struct {
		Start int32 `toml:"start"`
		End   int32 `toml:"end"`
	} `toml:"ports"`
	Agents struct {
		Claude string `toml:"claude"`
		Codex  string `toml:"codex"`
	} `toml:"agents"`
	// Sandbox providers fixed in the file (clients can't edit them). More can be saved over Race
	// Radio, e.g. from the Mac app's Team Car settings.
	SandboxProviders []SandboxProviderConfig `toml:"sandbox_providers"`

	// Resolved, not from the file.
	home string
}

// SandboxProviderConfig is one [[sandbox_providers]] table.
type SandboxProviderConfig struct {
	// A UUID. Keep it stable: clients remember which provider each workspace's sandbox is on.
	ID   string `toml:"id"`
	Name string `toml:"name"`
	// "boat" (the default and only kind today).
	Kind string `toml:"kind"`
	// The API key: an environment variable or a file (0600). Neither = BOAT_API_KEY, then the
	// Team Car user's `boat login` session.
	APIKeyEnv  string `toml:"api_key_env"`
	APIKeyFile string `toml:"api_key_file"`
	// Defaults for new sandboxes.
	MachineType     string `toml:"machine_type"`
	AutoStopMinutes *int   `toml:"auto_stop_minutes"` // unset or 0 = never
	Environment     string `toml:"environment"`
	FromSnapshot    string `toml:"from_snapshot"`
	DeleteOnArchive bool   `toml:"delete_on_archive"`
}

func (c SandboxProviderConfig) configured() (sandbox.Configured, error) {
	kind := radiov1.SandboxKind_SANDBOX_KIND_BOAT
	if c.Kind != "" && c.Kind != "boat" {
		return sandbox.Configured{}, fmt.Errorf("sandbox provider %q: unknown kind %q (want \"boat\")", c.Name, c.Kind)
	}
	d := &radiov1.SandboxDefaults{
		MachineType: c.MachineType, Environment: c.Environment, FromSnapshot: c.FromSnapshot, DeleteOnArchive: c.DeleteOnArchive,
	}
	if c.AutoStopMinutes != nil && *c.AutoStopMinutes > 0 {
		m := uint32(*c.AutoStopMinutes)
		d.AutoStopMinutes = &m
	}
	return sandbox.Configured{
		Provider:  &radiov1.SandboxProvider{Id: c.ID, Name: c.Name, Kind: kind, Defaults: d},
		APIKeyEnv: c.APIKeyEnv, APIKeyFile: c.APIKeyFile,
	}, nil
}

// homeDir is where Team Car keeps its database, socket and config.
//
//	$TEAMCAR_HOME, else
//	macOS: ~/Library/Application Support/Domestique/teamcar
//	Linux: $XDG_DATA_HOME/teamcar or ~/.local/share/teamcar
func homeDir() string {
	if h := os.Getenv("TEAMCAR_HOME"); h != "" {
		return h
	}
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "Domestique", "teamcar")
	}
	if x := os.Getenv("XDG_DATA_HOME"); x != "" {
		return filepath.Join(x, "teamcar")
	}
	return filepath.Join(home, ".local", "share", "teamcar")
}

func defaultSocket(home string) string { return filepath.Join(home, "teamcar.sock") }

func loadConfig(path string) (*Config, error) {
	cfg := &Config{home: homeDir()}
	if path == "" {
		path = filepath.Join(cfg.home, "teamcar.toml")
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			path = ""
		}
	}
	if path != "" {
		if _, err := toml.DecodeFile(path, cfg); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	// Environment overrides (handy for throwaway dev instances).
	if v := os.Getenv("TEAMCAR_WORKSPACES_ROOT"); v != "" {
		cfg.WorkspacesRoot = v
	}
	if v := os.Getenv("TEAMCAR_REPOS_ROOT"); v != "" {
		cfg.ReposRoot = v
	}
	home, _ := os.UserHomeDir()
	if len(cfg.Listen) == 0 {
		cfg.Listen = []string{"unix://" + defaultSocket(cfg.home)}
	}
	if cfg.WorkspacesRoot == "" {
		cfg.WorkspacesRoot = filepath.Join(home, "Domestique", "workspaces")
	}
	if cfg.ReposRoot == "" {
		cfg.ReposRoot = filepath.Join(home, "Domestique", "repos")
	}
	if cfg.BranchPrefix == "" {
		if u, err := user.Current(); err == nil {
			cfg.BranchPrefix = u.Username
		}
	}
	cfg.WorkspacesRoot = expand(cfg.WorkspacesRoot)
	cfg.ReposRoot = expand(cfg.ReposRoot)
	return cfg, nil
}

func expand(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}
