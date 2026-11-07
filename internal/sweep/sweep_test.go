package sweep

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// fixture builds a home with real git repositories. This file is the most important test in the project:
// everything below asserts what sweep must never offer.
type fixture struct {
	t    *testing.T
	home string
	e    *host.Env
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("needs git")
	}
	home := t.TempDir()
	home, _ = filepath.EvalSymlinks(home)
	e := host.ForTest(home, "linux", run.Real{})
	e.Look = exec.LookPath
	return &fixture{t, home, e}
}

func (f *fixture) file(path, text string) string {
	f.t.Helper()
	p := filepath.Join(f.home, path)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		f.t.Fatal(err)
	}
	return p
}

func (f *fixture) git(dir string, args ...string) {
	f.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", filepath.Join(f.home, dir), "-c", "user.name=Alex", "-c", "user.email=alex@example.com"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		f.t.Fatalf("git %v: %s", args, out)
	}
}

// old pushes everything in a project into the past, so only the rule being tested decides.
func (f *fixture) old(dir string) {
	f.t.Helper()
	long := time.Now().Add(-200 * 24 * time.Hour)
	filepath.Walk(filepath.Join(f.home, dir), func(p string, _ os.FileInfo, _ error) error {
		os.Chtimes(p, long, long)
		return nil
	})
}

func (f *fixture) scan(roots ...string) Report {
	f.t.Helper()
	var full []string
	for _, r := range roots {
		full = append(full, filepath.Join(f.home, r))
	}
	return Scan(Options{Roots: full, OlderThan: 14 * 24 * time.Hour, Env: f.e})
}

func has(r Report, suffix string) bool {
	for _, i := range r.Items {
		if strings.HasSuffix(i.Path, suffix) {
			return true
		}
	}
	return false
}

func TestOffersAnIgnoredIdleNodeModules(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/.gitignore", "node_modules/\n")
	f.file("p/app/node_modules/x/index.js", "x")
	f.git("p/app", "init", "-q")
	f.git("p/app", "add", ".")
	f.git("p/app", "commit", "-qm", "first")
	f.old("p/app")
	r := f.scan("p")
	if !has(r, "app/node_modules") {
		t.Fatalf("%+v", r)
	}
	if r.Items[0].Project != "app" || r.Items[0].Restore != "npm install" {
		t.Fatalf("%+v", r.Items[0])
	}
}

func TestNeverOffersAFolderGitTracks(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/Makefile", "all:\n")
	f.file("p/app/build/release.sh", "#!/bin/sh\n# written by hand\n") // the old app offered this
	f.git("p/app", "init", "-q")
	f.git("p/app", "add", ".")
	f.git("p/app", "commit", "-qm", "first")
	f.old("p/app")
	r := f.scan("p")
	if has(r, "build") {
		t.Fatalf("offered tracked files: %+v", r)
	}
	if r.SkippedGit != 1 {
		t.Fatalf("%+v", r)
	}
}

func TestIgnoredButTrackedIsStillTracked(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/node_modules/patched/index.js", "vendored by hand")
	f.git("p/app", "init", "-q")
	f.git("p/app", "add", ".")
	f.git("p/app", "commit", "-qm", "first")
	f.file("p/app/.gitignore", "node_modules/\n") // ignored afterwards, so git check-ignore alone would say yes
	f.old("p/app")
	if r := f.scan("p"); has(r, "node_modules") {
		t.Fatalf("offered tracked files: %+v", r)
	}
}

func TestNotIgnoredIsNotOffered(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/README.md", "x")
	f.file("p/app/node_modules/x/index.js", "x")
	f.git("p/app", "init", "-q")
	f.git("p/app", "add", "README.md", "package.json")
	f.git("p/app", "commit", "-qm", "first")
	f.old("p/app")
	if r := f.scan("p"); has(r, "node_modules") {
		t.Fatalf("%+v", r)
	}
}

func TestACommonNameWithoutGitIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/Makefile", "all:\n")
	f.file("p/app/build/notes.txt", "mine")
	f.old("p/app")
	if r := f.scan("p"); has(r, "build") {
		t.Fatalf("%+v", r)
	}
}

func TestAFakeVenvIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/venv/my-notes.txt", "a folder that merely has this name")
	f.old("p/app")
	if r := f.scan("p"); has(r, "venv") {
		t.Fatalf("%+v", r)
	}
	f.file("p/real/.venv/pyvenv.cfg", "home = /usr/bin\n")
	f.old("p/real")
	if r := f.scan("p"); !has(r, "real/.venv") {
		t.Fatalf("%+v", r)
	}
}

