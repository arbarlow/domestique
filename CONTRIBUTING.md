# Contributing to Domestique

First off, thank you for being here! 🎉

Domestique is a **young project**. It started as one person's daily driver and was opened up early so others could help shape it. Right now, **opinions are as valuable as code**. If a workflow feels wrong, a default seems odd, or you think the architecture should go another way, please say so. Very little is set in stone.

## Ways to contribute

You don't need to write Swift to help:

- **Use it and tell us what hurts.** Friction reports ("I expected X, got Y") are gold.
- **Report bugs** with the [bug report form](https://github.com/arbarlow/domestique/issues/new?template=bug_report.yml).
- **Propose ideas or challenge decisions** with the [feature request form](https://github.com/arbarlow/domestique/issues/new?template=feature_request.yml). That includes "I think `domestique.toml` should work differently" or "why not use X instead of Y?".
- **Improve the docs.** If something confused you, it will confuse the next person too.
- **Write code**: fix bugs, build features, add tests.

## Before you start on something big

For anything larger than a small bug fix, please **open an issue first** and describe what you have in mind. Because the project is moving quickly, a short conversation up front means your work won't clash with something already in flight, and we can agree on the approach before you spend a weekend on it.

Small fixes (typos, obvious bugs, missing tests) can go straight to a pull request.

## Development setup

### Prerequisites

- macOS 26+ on Apple silicon
- Xcode 26+ (Swift 6.2)
- `git`, plus `claude` and/or `codex` installed and logged in if you're touching agent code
- `gh` (logged in) if you're touching GitHub features

### Build

```sh
git clone https://github.com/arbarlow/domestique.git
cd domestique

# Option A: Xcode (full app bundle with icon, recommended for UI work)
open Domestique.xcodeproj           # "Domestique" scheme, then ⌘R
                                    # Accept "Trust & Enable" for the SwiftTerm plugin once

# Option B: SwiftPM (fast loop, no bundle)
swift build
swift run DomestiqueDev

# Release app bundle -> build/Domestique.app
scripts/build-app.sh
```

The Xcode app target compiles `Sources/Domestique` as a synchronized folder, so new files are picked up automatically. It links the `DomestiqueKit` library product from `Package.swift`.

### Keep your real data safe while hacking

By default Domestique stores state in `~/Library/Application Support/Domestique` and worktrees in `~/Domestique/workspaces`. To experiment without touching your real setup:

```sh
DOMESTIQUE_HOME=/tmp/dq-home DOMESTIQUE_WORKSPACES=/tmp/dq-ws swift run DomestiqueDev
```

### Test

```sh
swift test
```

The tests deliberately use **real things** where they can: real child processes and listening ports in `ProcessKitTests`, and a real bare `origin` with real worktrees and real rebases in `GitKitTests`. Please keep it that way. Mocks that drift from reality are how git and process bugs slip through.

| Target | Covers |
|---|---|
| `DQCoreTests` | TOML parsing, `domestique.toml` config, the SQLite store |
| `AgentKitTests` | Mapping Claude and Codex protocol messages to normalised events |
| `GitKitTests` | Worktrees, diffs, commit/push, trunk ship and conflict detection |
| `ProcessKitTests` | PTY processes, ANSI log screen, port detection |

### Debug the agent layer with `dq`

`dq` drives `AgentKit` with no UI and prints the normalised event stream. Use it whenever you change protocol handling:

```sh
swift build
.build/debug/dq chat claude|codex [--mode bypass|auto|ask] [--approve] [--model m] \
  [--cwd dir] [--resume id] "prompt" ["follow-up" ...]
.build/debug/dq models claude|codex
```

## Project layout

```
Sources/
├── Domestique/   SwiftUI app
│   ├── Design/       Theme tokens and shared components. Use these for new UI.
│   ├── Models/       @Observable app, workspace and chat models
│   └── Views/        Sidebar, chat, transcript, right panel, settings
├── AgentKit/     ClaudeSession (stream-json control protocol) and CodexAppServer (JSON-RPC)
├── GitKit/       Worktrees, unified-diff parser, rebase/push
├── GitHubKit/    REST + GraphQL client for PRs and checks
├── ProcessKit/   PTY processes, ANSI rendering, port scanner, task runs
├── DQCore/       Models, SQLite store, TOML parser, repo config, shell helpers
└── dq/           CLI harness
```

**Rule of thumb:** anything that can be tested without a window belongs in a library target, not in `Sources/Domestique`.

## Coding guidelines

- **Swift 6 strict concurrency.** No new warnings, and no `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it's safe.
- **Modern SwiftUI.** Use `@Observable` models rather than `ObservableObject`, and keep logic out of view bodies.
- **Use the design system.** Colours, spacing, and button styles live in `Sources/Domestique/Design/Theme.swift`. Reuse them so the app feels like one thing.
- **Stay native and light.** Prefer Apple frameworks. A new dependency needs a good reason, so discuss it in an issue first.
- **Don't modify the agents.** Domestique talks to the user's unmodified `claude` and `codex` binaries over their public protocols, so it works with people's existing subscriptions. Please keep it that way.
- **Comment the *why*, not the *what*.** Protocol quirks and git edge cases especially deserve a line explaining them.

## Pull requests

1. Fork the repo and create a branch from `master`.
2. Make your change, and add or update tests where it makes sense.
3. Make sure `swift build` and `swift test` pass, and that the app still builds in Xcode.
4. **UI changes:** include before/after screenshots (light and dark if relevant) in the PR description.
5. Open the PR and fill in the template. Link the issue it addresses.

Keep PRs focused, since one logical change per PR makes review much faster. Commit messages should be short and imperative ("Add port range to workspace settings"). We squash on merge, so don't worry about tidying your history.

### Using coding agents to contribute

This project is built for agent-assisted development and largely built *with* it, so go ahead. Just make sure **you** have read and understood every line you submit, that the tests pass, and that the PR description is written for a human reviewer.

## Reporting bugs

A great bug report includes:

- macOS version and Domestique commit (`git rev-parse --short HEAD`)
- Which agent (`claude --version` / `codex --version`) and permission mode
- Steps to reproduce, and what you expected compared with what happened
- Screenshots or logs. For agent issues, running the same prompt through `dq` is incredibly helpful.

**Security vulnerabilities:** please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Code of Conduct

Everyone taking part in this project is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind, and assume good intent.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
