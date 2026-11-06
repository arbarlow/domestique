package lineproc

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// ExtraPathDirs are the places agent CLIs commonly live that a non-login environment (launchd,
// systemd) misses: Homebrew, ~/.local/bin (the claude installer), ~/.bun/bin and nvm's node bins
// (codex is an npm package). Mirrors what Domestique gets from capturing the login shell's PATH.
func ExtraPathDirs() []string {
	home, _ := os.UserHomeDir()
	dirs := []string{"/opt/homebrew/bin", "/usr/local/bin"}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, ".local", "bin"), filepath.Join(home, ".bun", "bin"))
		dirs = append(dirs, nvmBins(home)...)
	}
	return dirs
}

// nvmBins lists ~/.nvm/versions/node/*/bin, newest version first.
func nvmBins(home string) []string {
	matches, _ := filepath.Glob(filepath.Join(home, ".nvm", "versions", "node", "*", "bin"))
	sort.Slice(matches, func(i, j int) bool {
		return versionLess(filepath.Base(filepath.Dir(matches[j])), filepath.Base(filepath.Dir(matches[i])))
	})
	return matches
}

// versionLess compares "v22.14.0"-style versions numerically.
func versionLess(a, b string) bool {
	pa := strings.Split(strings.TrimPrefix(a, "v"), ".")
	pb := strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := 0; i < len(pa) && i < len(pb); i++ {
		var na, nb int
		fmt.Sscanf(pa[i], "%d", &na)
		fmt.Sscanf(pb[i], "%d", &nb)
		if na != nb {
			return na < nb
		}
	}
	return len(pa) < len(pb)
}

// Environ returns this process's environment with PATH extended by ExtraPathDirs (appended, so the
// existing PATH keeps precedence), then extra applied on top. Variables that would make a nested
// agent CLI think it runs inside another agent session are removed.
func Environ(extra map[string]string) []string {
	env := map[string]string{}
	var order []string
	for _, kv := range os.Environ() {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if _, seen := env[k]; !seen {
			order = append(order, k)
		}
		env[k] = v
	}
	delete(env, "CLAUDECODE")
	path := env["PATH"]
	if path == "" {
		path = "/usr/bin:/bin:/usr/sbin:/sbin"
		if _, ok := env["PATH"]; !ok {
			order = append(order, "PATH")
		}
	}
	have := map[string]bool{}
	for _, d := range filepath.SplitList(path) {
		have[d] = true
	}
	for _, d := range ExtraPathDirs() {
		if !have[d] {
			path += string(os.PathListSeparator) + d
			have[d] = true
		}
	}
	env["PATH"] = path
	if env["TERM"] == "" {
		if _, ok := env["TERM"]; !ok {
			order = append(order, "TERM")
		}
		env["TERM"] = "xterm-256color"
	}
	for k, v := range extra {
		if _, ok := env[k]; !ok {
			order = append(order, k)
		}
		env[k] = v
	}
	out := make([]string, 0, len(order))
	for _, k := range order {
		if v, ok := env[k]; ok {
			out = append(out, k+"="+v)
		}
	}
	return out
}

// ErrNotFound is returned by LookPath when the binary can't be found.
var ErrNotFound = errors.New("not found")

// LookPath resolves an agent CLI: explicit (a path, or a name) if set, else name. Names are looked
// up on PATH and then in ExtraPathDirs.
func LookPath(explicit, name string) (string, error) {
	want := name
	if explicit != "" {
		want = explicit
	}
	if strings.Contains(want, "/") {
		p := want
		if strings.HasPrefix(p, "~/") {
			home, _ := os.UserHomeDir()
			p = filepath.Join(home, p[2:])
		}
		if isExecutable(p) {
			return p, nil
		}
		return "", fmt.Errorf("couldn't run %s: %w", want, ErrNotFound)
	}
	if p, err := exec.LookPath(want); err == nil {
		if abs, err := filepath.Abs(p); err == nil {
			return abs, nil
		}
		return p, nil
	}
	for _, d := range ExtraPathDirs() {
		p := filepath.Join(d, want)
		if isExecutable(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("couldn't find `%s` on PATH: %w", want, ErrNotFound)
}

func isExecutable(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}
