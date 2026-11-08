// Package git is a thin wrapper over the system git. Everything shells out so worktrees,
// credentials, hooks and config behave exactly like the user's terminal.
package git

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// MaxDiffLinesPerFile: patches with more changed lines are dropped (TooLarge).
const MaxDiffLinesPerFile = 10_000

// MaxUntrackedFileBytes: untracked files larger than this are not read for diffs.
const MaxUntrackedFileBytes = 1_000_000

var quietEnv = []string{
	"GIT_TERMINAL_PROMPT=0",
	"GIT_OPTIONAL_LOCKS=0",
	"GIT_EDITOR=true",
	"GIT_SEQUENCE_EDITOR=true",
	"GIT_MERGE_AUTOEDIT=no",
	"LC_ALL=C",
}

// Error is a failed git command.
type Error struct {
	Args   []string
	Code   int
	Stderr string
}

func (e *Error) Error() string {
	msg := strings.TrimSpace(e.Stderr)
	if msg == "" {
		msg = fmt.Sprintf("exit status %d", e.Code)
	}
	return fmt.Sprintf("git %s: %s", strings.Join(e.Args, " "), msg)
}

type result struct {
	stdout string
	stderr string
	code   int
}

func run(ctx context.Context, dir string, args ...string) (result, error) {
	full := append([]string{"-c", "core.quotePath=false", "-c", "color.ui=false"}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), quietEnv...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	r := result{stdout: out.String(), stderr: errb.String()}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			r.code = ee.ExitCode()
			return r, nil
		}
		return r, err
	}
	return r, nil
}

// Run runs git and fails on a non-zero exit.
func Run(ctx context.Context, dir string, args ...string) (string, error) {
	r, err := run(ctx, dir, args...)
	if err != nil {
		return "", err
	}
	if r.code != 0 {
		return "", &Error{Args: args, Code: r.code, Stderr: r.stderr}
	}
	return r.stdout, nil
}

func output(ctx context.Context, dir string, args ...string) (string, error) {
	s, err := Run(ctx, dir, args...)
	return strings.TrimSpace(s), err
}

func succeeds(ctx context.Context, dir string, args ...string) bool {
	r, err := run(ctx, dir, args...)
	return err == nil && r.code == 0
}

// RepoInfo describes a clone.
type RepoInfo struct {
	Root          string
	RemoteURL     string
	DefaultBranch string
}

// Info inspects the clone at path.
func Info(ctx context.Context, path string) (RepoInfo, error) {
	root, err := output(ctx, path, "rev-parse", "--show-toplevel")
	if err != nil {
		return RepoInfo{}, err
	}
	info := RepoInfo{Root: root}
	if r, err := run(ctx, root, "remote", "get-url", "origin"); err == nil && r.code == 0 {
		info.RemoteURL = strings.TrimSpace(r.stdout)
	}
	info.DefaultBranch = defaultBranch(ctx, root, info.RemoteURL != "")
	return info, nil
}

