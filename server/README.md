# Server

The Domestique server. It runs your coding agents (Claude Code and Codex), git worktrees and
workspace setup, and serves **the Domestique protocol**: protobuf frames over one WebSocket per client.

The Mac app talks to a local server over a Unix socket. You can run more servers on machines you own
and connect the Mac app, the iPhone app (`iOS/`), or your own backend (via the Go SDK) to any of them.

> Status: phase 1 of the [server spec](https://claude.ai/artifact/CXRoVibEkfUz6gycWteGjU). The server,
> protocol, Go SDK, `domestique ctl` and `domestique exec` (remote processes) work end to end. The Mac app
> doesn't use server yet (phase 2). Sandbox providers (below) work: each server owns its boat.dev
> accounts and keys. Ship (PRs, trunk) comes later (the request ids are reserved).

## Run it

```sh
cd server
go build -o domestique ./cmd/domestique
./domestique serve                       # Unix socket only (no token needed; the socket is 0600)
./domestique serve --listen unix:///tmp/tc.sock --listen tcp://127.0.0.1:7420
```

State lives in `DOMESTIQUE_SERVER_HOME`: by default `~/Library/Application Support/Domestique/domestique` on macOS
and `~/.local/share/domestique` on Linux (database `server.sqlite`, socket `server.sock`, optional
`server.toml`). `DOMESTIQUE_SERVER_WORKSPACES_ROOT` and `DOMESTIQUE_SERVER_REPOS_ROOT` override the config's roots.

```toml
# server.toml (every field optional)
listen = ["unix://~/Library/Application Support/Domestique/server/domestique.sock", "tcp://100.64.0.5:7420"]
name = "hetzner-box"
workspaces_root = "~/Domestique/workspaces"
repos_root = "~/Domestique/repos"         # where AddRepository{clone_url} clones to
branch_prefix = "alex"                     # new branches are alex/<workspace>
ports = { start = 41000, end = 50999 }      # workspace port blocks (10 each); the default

[tls]                                       # optional; or terminate TLS in a proxy
cert = "/etc/domestique/cert.pem"
key = "/etc/domestique/key.pem"

[agents]                                    # optional CLI paths
claude = "~/.local/bin/claude"
codex = "codex"
```

The host needs `git`, plus `claude` and/or `codex` installed and logged in.

## MCP servers

Each server keeps a list of MCP servers, with their secrets (environment variables and headers), in
`server.sqlite` (0600). Clients can see which secrets exist but only get the values through
`ResolveMcpConfig`, which needs an OPERATE token; saving needs ADMIN. The Mac app writes the result to
`~/.config/domestique/mcp.json` (0600) on a sandbox each time it starts Claude and passes `--mcp-config`,
so it doesn't matter that boat.dev rewrites Claude's own config. Servers marked "everywhere" also go to
Claude in the server's own worktrees, through `mcp.json` in `DOMESTIQUE_SERVER_HOME`.

## Sandbox providers

Each server owns its sandbox providers: boat.dev accounts with their API key and defaults for new
sandboxes. The key stays on the server. Clients (the Mac app, the phone, your own backends through the
Go SDK) ask the server to create, resume, stop and open sandboxes, so a server on your laptop can be
local-only while one on a server spawns boat.dev machines for everything that connects to it.

Fix providers in `server.toml` (clients can't edit these):

```toml
[[sandbox_providers]]
id = "6f9d1c2e-8a43-4f61-9d0b-2b7f5e1c9a10"   # a UUID; keep it stable
name = "boat · stride"
api_key_env = "STRIDE_BOAT_API_KEY"            # or api_key_file = "/etc/domestique/boat.key"
machine_type = "large"                          # small, default, large, xlarge
auto_stop_minutes = 120                         # unset or 0 = never
environment = "base"                            # boat environment (repos, secrets, AI logins)
from_snapshot = "stride"                        # boat saved snapshot to start from
delete_on_archive = false
```

Without `api_key_env` / `api_key_file`, a provider uses `BOAT_API_KEY`, then the server user's
`boat login` session. Providers can also be saved over the Domestique protocol with an `admin` token, which is
what the Mac app's Settings → Servers does (keys are stored in `server.sqlite`, inside the
`0700` server home):

```sh
domestique ctl sandbox-providers --check                # where each key comes from, and the account
echo "$BOAT_KEY" | domestique ctl add-sandbox-provider "boat · large" --machine-type large --from stride
domestique ctl sandboxes <provider-id>
domestique ctl rm-sandbox-provider <provider-id>
```

Scopes: listing is `read`; creating, resuming, stopping, renaming and auto-stop are `trigger`;
deleting, recovering and access (authorizing an SSH key, desktop and port URLs) are `operate`;
saving and removing providers is `admin`. `DOMESTIQUE_SERVER_BOAT_URL` points the boat.dev calls elsewhere
(tests, staging).

For now the Mac app still drives the workspace inside the sandbox over SSH (the server authorizes the
app's key); running the agents inside the sandbox from the server is the next step.

## Security

You own the network: Tailscale, a VPN, a reverse proxy, TLS. Server only does the minimum:

- By default it listens on the Unix socket only (mode `0600`).
- Every TCP connection must present a token. It warns loudly when listening on a non-loopback address
  without TLS.
- Tokens are 256-bit random secrets (`tc_…`), stored as SHA-256 hashes, revocable, and scoped:

| Scope | Allows |
| --- | --- |
| `read` | Subscriptions, lists, transcripts, diffs, files |
| `trigger` | `read`, plus adding repositories, creating, importing and archiving workspaces, sessions, prompts, approvals |
| `operate` | `trigger`, plus removing repositories, deleting archived workspaces, and running processes (`domestique exec`, terminals) |
| `admin` | Everything, including managing tokens and sandbox providers |

```sh
domestique token create --name iphone --scope operate   # prints the secret once
domestique token list
domestique token revoke tok_1a2b3c
```

## Drive it from the terminal

`domestique ctl` is built on the Go SDK, so it's also the SDK's reference user.

```sh
export DOMESTIQUE_SERVER_URL=ws://100.64.0.5:7420 DOMESTIQUE_SERVER_TOKEN=tc_…   # or omit both for the local socket
domestique ctl info
domestique ctl add-repo git@github.com:acme/api.git
domestique ctl new api --prompt "Add a /health endpoint"
domestique ctl sessions
domestique ctl watch <session-id>
domestique ctl chat <session-id> --approve "now add a test"
domestique ctl diff <workspace>
domestique ctl sandbox-providers --check
```

## Run commands: `domestique exec`

`domestique exec` runs one command on a server and behaves like `ssh host -- cmd` as a transport, so the
Mac app can run git, setup scripts, run tasks and terminals on a remote server by spawning it
exactly where it spawns `ssh -tt` today.

```sh
export DOMESTIQUE_SERVER_URL=wss://server.example.com:7420 DOMESTIQUE_SERVER_TOKEN=tc_…   # operate scope; or the local socket
domestique exec -- git status --porcelain
domestique exec --workspace 6f1c… --shell 'npm install && npm test'
domestique exec --workspace 6f1c… --cwd web --env NODE_ENV=test -- npx vitest run
domestique exec --tty -- htop                                       # interactive, like ssh -t
echo hi | domestique exec -- tr a-z A-Z
```

```text
domestique exec [--url URL] [--workspace ID] [--cwd DIR] [--tty] [--cols N --rows N] [--env K=V]...
             (--shell SCRIPT | -- ARGV...)
```

- **Target.** `ARGV` runs directly (`ARGV[0]` looked up on the process's `PATH`); `--shell SCRIPT` runs
  with the server user's shell and `-c` (`$SHELL` if it's bash, zsh or sh, else `/bin/bash`, else
  `/bin/sh`). `--workspace` adds the workspace's environment (`DOMESTIQUE_PORT`, … the same as setup
  scripts get) and makes a relative `--cwd` relative to the worktree. The default cwd is the
  workspace, else the server user's home. `--env` adds variables on top.
- **Connection.** The URL comes from `--url`, else `$DOMESTIQUE_SERVER_URL`, else the local socket. The token
  comes from `$DOMESTIQUE_SERVER_TOKEN` only (never a flag, so it stays out of `ps`). One dial, one subscribe,
  no reconnects: a dropped connection ends the command.
- **Streams.** Local stdin goes to the remote stdin, and EOF on it closes the remote stdin. Remote
  stdout and stderr go to local stdout and stderr. Nothing is dropped: if the local side reads slowly,
  the remote process is slowed down. All output arrives before the exit status.
- **Exit status.** The remote exit code; `128+N` when the remote was killed by signal `N`; `127` (with
  the reason on stderr) when it couldn't start; `255` with a message on stderr for connection,
  authentication, usage and protocol errors.
- **Signals.** SIGINT, SIGTERM and SIGHUP sent to `domestique exec` are forwarded to the remote process
  group. If `domestique exec` dies (even with SIGKILL), its connection closes and the server hangs the
  remote process up.
- **`--tty`.** The command runs on a pseudo-terminal; stdout and stderr arrive merged. If local stdin
  is a terminal, it's put in raw mode (restored on exit and on signals), its size is used, and window
  size changes are forwarded. Otherwise the size is `--cols`×`--rows` (default 200×50). `$TERM` is
  passed along (`xterm-256color` when unset). A terminal has no EOF: local EOF is ignored (send `^D`).
- **Lifetime.** The remote process runs in its own session and process group. When the connection
  closes or the client unsubscribes, the group gets SIGHUP, then SIGKILL 3 s later if anything in it
  is still alive. When the main process exits, anything it left in its group (background jobs) is
  hung up the same way, and a background job holding stdout open is hung up 1 s after the main
  process exits so the command can end.

## Go SDK

```go
import (
    "github.com/arbarlow/domestique/server/client"
    domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

c, err := client.Dial(ctx, "wss://server.example.com:7420", client.WithToken(os.Getenv("DOMESTIQUE_SERVER_TOKEN")))
repo, err := c.AddRepository(ctx, &domestiquev1.AddRepository{CloneUrl: "git@github.com:acme/api.git"})
ws, err := c.CreateWorkspace(ctx, &domestiquev1.CreateWorkspace{RepositoryId: repo.Id}, client.Idempotent(jobID))
ws, err = c.WaitWorkspace(ctx, ws.Id)
session, err := c.OpenSession(ctx, &domestiquev1.OpenSession{WorkspaceId: ws.Id, Provider: domestiquev1.Provider_PROVIDER_CLAUDE})
turn, err := c.Prompt(ctx, session.Id, "Fix the flaky TestCheckout", client.PromptOptions{
    OnApproval: func(a *domestiquev1.ApprovalRequest) domestiquev1.Decision { return domestiquev1.Decision_DECISION_APPROVE },
})
fmt.Println(turn.Text)
```

Processes are a subscription too:

```go
p, err := c.StartProcess(ctx, &domestiquev1.ProcessTarget{WorkspaceId: ws.Id, Argv: []string{"git", "status"}})
go func() { p.Write(ctx, input); p.CloseStdin(ctx) }()
for o := range p.Output() { // drain it: a full client queue pauses the whole connection
    os.Stdout.Write(o.Data)
}
exit, err := p.Wait() // exit.ExitCode, exit.Signal, exit.Error (couldn't start: code 127)
```

One client multiplexes every request and subscription over one connection. When the connection drops,
it reconnects with backoff and resumes every subscription from its last cursor, so a subscriber sees a
continuous stream. `client.Transcript` folds events the same way the apps do.

## the Domestique protocol in brief

The schema is [`proto/domestique/v1/domestique.proto`](../proto/domestique/v1/domestique.proto) and is the contract.

- The first frame is `Hello` (with a token on TCP). The server answers `Welcome` with the granted scope.
- `Request{id, command}` → `Response{id, result | error}`. Requests run concurrently. Create-type
  requests take an `idempotency_key` (honoured for 10 minutes).
- `Subscribe` returns a subscription id, and its response always arrives before its first event.
  - Server stream: `ServerSnapshot` first, then repository, workspace and session upserts and removals.
  - Session stream: items persisted after `from_seq`, replayed in display order, then `ReplayDone`, then live
    events. Keep the highest `seq` you've seen and resubscribe from it.
- Every transcript write gets the session's next `seq`. Streamed text (`AppendText`) is merged for 33 ms by
  default (`coalesce_ms`) and persisted lazily. A subscribe flushes it first, so a replay plus the live
  stream never loses text.
  - Process stream: `ProcessStarted` (with the `process_id` for input, resize and signal requests), then
    `ProcessOutput` chunks (64 KB at most), then `ProcessExited`. A command that can't start gets only
    `ProcessExited` (code 127, `error` set). Process ids belong to the connection that started them.
    `ProcessInput` requests for one process are applied in the order they arrive and answered once
    written. The SDK never resubscribes a process after a reconnect (it would run the command again);
    `Wait` returns `ErrProcessLost`.
- The server never buffers without limit. A subscriber that falls 1,024 events behind is dropped with a
  `Gap`, and the client resubscribes. Process output is the exception: it's never dropped. At most
  1 MB per process waits on the connection; past that the server stops reading the process's pipes.
- Responses, pongs and gaps go out ahead of stream events, so an approval never waits behind a burst of
  logs.
- Keepalive: the server pings every 15 s and drops a connection it hasn't heard from (any frame, or a
  pong) for 30 s. A client that stops reading to push back on process output can't answer pings, so it
  should send `Ping` frames itself (the Go SDK does, every 15 s).

