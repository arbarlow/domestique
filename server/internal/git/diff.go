package git

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FileStatus of a file in a diff.
type FileStatus int

const (
	Modified FileStatus = iota
	Added
	Deleted
	Renamed
)

// FileDiff is one file's change against the merge base.
type FileDiff struct {
	Path      string
	OldPath   string
	Status    FileStatus
	Additions int
	Deletions int
	// Unified diff for this file, starting at its "diff --git" line. Empty when Binary or TooLarge.
	Patch    string
	Binary   bool
	TooLarge bool
}

// Diff is the working tree (committed + staged + unstaged + untracked) vs merge-base(HEAD, base).
// Returns the merge base used and the files, sorted by path.
func Diff(ctx context.Context, path, base string) (string, []FileDiff, error) {
	from := base
	if mb, err := output(ctx, path, "merge-base", "HEAD", base); err == nil && mb != "" {
		from = mb
	}
	out, err := Run(ctx, path, "diff", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/", from)
	if err != nil {
		return "", nil, err
	}
	files := ParseUnified(out)
	tracked := map[string]bool{}
	for _, f := range files {
		tracked[f.Path] = true
	}
	untracked, err := Run(ctx, path, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return "", nil, err
	}
	for _, rel := range splitZ(untracked) {
		if !tracked[rel] {
			files = append(files, untrackedDiff(path, rel))
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return from, files, nil
}

// ParseUnified splits `git diff` output into per-file diffs and counts lines.
func ParseUnified(out string) []FileDiff {
	var files []FileDiff
	var cur *FileDiff
	var patch strings.Builder
	inHunk := false
	flush := func() {
		if cur == nil {
			return
		}
		if cur.Additions+cur.Deletions > MaxDiffLinesPerFile {
			cur.TooLarge = true
		} else if !cur.Binary {
			cur.Patch = patch.String()
		}
		files = append(files, *cur)
		cur = nil
		patch.Reset()
	}
	for _, line := range strings.SplitAfter(out, "\n") {
		if line == "" {
			continue
		}
		trimmed := strings.TrimRight(line, "\n")
		if strings.HasPrefix(trimmed, "diff --git ") {
			flush()
			cur = &FileDiff{Status: Modified}
			inHunk = false
			if a, b, ok := parseGitHeader(trimmed); ok {
				cur.OldPath, cur.Path = a, b
			}
			patch.WriteString(line)
			continue
		}
		if cur == nil {
			continue
		}
		patch.WriteString(line)
		if inHunk {
			switch {
			case strings.HasPrefix(trimmed, "+"):
				cur.Additions++
			case strings.HasPrefix(trimmed, "-"):
				cur.Deletions++
			}
			continue
		}
		switch {
		case strings.HasPrefix(trimmed, "@@"):
			inHunk = true
		case strings.HasPrefix(trimmed, "new file mode"):
			cur.Status = Added
		case strings.HasPrefix(trimmed, "deleted file mode"):
			cur.Status = Deleted
		case strings.HasPrefix(trimmed, "rename from "):
			cur.Status = Renamed
			cur.OldPath = strings.TrimPrefix(trimmed, "rename from ")
		case strings.HasPrefix(trimmed, "rename to "):
			cur.Path = strings.TrimPrefix(trimmed, "rename to ")
		case strings.HasPrefix(trimmed, "Binary files "):
			cur.Binary = true
		case strings.HasPrefix(trimmed, "--- "):
			if p := strings.TrimPrefix(trimmed, "--- "); p != "/dev/null" {
				cur.OldPath = strings.TrimPrefix(p, "a/")
			}
		case strings.HasPrefix(trimmed, "+++ "):
			if p := strings.TrimPrefix(trimmed, "+++ "); p != "/dev/null" {
				cur.Path = strings.TrimPrefix(p, "b/")
			}
		}
	}
	flush()
	for i := range files {
		if files[i].Status != Renamed {
			if files[i].Path == "" {
				files[i].Path = files[i].OldPath
			}
			files[i].OldPath = ""
		}
	}
	return files
}

// parseGitHeader parses "diff --git a/x b/y" for unquoted paths. Renames and quoted paths are
// fixed up from later header lines.
func parseGitHeader(line string) (string, string, bool) {
	rest := strings.TrimPrefix(line, "diff --git ")
	if !strings.HasPrefix(rest, "a/") {
		return "", "", false
	}
	// Paths are equal unless renamed, so split in the middle when both halves match.
	if i := strings.Index(rest, " b/"); i >= 0 {
		return rest[2:i], rest[i+3:], true
	}
	return "", "", false
}

func untrackedDiff(root, rel string) FileDiff {
	f := FileDiff{Path: rel, Status: Added}
	full := filepath.Join(root, rel)
	st, err := os.Stat(full)
	if err != nil || st.IsDir() {
		return f
	}
	if st.Size() > MaxUntrackedFileBytes {
		f.TooLarge = true
		return f
	}
	data, err := os.ReadFile(full)
	if err != nil || len(data) == 0 {
		return f
	}
	if bytes.IndexByte(data[:min(len(data), 8000)], 0) >= 0 {
		f.Binary = true
		return f
	}
	text := string(data)
	lines := strings.Split(text, "\n")
	endsWithNewline := lines[len(lines)-1] == ""
	if endsWithNewline {
		lines = lines[:len(lines)-1]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n", rel, rel, rel, len(lines))
	for _, l := range lines {
		b.WriteString("+")
		b.WriteString(l)
		b.WriteString("\n")
	}
	if !endsWithNewline {
		b.WriteString("\\ No newline at end of file\n")
	}
	f.Additions = len(lines)
	if f.Additions > MaxDiffLinesPerFile {
		f.TooLarge = true
		return f
	}
	f.Patch = b.String()
	return f
}
