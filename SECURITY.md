# Security Policy

Domestique runs coding agents that can execute commands on your machine, so we take security reports seriously.

## Reporting a vulnerability

**Please do not open a public issue.** Instead, report it privately through GitHub's
[private vulnerability reporting](https://github.com/arbarlow/domestique/security/advisories/new).

Please include:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- The commit you tested against

You should get an acknowledgement within a few days. Once a fix is ready we'll coordinate disclosure with you, and credit you if you'd like.

## Supported versions

Domestique is pre-1.0 and has no release branches yet. Fixes land on `master`.

## Scope notes

- **Full access mode is intentional.** In the default permission mode, agents run with your user's permissions and without approval prompts. That's a documented feature, not a vulnerability. Use **Auto** or **Ask** mode if you want guardrails.
- Domestique reads your GitHub token from `gh auth token` and relies on the `claude` and `codex` CLIs for their own authentication. It does not store credentials itself. Issues where Domestique leaks or mishandles these credentials are absolutely in scope.
