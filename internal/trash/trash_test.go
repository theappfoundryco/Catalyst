package trash

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func bin(t *testing.T, goos string) (*Bin, string) {
	t.Helper()
	home, _ := filepath.EvalSymlinks(t.TempDir())
	return &Bin{OS: goos, Home: home, UID: 501, Now: func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }}, home
}

func TestMacUsesTheHomeTrash(t *testing.T) {
	b, home := bin(t, "darwin")
	p := filepath.Join(home, "app", "node_modules")
	os.MkdirAll(p, 0o755)
	os.WriteFile(filepath.Join(p, "a.js"), []byte("x"), 0o644)
	m, err := b.Move(p)
	if err != nil {
		t.Fatal(err)
	}
	if m.To != filepath.Join(home, ".Trash", "node_modules") || m.Info != "" {
		t.Fatalf("%+v", m)
	}
	if _, err := os.Stat(p); err == nil {
		t.Fatal("still there")
	}
	if err := Restore(m.From, m.To, m.Info); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(p, "a.js")); string(b) != "x" {
		t.Fatal("not restored")
	}
}

func TestLinuxFollowsTheFreedesktopSpec(t *testing.T) {
	b, home := bin(t, "linux")
	p := filepath.Join(home, "my project", "target")
	os.MkdirAll(p, 0o755)
	m, err := b.Move(p)
	if err != nil {
		t.Fatal(err)
	}
	if m.To != filepath.Join(home, ".local/share/Trash/files/target") {
		t.Fatalf("%+v", m)
	}
	info, err := os.ReadFile(m.Info)
	if err != nil {
		t.Fatal(err)
	}
	text := string(info)
	if !strings.HasPrefix(text, "[Trash Info]\n") || !strings.Contains(text, "my%20project/target") || !strings.Contains(text, "DeletionDate=2026-01-02T03:04:05") {
		t.Fatal(text)
	}
	if err := Restore(m.From, m.To, m.Info); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.Info); err == nil {
		t.Fatal("info file left behind")
	}
}

func TestSameNameNeverOverwrites(t *testing.T) {
	b, home := bin(t, "darwin")
	var moved []Moved
	for _, name := range []string{"a", "b", "c"} {
		p := filepath.Join(home, name, "node_modules")
		os.MkdirAll(p, 0o755)
		os.WriteFile(filepath.Join(p, "who"), []byte(name), 0o644)
		m, err := b.Move(p)
		if err != nil {
			t.Fatal(err)
		}
		moved = append(moved, m)
	}
	for i, name := range []string{"a", "b", "c"} {
		got, err := os.ReadFile(filepath.Join(moved[i].To, "who"))
		if err != nil || string(got) != name {
			t.Fatalf("%s: %q %v", name, got, err)
		}
	}
}

func TestRestoreRefusesToOverwrite(t *testing.T) {
	b, home := bin(t, "darwin")
	p := filepath.Join(home, "node_modules")
	os.MkdirAll(p, 0o755)
	m, _ := b.Move(p)
	os.MkdirAll(p, 0o755) // npm install ran again
	if err := Restore(m.From, m.To, ""); err == nil {
		t.Fatal("overwrote something new")
	}
}

func TestRelativePathsAreRefused(t *testing.T) {
	b, _ := bin(t, "darwin")
	if _, err := b.Move("node_modules"); err == nil {
		t.Fatal("moved a relative path")
	}
}