## Run on a server

Server runs on Linux (amd64, arm64) as well as macOS. `scripts/build-server-dist.sh` (in the repo
root) builds `dist/domestique_<version>_<os>_<arch>.tar.gz` plus a `.sha256` for linux/amd64,
linux/arm64 and darwin/arm64.

**The network is yours.** server listens where you tell it and checks tokens; it doesn't
provide a VPN, a firewall or certificates. Put it on a private network (Tailscale, WireGuard), or
behind a reverse proxy that terminates TLS (Caddy, nginx), or give it a certificate in `[tls]`. Without
one of those, tokens and code travel in clear text, and server warns about it at startup.

### Container

[`deploy/Dockerfile`](deploy/Dockerfile) builds a static `domestique` and a `debian:stable-slim` runtime
with git, openssh-client, curl, bash, gh, Node.js and the `claude` and `codex` CLIs. It runs as the
non-root user `domestique` with `tini` as PID 1, so orphaned processes get reaped. Everything that has to
survive an upgrade lives in the `/data` volume: the database (`DOMESTIQUE_SERVER_HOME=/data/domestique`), repositories
and worktrees, and the user's home (`/data/home`: agent logins, git config, SSH keys).

```sh
cd server
docker build -f deploy/Dockerfile -t domestique --build-arg VERSION=$(git describe --always) .
docker run -d --name domestique --restart unless-stopped -p 127.0.0.1:7420:7420 -v domestique-data:/data domestique
docker logs -f domestique
```

