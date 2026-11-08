package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"golang.org/x/term"

	"github.com/arbarlow/domestique/server/client"
	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

const execUsage = `domestique exec: run a command on a server, like ssh

Usage:
  domestique exec [flags] -- ARGV...
  domestique exec [flags] --shell SCRIPT

Flags:
  --url URL        unix:///path.sock, ws://host:port or wss://host:port
                   (default: $DOMESTIQUE_SERVER_URL, else the local socket)
  --workspace ID   run in this workspace (relative --cwd resolves against it; its env is added)
  --cwd DIR        working directory (default: the workspace, else the server user's home)
  --env K=V        extra environment variable (repeatable)
  --shell SCRIPT   run SCRIPT with the server user's shell (-c) instead of ARGV
  --tty            run on a pseudo-terminal (stdout and stderr merge)
  --cols N --rows N  terminal size when stdin isn't a terminal (default 200x50)

The token comes from $DOMESTIQUE_SERVER_TOKEN. stdin, stdout and stderr are wired through; the exit status
is the remote command's (128+N when killed by signal N, 127 when it couldn't start) and 255 for
connection, authentication and protocol errors.
`

// execFailure is how `domestique exec` reports a local failure: exit 255 with a message, like ssh.
const execFailure = 255

func execCmd(args []string) int {
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	urlFlag := fs.String("url", "", "")
	workspace := fs.String("workspace", "", "")
	cwd := fs.String("cwd", "", "")
	shell := fs.String("shell", "", "")
	tty := fs.Bool("tty", false, "")
	cols := fs.Uint("cols", 200, "")
	rows := fs.Uint("rows", 50, "")
	var envs multiFlag
	fs.Var(&envs, "env", "")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(os.Stderr, execUsage)
			return execFailure
		}
		return execFail("%v\n\n%s", err, execUsage)
	}
	argv := fs.Args()
	switch {
	case *shell != "" && len(argv) > 0:
		return execFail("give --shell SCRIPT or -- ARGV, not both")
	case *shell == "" && len(argv) == 0:
		return execFail("nothing to run\n\n%s", execUsage)
	}
	env := map[string]string{}
	for _, kv := range envs {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || k == "" {
			return execFail("--env wants K=V, got %q", kv)
		}
		env[k] = v
	}

	target := &domestiquev1.ProcessTarget{WorkspaceId: *workspace, Cwd: *cwd, Argv: argv, Shell: *shell, Env: env, Tty: *tty}
	stdinTerm := term.IsTerminal(int(os.Stdin.Fd()))
	raw := *tty && stdinTerm
	if *tty {
		target.Cols, target.Rows = uint32(*cols), uint32(*rows)
		if raw {
			if w, h, err := term.GetSize(int(os.Stdin.Fd())); err == nil && w > 0 && h > 0 {
				target.Cols, target.Rows = uint32(w), uint32(h)
			}
		}
		if _, ok := env["TERM"]; !ok && os.Getenv("TERM") != "" {
			env["TERM"] = os.Getenv("TERM")
		}
	}

	u := *urlFlag
	if u == "" {
		u = serverEnv("URL")
	}
	if u == "" {
		u = "unix://" + defaultSocket(homeDir())
	}
	ctx := context.Background()
	c, err := client.Dial(ctx, u, client.WithToken(serverEnv("TOKEN")), client.WithoutReconnect(),
		client.WithClientName("domestique exec "+version), client.WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	if err != nil {
		return execFail("%v", err)
	}
	// No c.Close(): its close handshake is a round trip spent on nothing. Exiting closes the socket,
	// which ends the subscription (and hangs the process up if it's still running).

	// Catch signals before starting, so none is lost in between.
	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	if raw {
		signal.Notify(sigs, syscall.SIGWINCH)
	}

	p, err := c.StartProcess(ctx, target)
	if err != nil {
		return execFail("%v", err)
	}

	restore := func() {}
	if raw {
		if st, err := term.MakeRaw(int(os.Stdin.Fd())); err == nil {
			restore = func() { _ = term.Restore(int(os.Stdin.Fd()), st) }
		}
	}
	defer restore()

	go func() {
		for sig := range sigs {
			s := sig.(syscall.Signal)
			if s == syscall.SIGWINCH {
				if w, h, err := term.GetSize(int(os.Stdin.Fd())); err == nil && w > 0 && h > 0 {
					_ = p.Resize(ctx, uint32(w), uint32(h))
				}
				continue
			}
			if raw {
				// The keyboard can't send these in raw mode (^C arrives as a byte), so this is someone
				// killing us: restore the terminal and go. The server hangs the process up.
				restore()
				os.Exit(128 + int(s))
			}
			_ = p.Signal(ctx, s)
		}
	}()

	if p.ID() != "" {
		go pumpStdin(ctx, p, *tty)
	}

	for o := range p.Output() {
		w := os.Stdout
		if o.Stream == domestiquev1.OutputStream_OUTPUT_STREAM_STDERR {
			w = os.Stderr
		}
		if _, err := w.Write(o.Data); err != nil {
			restore()
			return execFail("writing output: %v", err)
		}
	}
	ex, err := p.Wait()
	restore()
	if err != nil {
		return execFail("%v", err)
	}
	switch {
	case ex.Error != "":
		fmt.Fprintf(os.Stderr, "domestique exec: %s\n", ex.Error)
		return int(ex.ExitCode)
	case ex.Signal > 0:
		return 128 + int(ex.Signal)
	case ex.ExitCode < 0 || ex.ExitCode > 255:
		return execFailure
	}
	return int(ex.ExitCode)
}

// pumpStdin forwards local stdin; EOF closes the remote stdin (pipes) like ssh. Errors end it
// quietly: the process may simply have stopped reading, and its exit is what counts.
func pumpStdin(ctx context.Context, p *client.Process, tty bool) {
	buf := make([]byte, 256<<10)
	for {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			if p.Write(ctx, buf[:n]) != nil {
				return
			}
		}
		if err != nil {
			if !tty {
				_ = p.CloseStdin(ctx)
			}
			return
		}
	}
}

func execFail(format string, a ...any) int {
	fmt.Fprintf(os.Stderr, "domestique exec: "+format+"\n", a...)
	return execFailure
}
