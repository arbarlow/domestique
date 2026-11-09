// domestique is the Domestique server: it runs agents, worktrees and processes, and serves the Domestique protocol.
//
//	domestique serve [--config server.toml] [--listen tcp://0.0.0.0:7420] ...
//	domestique token create --name ci --scope trigger
//	domestique ctl <command>          (a client for poking at a running server)
//	domestique exec [flags] -- argv   (run a command on a server, like ssh)
//	domestique version
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
	"github.com/arbarlow/domestique/server/internal/agent/claude"
	"github.com/arbarlow/domestique/server/internal/agent/codex"
	"github.com/arbarlow/domestique/server/internal/agent/lineproc"
	"github.com/arbarlow/domestique/server/internal/core"
	"github.com/arbarlow/domestique/server/internal/mcp"
	"github.com/arbarlow/domestique/server/internal/rpc"
	"github.com/arbarlow/domestique/server/internal/sandbox"
	"github.com/arbarlow/domestique/server/internal/store"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(os.Args[2:])
	case "token":
		err = tokenCmd(os.Args[2:])
	case "ctl":
		err = ctl(os.Args[2:])
	case "exec":
		os.Exit(execCmd(os.Args[2:]))
	case "version", "--version", "-v":
		fmt.Println("domestique", version)
	case "help", "--help", "-h":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "domestique:", err)
		if errors.Is(err, errAlreadyRunning) {
			os.Exit(exitAlreadyRunning)
		}
		os.Exit(1)
	}
}

// exitAlreadyRunning tells the app that another server owns this home, so it should connect to that one
// (LocalServer.alreadyRunningExitCode in Swift).
const exitAlreadyRunning = 75

var errAlreadyRunning = errors.New("another domestique is already running")