It serves `tcp://0.0.0.0:7420` inside the container. Publish the port only where you mean to (above:
loopback, for a proxy or `tailscale serve` on the host). It also serves a Unix socket in the volume, so
`docker exec domestique domestique ctl info` works without a token.

### systemd

[`deploy/domestique.service`](deploy/domestique.service) is an example unit:

```sh
sudo useradd --system --create-home --home-dir /var/lib/domestique --shell /bin/bash domestique
sudo install -m 0755 domestique /usr/local/bin/domestique
sudo cp deploy/domestique.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now domestique
journalctl -u domestique -f
```

Edit `ExecStart`'s `--listen` to bind a private address (e.g. your Tailscale IP), or `127.0.0.1` behind
a proxy. Install git, gh, and Node.js with the agent CLIs on the host
(`npm install -g @anthropic-ai/claude-code @openai/codex`, or each CLI's own installer).

### Log the agents in, once

Agents and git run as the server's user, with that user's credentials. Log in as that user:

```sh
docker exec -it domestique bash        # container (or: sudo -iu domestique on a systemd host)
claude                              # then /login: open the printed URL anywhere, paste the code back
                                    # (or `claude setup-token` for a long-lived token)
printenv OPENAI_API_KEY | codex login --with-api-key
                                    # or run `codex login` on a machine with a browser and copy
                                    # its ~/.codex/auth.json to the server user's ~/.codex/
gh auth login && gh auth setup-git  # pull requests, and HTTPS git with gh's credentials
git config --global user.name "Your Name" && git config --global user.email you@example.com
ssh-keygen -t ed25519               # for SSH remotes: add ~/.ssh/id_ed25519.pub to GitHub
```

`domestique ctl info` lists the agents it found (`providers`). Set paths in `server.toml`'s `[agents]` if
they aren't on `PATH`.

### Create a token and point the app at it

```sh
docker exec domestique domestique token create --name mac --scope operate   # or: sudo -u domestique env DOMESTIQUE_SERVER_HOME=/var/lib/server/domestique domestique token create …
```

The secret is printed once. In the Mac app, add the server with its URL (`wss://server.example.com`
behind a TLS proxy, `ws://100.x.y.z:7420` on a tailnet) and the token. The app needs the `operate`
scope, because it runs git, scripts and terminals with `domestique exec`, and opens SSH access to the
server's sandboxes. Use an `admin` token to manage the server's sandbox providers from the app. To check
from any machine:

```sh
DOMESTIQUE_SERVER_URL=wss://server.example.com DOMESTIQUE_SERVER_TOKEN=tc_… domestique exec -- uname -a
```

## Develop

```sh
cd proto && buf lint                     # schema rules
cd server && buf generate               # regenerate gen/ (needs protoc-gen-go)
go test -race ./...                      # unit + end-to-end tests (real git, fake agent)
DOMESTIQUE_SERVER_LIVE=1 go test ./internal/agent/... -run Live   # talk to the real claude/codex CLIs
```
