package git

import "testing"

const sample = `diff --git a/a.txt b/a.txt
index 1..2 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
 keep
-old
+new
diff --git a/old.go b/new.go
similarity index 90%
rename from old.go
rename to new.go
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/img.png b/img.png
new file mode 100644
Binary files /dev/null and b/img.png differ
`

func TestParseUnified(t *testing.T) {
	files := ParseUnified(sample)
	if len(files) != 4 {
		t.Fatalf("got %d files", len(files))
	}
	a := files[0]
	if a.Path != "a.txt" || a.Status != Modified || a.Additions != 1 || a.Deletions != 1 || a.Patch == "" {
		t.Fatalf("a = %+v", a)
	}
	r := files[1]
	if r.Path != "new.go" || r.OldPath != "old.go" || r.Status != Renamed {
		t.Fatalf("rename = %+v", r)
	}
	g := files[2]
	if g.Path != "gone.txt" || g.Status != Deleted || g.Deletions != 1 {
		t.Fatalf("delete = %+v", g)
	}
	b := files[3]
	if b.Path != "img.png" || !b.Binary || b.Status != Added || b.Patch != "" {
		t.Fatalf("binary = %+v", b)
	}
}
