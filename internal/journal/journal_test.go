package journal

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLastUndoableIsTheNewestBatch(t *testing.T) {
	j := New(t.TempDir())
	if j.LastUndoable() != nil {
		t.Fatal("empty")
	}
	now := time.Now()
	j.Add(Entry{Time: now, Batch: "1", Kind: KindTrash, From: "/a"})
	j.Add(Entry{Time: now, Batch: "2", Kind: KindTrash, From: "/b"})
	j.Add(Entry{Time: now, Batch: "2", Kind: KindChmod, From: "/c"})
	j.Add(Entry{Time: now, Batch: "3", Kind: KindRun, Command: []string{"docker"}})
	b := j.LastUndoable()
	if len(b) != 2 || b[0].From != "/b" {
		t.Fatalf("a command cannot be undone, so batch 2 is next: %+v", b)
	}
	j.Add(Entry{Time: now, Batch: "2", Kind: KindUndo})
	if b := j.LastUndoable(); len(b) != 1 || b[0].From != "/a" {
		t.Fatalf("%+v", b)
	}
	j.Add(Entry{Time: now, Batch: "1", Kind: KindUndo})
	if j.LastUndoable() != nil {
		t.Fatal("nothing left")
	}
}

func TestADamagedLineLosesOnlyItself(t *testing.T) {
	dir := t.TempDir()
	j := New(dir)
	j.Add(Entry{Batch: "1", Kind: KindTrash, From: "/a"})
	f, _ := os.OpenFile(filepath.Join(dir, "journal.jsonl"), os.O_APPEND|os.O_WRONLY, 0o600)
	f.WriteString("{not json\n")
	f.Close()
	j.Add(Entry{Batch: "2", Kind: KindTrash, From: "/b"})
	if n := len(j.All()); n != 2 {
		t.Fatal(n)
	}
}

func TestPrivateToYou(t *testing.T) {
	dir := t.TempDir()
	j := New(dir)
	j.Add(Entry{Batch: "1"})
	st, _ := os.Stat(j.Path)
	if st.Mode().Perm() != 0o600 {
		t.Fatal(st.Mode())
	}
}