func defaultBranch(ctx context.Context, root string, hasRemote bool) string {
	if r, err := run(ctx, root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil && r.code == 0 {
		name := strings.TrimSpace(r.stdout)
		if s, ok := strings.CutPrefix(name, "origin/"); ok {
			return s
		}
		if name != "" {
			return name
		}
	}
	if hasRemote {
		if r, err := run(ctx, root, "ls-remote", "--symref", "origin", "HEAD"); err == nil && r.code == 0 {
			for _, line := range strings.Split(r.stdout, "\n") {
				if rest, ok := strings.CutPrefix(line, "ref: refs/heads/"); ok {
					if i := strings.IndexAny(rest, "\t "); i >= 0 {
						return rest[:i]
					}
				}
			}
		}
	}
	for _, c := range []string{"main", "master"} {
		if succeeds(ctx, root, "show-ref", "--verify", "--quiet", "refs/remotes/origin/"+c) {
			return c
		}
	}
	for _, c := range []string{"main", "master"} {
		if succeeds(ctx, root, "show-ref", "--verify", "--quiet", "refs/heads/"+c) {
			return c
		}
	}
	return "main"
}

// Clone clones url into path, which must not exist.
func Clone(ctx context.Context, url, path string) error {
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	_, err := Run(ctx, parent, "clone", url, path)
	return err
}

// Fetch fetches one branch from origin.
func Fetch(ctx context.Context, repoPath, branch string) error {
	_, err := Run(ctx, repoPath, "fetch", "origin", branch, "--prune")
	return err
}

// HasRemote reports whether the repo has an origin remote.
func HasRemote(ctx context.Context, repoPath string) bool {
	return succeeds(ctx, repoPath, "remote", "get-url", "origin")
}

// CreateWorktree creates path as a new worktree on a new branch starting at base (e.g.
// "origin/main"). Returns the base commit sha.
func CreateWorktree(ctx context.Context, repoPath, path, branch, base string) (string, error) {
	if succeeds(ctx, repoPath, "show-ref", "--verify", "--quiet", "refs/heads/"+branch) {
		return "", fmt.Errorf("a branch named %s already exists in %s", branch, repoPath)
	}
	if _, err := os.Stat(path); err == nil {
		return "", fmt.Errorf("%s already exists", path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	sha, err := output(ctx, repoPath, "rev-parse", base+"^{commit}")
	if err != nil {
		return "", err
	}
	if _, err := Run(ctx, repoPath, "worktree", "add", "--no-track", "-b", branch, path, sha); err != nil {
		return "", err
	}
	return sha, nil
}

// RemoveWorktree removes a worktree. Succeeds if the directory is already gone.
func RemoveWorktree(ctx context.Context, repoPath, path string, force bool) error {
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, path)
	r, err := run(ctx, repoPath, args...)
	if err != nil {
		return err
	}
	if r.code != 0 {
		if _, statErr := os.Stat(path); statErr == nil {
			return &Error{Args: args, Code: r.code, Stderr: r.stderr}
		}
	}
	_, _ = run(ctx, repoPath, "worktree", "prune")
	return nil
}

// ValidBranchName reports whether name is a valid new branch name (git check-ref-format --branch).
func ValidBranchName(ctx context.Context, name string) bool {
	if name == "" || strings.HasPrefix(name, "-") || strings.HasPrefix(name, "@") {
		return false
	}
	return succeeds(ctx, "", "check-ref-format", "--branch", name)
}

// DeleteBranch force-deletes a local branch.
func DeleteBranch(ctx context.Context, repoPath, branch string) error {
	_, err := Run(ctx, repoPath, "branch", "-D", branch)
	return err
}

// ListFiles lists tracked and untracked (not ignored) files, minus ones deleted in the working tree.
func ListFiles(ctx context.Context, path string) ([]string, error) {
	out, err := Run(ctx, path, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	deleted, err := Run(ctx, path, "ls-files", "-z", "--deleted")
	if err != nil {
		return nil, err
	}
	gone := map[string]bool{}
	for _, f := range splitZ(deleted) {
		gone[f] = true
	}
	seen := map[string]bool{}
	var files []string
	for _, f := range splitZ(out) {
		if !gone[f] && !seen[f] {
			seen[f] = true
			files = append(files, f)
		}
	}
	sort.Strings(files)
	return files, nil
}

// AheadBehind counts commits HEAD is ahead of / behind base.
func AheadBehind(ctx context.Context, path, base string) (ahead, behind int, err error) {
	out, err := output(ctx, path, "rev-list", "--left-right", "--count", base+"...HEAD")
	if err != nil {
		return 0, 0, err
	}
	parts := strings.Fields(out)
	if len(parts) != 2 {
		return 0, 0, nil
	}
	behind, _ = strconv.Atoi(parts[0])
	ahead, _ = strconv.Atoi(parts[1])
	return ahead, behind, nil
}

func splitZ(s string) []string {
	var out []string
	for _, p := range strings.Split(s, "\x00") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
