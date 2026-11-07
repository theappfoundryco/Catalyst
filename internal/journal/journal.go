// Package journal records every change Catalyst makes, so `catalyst undo` can reverse it and `catalyst log` can show it.
// One JSON line per change. Paths and titles only, never file contents or secrets.
package journal

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// The kinds of change.
const (
	KindTrash = "trash"   // moved From to To
	KindChmod = "chmod"   // changed Path's mode from OldMode to NewMode
	KindRun   = "run"     // ran a command; cannot be undone
	KindUndo  = "undone"  // Batch was reversed
	KindEmpty = "emptied" // Batch was emptied from the Trash, so it can no longer be undone
	KindEdit  = "edited"  // changed the text file From; To is a copy of it from before
)

// Entry is one change.
type Entry struct {
	Time    time.Time   `json:"time"`
	Batch   string      `json:"batch"`
	Kind    string      `json:"kind"`
	Title   string      `json:"title"`
	From    string      `json:"from,omitempty"`
	To      string      `json:"to,omitempty"`
	Info    string      `json:"info,omitempty"` // a trash info file to remove on undo
	Size    int64       `json:"size,omitempty"`
	OldMode fs.FileMode `json:"old_mode,omitempty"`
	NewMode fs.FileMode `json:"new_mode,omitempty"`
	Command []string    `json:"command,omitempty"`
}

// Journal is one file on disk.
type Journal struct{ Path string }

// New opens the journal in the given folder.
func New(dir string) *Journal { return &Journal{Path: filepath.Join(dir, "journal.jsonl")} }

// NewBatch names a group of changes that are undone together.
func NewBatch(now time.Time) string { return fmt.Sprintf("%d", now.UnixNano()) }

// Add appends one change. If it cannot be written the change must not go ahead, so callers add before acting when they can.
func (j *Journal) Add(e Entry) error {
	if err := os.MkdirAll(filepath.Dir(j.Path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(j.Path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	b, err := json.Marshal(e)
	if err != nil {
		return err
	}
	_, err = f.Write(append(b, '\n'))
	return err
}

// All reads every entry, oldest first. A damaged line is skipped, so one bad write cannot lose the rest.
func (j *Journal) All() []Entry {
	f, err := os.Open(j.Path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []Entry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var e Entry
		if json.Unmarshal(sc.Bytes(), &e) == nil {
			out = append(out, e)
		}
	}
	return out
}

// LastUndoable returns the changes of the newest batch that can still be reversed.
func (j *Journal) LastUndoable() []Entry {
	all := j.All()
	undone := map[string]bool{}
	for _, e := range all {
		if e.Kind == KindUndo || e.Kind == KindEmpty {
			undone[e.Batch] = true
		}
	}
	for i := len(all) - 1; i >= 0; i-- {
		e := all[i]
		if undone[e.Batch] || (e.Kind != KindTrash && e.Kind != KindChmod && e.Kind != KindEdit) {
			continue
		}
		var batch []Entry
		for _, x := range all {
			if x.Batch == e.Batch && (x.Kind == KindTrash || x.Kind == KindChmod || x.Kind == KindEdit) {
				batch = append(batch, x)
			}
		}
		return batch
	}
	return nil
}