func TestNoMarkerNoOffer(t *testing.T) {
	f := newFixture(t)
	f.file("p/x/node_modules/a.js", "no package.json beside it, so it belongs to an installed tool")
	f.file("p/y/target/a.txt", "no Cargo.toml or pom.xml")
	f.old("p")
	if r := f.scan("p"); len(r.Items) != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestASymlinkIsNeverFollowedOrOffered(t *testing.T) {
	f := newFixture(t)
	f.file("elsewhere/precious/data.txt", "keep me")
	f.file("p/app/package.json", "{}")
	if err := os.Symlink(filepath.Join(f.home, "elsewhere/precious"), filepath.Join(f.home, "p/app/node_modules")); err != nil {
		t.Fatal(err)
	}
	// and a linked folder holding something that looks offerable
	f.file("elsewhere/other/package.json", "{}")
	f.file("elsewhere/other/node_modules/a.js", "x")
	if err := os.Symlink(filepath.Join(f.home, "elsewhere/other"), filepath.Join(f.home, "p/link")); err != nil {
		t.Fatal(err)
	}
	f.old("p")
	f.old("elsewhere")
	if r := f.scan("p"); len(r.Items) != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestRecentWorkProtectsAProject(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/.gitignore", "node_modules/\n")
	f.file("p/app/node_modules/x/index.js", "x")
	f.file("p/app/src/deep/main.js", "x")
	f.git("p/app", "init", "-q")
	f.git("p/app", "add", ".")
	f.git("p/app", "commit", "-qm", "first")
	f.old("p/app")
	if !has(f.scan("p"), "node_modules") {
		t.Fatal("should be offered while idle")
	}
	// An edit nobody staged: .git/index does not move. The old app stopped looking at the git date and offered this.
	f.file("p/app/src/deep/main.js", "edited today, not staged")
	r := f.scan("p")
	if has(r, "node_modules") || r.SkippedRecent != 1 {
		t.Fatalf("%+v", r)
	}
}

func TestABackgroundToolTouchingNodeModulesIsNotWork(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/node_modules/x/index.js", "x")
	f.old("p/app")
	f.file("p/app/node_modules/.cache/touched", "a linter was here")
	if !has(f.scan("p"), "node_modules") {
		t.Fatal("artifact activity must not count")
	}
}

func TestSkipsPrivateAndAppFolders(t *testing.T) {
	f := newFixture(t)
	for _, dir := range []string{".ssh", "Library", ".config", ".git", "My.app/Contents/Resources"} {
		f.file("p/"+dir+"/package.json", "{}")
		f.file("p/"+dir+"/node_modules/a.js", "x")
	}
	f.old("p")
	if r := f.scan("p"); len(r.Items) != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestDoesNotLookInsideWhatItFound(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/node_modules/dep/package.json", "{}")
	f.file("p/app/node_modules/dep/node_modules/inner/a.js", "x")
	f.old("p/app")
	if r := f.scan("p"); len(r.Items) != 1 {
		t.Fatalf("%+v", r)
	}
}

func TestMinSizeFilters(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/node_modules/a.js", "tiny")
	f.old("p/app")
	r := Scan(Options{Roots: []string{filepath.Join(f.home, "p")}, OlderThan: time.Hour, MinSize: 50_000_000, Env: f.e})
	if len(r.Items) != 0 || r.SkippedSmall != 1 {
		t.Fatalf("%+v", r)
	}
}

func TestHardLinksCountOnce(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	data := make([]byte, 1<<20)
	if err := os.WriteFile(a, data, 0o644); err != nil {
		t.Fatal(err)
	}
	one := DirSize(dir, NewSeen())
	for _, n := range []string{"b", "c", "d"} {
		if err := os.Link(a, filepath.Join(dir, n)); err != nil {
			t.Fatal(err)
		}
	}
	if got := DirSize(dir, NewSeen()); got != one {
		t.Fatalf("linked files counted again: %d vs %d", got, one)
	}
}

func TestUnreadableGitMeansNo(t *testing.T) {
	f := newFixture(t)
	f.file("p/app/package.json", "{}")
	f.file("p/app/node_modules/a.js", "x")
	f.git("p/app", "init", "-q")
	f.old("p/app")
	f.e.Look = func(string) (string, error) { return "", exec.ErrNotFound } // git is gone
	if r := f.scan("p"); has(r, "node_modules") {
		t.Fatalf("%+v", r)
	}
}
