<div align="center">

<img src="docs/assets/icon.png" width="128" height="128" alt="Domestique app icon">

# Domestique

**A native macOS home for your coding agents.**<br>
Run Claude Code and Codex side by side, each in its own git worktree, with your dev stack one keystroke away.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Status: early](https://img.shields.io/badge/status-early%20%26%20evolving-orange)](#-project-status)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[Features](#-features) ·
[Getting started](#-getting-started) ·
[Configuration](#-configuration-domestiquetoml) ·
[Architecture](#-architecture) ·
[Contributing](#-contributing)

<br>

<img src="docs/assets/screenshot.png" alt="Domestique: a workspace with a Claude chat, three background agents, the changes panel and the run dock" width="100%">

</div>

---

> In a cycling team, the *domestique* is the rider who does the hard, unglamorous work so the leader can win: fetching bottles, setting the pace, closing gaps. This app does the same for you. Agents grind through tasks in parallel while you stay in charge of what ships.

## 🚧 Project status

**Domestique is brand new.** It started as a personal tool and is being opened up early, on purpose, so the design can be shaped by the people who use it.

That means:

- **Expect rough edges.** Things will change, sometimes in breaking ways, and there are no signed release builds yet. You build it from source.
- **Nothing is set in stone.** The workflow, the config format, the UI and the architecture are all open for discussion. If you think something should work differently, [open an issue](https://github.com/arbarlow/domestique/issues/new/choose). "I'd expect it to work like X" is genuinely useful feedback.
- **Contributions of all sizes are welcome**, from typo fixes to whole features. See [CONTRIBUTING.md](CONTRIBUTING.md).

## ✨ Features

### 🌳 One worktree per task

Every workspace is an isolated **git worktree** branched from a freshly fetched `origin/<default-branch>`. Run five agents on five tasks in the same repo without them stepping on each other or on your main checkout.

### 🤖 Claude Code and Codex, on your own subscriptions

Domestique drives the **unmodified `claude` and `codex` CLIs** you already have installed and logged in. There are no API keys and no proxy. Your existing Claude and ChatGPT plans just work.

- Several chat tabs per workspace, and you can mix Claude and Codex in the same workspace
- Model and reasoning-effort pickers, interrupt (<kbd>⌘</kbd><kbd>.</kbd>), and steer or queue follow-ups while a turn is running
- Background sub-agents shown as live cards, with a summary when they finish
- Three permission modes: **Full access** (default), **Auto**, or **Ask**, where approvals appear as cards in the chat

### 🔍 Review without leaving the app

A right-hand panel with **All files**, **Changes** and **Checks**. Browse the tree, read syntax-highlighted diffs against the merge base, and see CI status for the branch.

<img src="docs/assets/screenshot-light.png" alt="Light mode: a Codex chat with edited-file cards and an inline diff of api/server.py" width="100%">

### ▶️ Your dev stack, per workspace

Define setup scripts, long-running tasks and one-shot checks in a small `domestique.toml`. Hit <kbd>⌘</kbd><kbd>R</kbd> to start the stack. Each workspace gets its own block of ports, so ten copies of your app can run at once without clashing.

- PTY-backed processes with full ANSI colour output, plus an integrated terminal
- Listening ports detected automatically, with **Open :port** one click away
- **Send to agent** hands the current logs to the chat (handy for "why is this crashing?")

<img src="docs/assets/screenshot-run.png" alt="The run dock streaming API and Web task logs while three agents report back" width="100%">

### ☁️ Cloud workspaces (boat.dev)

Run a workspace on a cloud sandbox instead of this Mac. Pick **This Mac** or **boat.dev** per repository (Repository settings → *Run new workspaces on*), or use <kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd> for a one-off cloud workspace.

- Each workspace gets its own [boat.dev](https://boat.dev) sandbox with the repo cloned to `/home/user/<repo>`, on a fresh branch from `origin/<default>`, with your git identity.
- Claude Code, Codex, setup scripts, the run stack and terminals all run **on the sandbox**, over one multiplexed SSH connection per machine. Diffs, files and shipping work the same as local workspaces.
- **Ports are forwarded automatically**: anything the stack or the agent listens on shows up at the same `localhost` port on your Mac, so **Open :port** just works. You can also copy a private or public HTTPS URL for any port.
- The header badge shows machine status and auto-stop time, with actions to open the desktop (60fps, in your browser), extend or disable auto-stop, stop or start the machine, and copy the SSH command. A stopped sandbox doesn't bill, and it restarts by itself when you send a message, run the stack or open a terminal.
- Archiving a workspace stops its sandbox, which is kept for 14 days. Deleting the workspace deletes the sandbox.

Setup: sign in once with `boat login` (Domestique reuses the CLI's login), or paste an API key in **Settings → Cloud**. Agents in sandboxes use the Claude/ChatGPT accounts you connect on boat.dev's **Agents & Proxying** page. If boat.dev's GitHub app can't access a repo, Domestique can give the sandbox your `gh` token (Settings → Cloud).

### 🚀 Ship it your way

- **Pull requests:** create the PR, watch checks, merge or enable auto-merge, and **Fix CI**, which pulls the failing job logs into the chat for the agent.
- **Trunk-based:** **Push to main** rebases onto `origin`, runs your gate tasks, and fast-forward pushes, with retries and conflict detection.

### ⚡ Native and lightweight

Pure SwiftUI on macOS 26, with no Electron, no web views and no Node sidecar. State lives in a single local SQLite database. Nothing leaves your machine except what your agents and `git` send.

## 🏁 Getting started

### Requirements

| | |
|---|---|
| **macOS** | 26 or later (Apple silicon) |
| **Xcode** | 26 or later (Swift 6.2 toolchain) |
| **git** | on your login-shell `PATH` |
| **Agents** | [`claude`](https://docs.anthropic.com/en/docs/claude-code) and/or [`codex`](https://github.com/openai/codex), installed and logged in |
| **GitHub** *(optional)* | [`gh`](https://cli.github.com), logged in with `gh auth login`, for PRs and checks |

### Build and run

```sh
git clone https://github.com/arbarlow/domestique.git
cd domestique
open Domestique.xcodeproj    # select the "Domestique" scheme, then press ⌘R
```

The first build asks you to **Trust & Enable** SwiftTerm's build plugin. Accept it once.

Prefer the terminal?

```sh
scripts/build-app.sh             # Release build -> build/Domestique.app
open build/Domestique.app
```

### Your first workspace

1. **Add a repository** with <kbd>⌘</kbd><kbd>⇧</kbd><kbd>O</kbd> and choose any local git checkout.
2. **Create a workspace** with <kbd>⌘</kbd><kbd>N</kbd>. Domestique fetches, branches, and sets up a fresh worktree.
3. **Ask an agent** to do something. Open more tabs with <kbd>⌘</kbd><kbd>T</kbd> to run Claude and Codex in parallel.
4. **Run your stack** with <kbd>⌘</kbd><kbd>R</kbd>, review the **Changes** tab, then **Create PR** or **Push to main**.

You can also launch straight into a repo:

```sh
Domestique --add-repo ~/code/my-app --prompt "Add a /health endpoint"
```

## ⌨️ Keyboard shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd><kbd>N</kbd> | New workspace |
| <kbd>⌘</kbd><kbd>T</kbd> | New chat tab |
| <kbd>⌃</kbd><kbd>`</kbd> | New terminal |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>O</kbd> | Add repository |
| <kbd>⌘</kbd><kbd>R</kbd> | Run stack |
| <kbd>⌘</kbd><kbd>.</kbd> | Stop agent |
| <kbd>⌘</kbd><kbd>↩</kbd> | Allow a pending approval (Ask mode) |
| <kbd>⌘</kbd><kbd>\\</kbd> | Toggle sidebar |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>I</kbd> | Toggle right panel |
| <kbd>⌘</kbd><kbd>J</kbd> | Toggle run dock |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>1</kbd> / <kbd>2</kbd> / <kbd>3</kbd> | All files / Changes / Checks |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>P</kbd> | Primary ship action (Create PR, Merge, Push to main…) |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd> | Open workspace in your editor |
| <kbd>⌘</kbd><kbd>,</kbd> | Settings |

## 🛠 Configuration: `domestique.toml`

Drop a `domestique.toml` in the root of your repo. Every section is optional.

```toml
[setup]
script = "bun install"
copy = [".env", ".env.local"]        # copied from your main checkout into each worktree

[archive]
script = "docker compose down"       # runs when a workspace is archived

[tasks.api]
name = "API"
command = "bun run dev:api"
env = { PORT = "$DOMESTIQUE_PORT" }
ready_port = "$DOMESTIQUE_PORT"      # task counts as "ready" once this port is listening

[tasks.web]
command = "bun run dev:web -- --port $DOMESTIQUE_PORT_1"
open = "http://localhost:$DOMESTIQUE_PORT_1"

[tasks.test]
command = "bun test"
kind = "oneshot"

[stacks.dev]                          # ⌘R runs the first stack
tasks = ["api", "web"]

[trunk]
gate = ["test"]                       # must pass before "Push to main"
```

**Environment available to every script and task:**

| Variable | Value |
|---|---|
| `DOMESTIQUE_PORT`, `DOMESTIQUE_PORT_0` … `_9` | Ten ports reserved for this workspace |
| `DOMESTIQUE_WORKSPACE` | Workspace name |
| `DOMESTIQUE_WORKSPACE_PATH` | Absolute path of the worktree |
| `DOMESTIQUE_ROOT_PATH` | Your main checkout |
| `DOMESTIQUE_BRANCH` | The workspace branch |
| `DOMESTIQUE_DEFAULT_BRANCH` | e.g. `main` |

Worktrees live in `~/Domestique/workspaces/<repo>/<name>`. Override the locations with `DOMESTIQUE_HOME` (app data) and `DOMESTIQUE_WORKSPACES` (worktrees), which is handy for testing.

## 🏗 Architecture

Domestique is a Swift package plus a thin Xcode app target. Everything below the UI is a plain library you can test headlessly.

```
Sources/
├── Domestique/   SwiftUI app: views, models, design system
├── AgentKit/     Claude Code + Codex sessions, normalised into one event stream
├── GitKit/       worktrees, diffs, commit/push, trunk ship
├── GitHubKit/    PRs, checks, merge, failing-job logs
├── ProcessKit/   PTY processes, ANSI logs, port detection (local and remote)
├── HostKit/      cloud machines: boat.dev API, multiplexed SSH, port forwarding
├── DQCore/       models, SQLite store, TOML config, shell helpers
└── dq/           CLI harness for the agent layer
```

| Piece | How it works |
|---|---|
| **Claude** | Spawns the `claude` binary once per tab with `--input-format stream-json --output-format stream-json --permission-prompt-tool stdio`, and speaks the same stdio control protocol as the official Agent SDK (initialize, `can_use_tool`, interrupt, `set_model`, `set_permission_mode`) natively in Swift. |
| **Codex** | One shared `codex app-server` (JSON-RPC over stdio) for all Codex tabs: `thread/start` and `thread/resume`, `turn/start`, `turn/steer` and `turn/interrupt`, plus approval requests. |
| **Permissions** | **Full access**: Claude `bypassPermissions`, Codex `never` + `danger-full-access`. **Auto**: Claude `auto`, Codex `auto_review`. **Ask**: every approval becomes a card in the chat. |
| **GitHub** | Token from `gh auth token`. PR status is a single GraphQL query. |
| **Processes** | Each task runs in its own process group on a PTY. Listening ports are found via `libproc`. |
| **State** | `~/Library/Application Support/Domestique/domestique.sqlite` (WAL mode, so several app instances stay in sync). |

## 🧑‍💻 Development

```sh
swift build && swift test        # libraries, tests and the dq harness
swift run DomestiqueDev          # the same UI without an app bundle (quick dev loop)
```

**`dq`** drives the agent layer with no UI and prints the normalised event stream. It's great for debugging protocol changes:

```sh
.build/debug/dq chat claude --mode bypass "list the files in this repo"
.build/debug/dq chat codex --mode ask --approve --cwd ~/code/my-app "run the tests" "now fix the failures"
```

Tests use real processes, real ports, and a real bare `origin` with real worktrees, not mocks. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development guide.

## 🗺 Roadmap

These are ideas, not promises, and we'd love your input on them:

- [ ] Signed, notarised release builds and auto-update
- [x] Cloud workspaces on boat.dev
- [ ] More cloud providers behind the same `ExecutionHost` interface
- [ ] More agents behind the same `AgentSession` interface
- [ ] Richer review: inline comments on diffs sent back to the agent
- [ ] Linear / GitHub Issues as workspace starting points

Have a different idea? [Start a conversation](https://github.com/arbarlow/domestique/issues/new/choose).

## 🤝 Contributing

Domestique is early, so this is a great time to get involved. Your feedback will shape how it works.

- 🐛 **Found a bug?** [Report it](https://github.com/arbarlow/domestique/issues/new?template=bug_report.yml)
- 💡 **Have an idea, or disagree with a design choice?** [Propose it](https://github.com/arbarlow/domestique/issues/new?template=feature_request.yml)
- 🔧 **Want to write code?** Read [CONTRIBUTING.md](CONTRIBUTING.md), then pick up any issue labelled [`good first issue`](https://github.com/arbarlow/domestique/labels/good%20first%20issue)

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md). For security issues, see [SECURITY.md](SECURITY.md).

## 🙏 Acknowledgements

- [Conductor](https://conductor.build), [T3 Code](https://github.com/pingdotgg/t3code) and the [Codex app](https://openai.com/codex), whose workflows and polish inspired this project
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza, which powers the terminal
- [Claude Code](https://www.anthropic.com/claude-code) and [Codex](https://github.com/openai/codex), the agents doing the actual riding

Domestique is an independent project. It is not affiliated with or endorsed by Anthropic, OpenAI, or Conductor.

## 📄 License

[MIT](LICENSE) © Alex Barlow

<div align="center">
<br>
<sub>Built with ☕ and a lot of agents, all pulling in the same direction.</sub>
</div>