// lockHome makes this process the only server for home until the returned file is closed. The kernel drops
// the lock when the process dies, so a crash can't leave it stuck, and Go opens files close-on-exec, so agents
// and tasks don't inherit it. The name is fixed, not dataFile's: that one changes when a pre-rename home migrates.
func lockHome(home string) (*os.File, error) {
	path := filepath.Join(home, "server.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("%w on %s", errAlreadyRunning, home)
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	return f, nil
}

func usage() {
	fmt.Fprint(os.Stderr, `domestique: the Domestique server

Usage:
  domestique serve [--config file] [--listen addr]... [--add-listen addr]... [--name name]
  domestique token create --name NAME --scope read|trigger|operate|admin
  domestique token list
  domestique token revoke TOKEN_ID
  domestique ctl [--url URL] [--token TOKEN] <command>   (run "domestique ctl help")
  domestique exec [--url URL] [--workspace ID] [--cwd DIR] [--tty] [--env K=V]... (--shell SCRIPT | -- ARGV...)
  domestique version

Listen addresses: unix:///path/to.sock (default: the socket in DOMESTIQUE_SERVER_HOME) or tcp://host:port.
TCP connections need a token. You are responsible for the network in between (Tailscale, VPN,
reverse proxy, TLS).
`)
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	cfgPath := fs.String("config", "", "path to server.toml (default: $DOMESTIQUE_SERVER_HOME/server.toml if present)")
	var listen multiFlag
	fs.Var(&listen, "listen", "listen address (repeatable): unix:///path or tcp://host:port")
	var addListen multiFlag
	fs.Var(&addListen, "add-listen", "listen address on top of the configured ones (repeatable)")
	name := fs.String("name", "", "server name shown to clients (default: hostname)")
	verbose := fs.Bool("v", false, "debug logging")
	_ = fs.Parse(args)

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	// Under launchd or systemd PATH is minimal; git needs Homebrew's git-lfs for LFS repos, and setup
	// scripts expect the usual user tool dirs. Every child process inherits this.
	extendPath()
	if len(listen) > 0 {
		cfg.Listen = listen
	}
	for _, addr := range addListen {
		if !slices.Contains(cfg.Listen, addr) {
			cfg.Listen = append(cfg.Listen, addr)
		}
	}
	if *name != "" {
		cfg.Name = *name
	}
	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	if err := os.MkdirAll(cfg.home, 0o700); err != nil {
		return err
	}
	// Before the store and the sockets: two servers starting together would otherwise both find no live
	// socket, and the later one would unlink the earlier one's and strand it.
	lock, err := lockHome(cfg.home)
	if err != nil {
		return err
	}
	defer lock.Close()
	st, err := openStore(cfg)
	if err != nil {
		return err
	}
	defer st.Close()
	// The database holds API keys and MCP secrets, and DOMESTIQUE_SERVER_HOME may be a directory that already existed.
	if err := os.Chmod(dataFile(cfg.home, "sqlite"), 0o600); err != nil {
		return err
	}
	mcpServers := mcp.New(st)

	reg := agent.NewRegistry()
	claude.Register(reg)
	codex.Register(reg)
	execs := map[domestiquev1.Provider]string{}
	if cfg.Agents.Claude != "" {
		execs[domestiquev1.Provider_PROVIDER_CLAUDE] = expand(cfg.Agents.Claude)
	}
	if cfg.Agents.Codex != "" {
		execs[domestiquev1.Provider_PROVIDER_CODEX] = expand(cfg.Agents.Codex)
	}
	server, err := core.New(core.Options{
		Name: cfg.Name, Version: version, Store: st, Agents: reg, WorkspacesRoot: cfg.WorkspacesRoot,
		ReposRoot: cfg.ReposRoot, BranchPrefix: cfg.BranchPrefix, PortStart: cfg.Ports.Start, PortEnd: cfg.Ports.End, Executables: execs, Log: log,
		McpConfigFile: func() (string, error) { return mcpServers.WriteFile(filepath.Join(cfg.home, "mcp.json")) },
	})
	if err != nil {
		return err
	}
	defer codex.ShutdownServers() // after sessions stop (defers run last-in first-out)
	defer server.Shutdown()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := rpc.NewServer(server, st, log)
	var fixed []sandbox.Configured
	for _, p := range cfg.SandboxProviders {
		c, err := p.configured()
		if err != nil {
			return err
		}
		fixed = append(fixed, c)
	}
	// DOMESTIQUE_SERVER_BOAT_URL points boat.dev calls elsewhere (tests, staging).
	sandboxes, err := sandbox.New(sandbox.Options{Store: st, Configured: fixed, BoatURL: serverEnv("BOAT_URL")})
	if err != nil {
		return err
	}
	srv.SetSandboxes(sandboxes)
	srv.SetMcp(mcpServers)
	errs := make(chan error, len(cfg.Listen))
	for _, addr := range cfg.Listen {
		l, trusted, err := listenOn(addr, cfg, log)
		if err != nil {
			return err
		}
		log.Info("listening", "addr", addr, "token_required", !trusted)
		go func() { errs <- srv.Serve(ctx, l, trusted) }()
	}
	log.Info("server ready", "name", server.ServerName(), "id", server.ServerID(), "version", version, "home", cfg.home)
	select {
	case <-ctx.Done():
		log.Info("shutting down")
	case err := <-errs:
		if err != nil {
			return err
		}
	}
	return nil
}

// openStore opens the database, refusing to migrate a pre-rename one while its older server is running.
func openStore(cfg *Config) (*store.Store, error) {
	path := dataFile(cfg.home, "sqlite")
	legacy, err := store.NeedsRename(path)
	if err != nil {
		return nil, err
	}
	if legacy {
		if c, err := net.DialTimeout("unix", defaultSocket(cfg.home), 500*time.Millisecond); err == nil {
			c.Close()
			return nil, fmt.Errorf("an older server is still running on %s; stop it, then try again", path)
		}
	}
	return store.Open(path)
}

func listenOn(addr string, cfg *Config, log *slog.Logger) (net.Listener, bool, error) {
	u, err := url.Parse(addr)
	if err != nil {
		return nil, false, fmt.Errorf("listen %q: %w", addr, err)
	}
	switch u.Scheme {
	case "unix":
		path := u.Path
		if path == "" {
			path = u.Opaque
		}
		path = expand(path)
		// sockaddr_un holds 104 bytes on macOS (108 on Linux), including the terminator.
		if len(path) > 103 {
			return nil, false, fmt.Errorf("unix socket path is %d bytes; the limit is 103. Use a shorter path (or DOMESTIQUE_SERVER_HOME): %s", len(path), path)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, false, err
		}
		// A stale socket from a crash blocks bind; a live one means another server owns it.
		if c, err := net.DialTimeout("unix", path, 500*time.Millisecond); err == nil {
			c.Close()
			return nil, false, fmt.Errorf("another domestique is already listening on %s", path)
		}
		_ = os.Remove(path)
		old := syscall.Umask(0o077)
		l, err := net.Listen("unix", path)
		syscall.Umask(old)
		if err != nil {
			return nil, false, err
		}
		if err := os.Chmod(path, 0o600); err != nil {
			l.Close()
			return nil, false, err
		}
		return l, true, nil
	case "tcp":
		l, err := net.Listen("tcp", u.Host)
		if err != nil {
			return nil, false, err
		}
		if cfg.TLS.Cert != "" {
			cert, err := tls.LoadX509KeyPair(expand(cfg.TLS.Cert), expand(cfg.TLS.Key))
			if err != nil {
				l.Close()
				return nil, false, fmt.Errorf("tls: %w", err)
			}
			l = tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
		} else if host, _, _ := net.SplitHostPort(u.Host); !isLoopback(host) {
			log.Warn("listening on a non-loopback address WITHOUT TLS: tokens and code travel in clear text unless a proxy or VPN in front encrypts them", "addr", u.Host)
		}
		return l, false, nil
	}
	return nil, false, fmt.Errorf("listen %q: use unix:// or tcp://", addr)
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func tokenCmd(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: domestique token create|list|revoke")
	}
	cfg, err := loadConfig("")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.home, 0o700); err != nil {
		return err
	}
	st, err := openStore(cfg)
	if err != nil {
		return err
	}
	defer st.Close()
	switch args[0] {
	case "create":
		fs := flag.NewFlagSet("token create", flag.ExitOnError)
		name := fs.String("name", "", "a label for the token (e.g. iphone, ci)")
		scope := fs.String("scope", "operate", "read, trigger, operate or admin")
		_ = fs.Parse(args[1:])
		sc, err := parseScope(*scope)
		if err != nil {
			return err
		}
		if *name == "" {
			return errors.New("--name is required")
		}
		info, secret, err := st.CreateToken(*name, sc)
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "Created token %s (%s, scope %s). It is shown once:\n", info.Id, info.Name, *scope)
		fmt.Println(secret)
	case "list":
		ts, err := st.Tokens()
		if err != nil {
			return err
		}
		for _, t := range ts {
			last := "never"
			if t.LastUsedAtMs > 0 {
				last = time.UnixMilli(t.LastUsedAtMs).Format(time.DateTime)
			}
			fmt.Printf("%s\t%s\t%s\tlast used %s\n", t.Id, t.Name, scopeName(t.Scope), last)
		}
	case "revoke":
		if len(args) < 2 {
			return errors.New("usage: domestique token revoke TOKEN_ID")
		}
		return st.RevokeToken(args[1])
	default:
		return fmt.Errorf("unknown token command %q", args[0])
	}
	return nil
}

func parseScope(s string) (domestiquev1.TokenScope, error) {
	switch strings.ToLower(s) {
	case "read":
		return domestiquev1.TokenScope_TOKEN_SCOPE_READ, nil
	case "trigger":
		return domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER, nil
	case "operate":
		return domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE, nil
	case "admin":
		return domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN, nil
	}
	return 0, fmt.Errorf("unknown scope %q (read, trigger, operate, admin)", s)
}

func scopeName(s domestiquev1.TokenScope) string {
	return strings.ToLower(strings.TrimPrefix(s.String(), "TOKEN_SCOPE_"))
}

// extendPath appends lineproc.ExtraPathDirs (Homebrew, ~/.local/bin, ...) to this process's PATH, so the
// existing entries keep precedence.
func extendPath() {
	for _, kv := range lineproc.Environ(nil) {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			os.Setenv("PATH", v)
		}
	}
}
