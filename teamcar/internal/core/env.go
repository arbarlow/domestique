package core

import (
	"fmt"
	"net"
	"strconv"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

const portCount = 10

// workspaceEnv is the environment every script, task and agent in a workspace gets.
func workspaceEnv(ws *radiov1.Workspace, repo *radiov1.Repository) map[string]string {
	port := strconv.Itoa(int(ws.PortBase))
	env := map[string]string{
		"DOMESTIQUE":                "1",
		"DOMESTIQUE_WORKSPACE":      ws.Name,
		"DOMESTIQUE_WORKSPACE_PATH": ws.Path,
		"DOMESTIQUE_ROOT_PATH":      repo.Path,
		"DOMESTIQUE_BRANCH":         ws.Branch,
		"DOMESTIQUE_DEFAULT_BRANCH": repo.DefaultBranch,
		"DOMESTIQUE_PORT":           port,
		// Compatibility: scripts written for Conductor read these names.
		"CONDUCTOR_PORT":           port,
		"CONDUCTOR_ROOT_PATH":      repo.Path,
		"CONDUCTOR_WORKSPACE_PATH": ws.Path,
		"CONDUCTOR_WORKSPACE_NAME": ws.Name,
		"CONDUCTOR_DEFAULT_BRANCH": repo.DefaultBranch,
	}
	for i := 0; i < portCount; i++ {
		env[fmt.Sprintf("DOMESTIQUE_PORT_%d", i)] = strconv.Itoa(int(ws.PortBase) + i)
	}
	return env
}

func systemPrompt(ws *radiov1.Workspace, repo *radiov1.Repository) string {
	return fmt.Sprintf(`You are working inside Domestique, in an isolated git worktree for the %q repository.
- Worktree: %s
- Branch: %s (branched from origin/%s)
- This workspace owns ports %d-%d ($DOMESTIQUE_PORT is the first). Use them for any dev servers so parallel workspaces don't collide.
- The user previews, runs tasks, and ships (a pull request, or a push straight to the default branch) from the Domestique UI, so don't push or open PRs unless asked.`,
		repo.Name, ws.Path, ws.Branch, repo.DefaultBranch, ws.PortBase, ws.PortBase+portCount-1)
}

// Default port range for workspaces. Domestique keeps other ranges for other kinds of workspace
// (boat.dev sandboxes use 51000-60999), so blocks never collide on a machine that runs both.
const (
	DefaultPortStart = 41000
	DefaultPortEnd   = 50999
)

// allocatePorts returns the lowest base (start, start+10, ...) in [start, end] not in used whose
// ports are all free. Falls back to start when the range is full.
func allocatePorts(used map[int32]bool, start, end int32) int32 {
	for base := start; base+portCount-1 <= end; base += portCount {
		if used[base] {
			continue
		}
		free := true
		for p := base; p < base+portCount; p++ {
			if portInUse(int(p)) {
				free = false
				break
			}
		}
		if free {
			return base
		}
	}
	return start
}

func portInUse(port int) bool {
	l, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return true
	}
	l.Close()
	return false
}
