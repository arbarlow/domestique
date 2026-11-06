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

	// Resolved, not from the file.
	home string
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
