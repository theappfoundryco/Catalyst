package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func testApp(t *testing.T, goos string) (*App, *bytes.Buffer) {
	t.Helper()
	home, _ := filepath.EvalSymlinks(t.TempDir())
	var b bytes.Buffer
	e := host.ForTest(home, goos, run.Real{})
	e.Look = exec.LookPath
	s := state.New(home, nil)
	return &App{U: ui.Plain(&b, 100), E: e, Store: s, Journal: journal.New(s.Dir)}, &b
}

func put(t *testing.T, path, text string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func past(root string) {
	long := time.Now().Add(-200 * 24 * time.Hour)
	filepath.Walk(root, func(p string, _ os.FileInfo, _ error) error {
		os.Chtimes(p, long, long)
		return nil
	})
}

func TestParseAge(t *testing.T) {
	for in, want := range map[string]time.Duration{"14d": 14 * 24 * time.Hour, "2w": 14 * 24 * time.Hour, "48h": 48 * time.Hour, "0": 0, "1m": 30 * 24 * time.Hour} {
		got, err := ParseAge(in)
		if err != nil || got != want {
			t.Errorf("%s: %v %v", in, got, err)
		}
	}
	if _, err := ParseAge("soon"); err == nil {
		t.Error("should refuse")
	}
}

func TestParseSize(t *testing.T) {
	for in, want := range map[string]int64{"10MB": 10_000_000, "1gb": 1_000_000_000, "0B": 0} {
		got, err := ParseSize(in)
		if err != nil || got != want {
			t.Errorf("%s: %v %v", in, got, err)
		}
	}
	if _, err := ParseSize("big"); err == nil {
		t.Error("should refuse")
	}
}

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{{"v0.2.0", "0.1.0", true}, {"v0.1.0", "0.1.0", false}, {"v0.1.0", "0.2.0", false}, {"v0.1.10", "0.1.9", true}, {"v0.1.0", "0.1.0-dev", true}, {"v1.0.0", "0.9.9", true}}
	for _, c := range cases {
		if got := Newer(c.a, c.b); got != c.want {
			t.Errorf("%+v: %v", c, got)
		}
	}
}

func TestVerifySumRefusesWhatItCannotCheck(t *testing.T) {
	data := []byte("hello")
	good := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	if err := VerifySum(data, "a.tar.gz", good+"  a.tar.gz\n"); err != nil {
		t.Fatal(err)
	}
	if err := VerifySum(data, "a.tar.gz", strings.Repeat("0", 64)+"  a.tar.gz\n"); err == nil {
		t.Fatal("accepted a bad checksum")
	}
	if err := VerifySum(data, "a.tar.gz", good+"  other.tar.gz\n"); err == nil {
		t.Fatal("accepted a missing line")
	}
}

func TestTrendWords(t *testing.T) {
	now := time.Date(2026, 3, 12, 9, 0, 0, 0, time.Local) // a Thursday
	if got := trendWords(3, now.AddDate(0, 0, -2), now); got != "up 3 since Tuesday" {
		t.Error(got)
	}
	if got := trendWords(-4, now.AddDate(0, 0, -20), now); got != "down 4 since Feb 20" {
		t.Error(got)
	}
	if got := trendWords(0, now.AddDate(0, 0, -1), now); got != "same as Wednesday" {
		t.Error(got)
	}
}

func TestUnknownCommandIsAUsageError(t *testing.T) {
	a, b := testApp(t, "linux")
	if code := a.dispatch([]string{"bogus"}); code != ExitUsage {
		t.Fatal(code)
	}
	if !strings.Contains(b.String(), "bogus") {
		t.Fatal(b.String())
	}
}

func TestDocsListEveryCommandInHelp(t *testing.T) {
	a, b := testApp(t, "linux")
	cmdHelp(a, nil)
	for _, c := range commands() {
		if !strings.Contains(b.String(), c.Name) {
			t.Errorf("%s missing from help", c.Name)
		}
	}
}

func project(t *testing.T, a *App, name string) string {
	t.Helper()
	dir := a.E.Path("Developer", name)
	put(t, filepath.Join(dir, "package.json"), "{}")
	put(t, filepath.Join(dir, "node_modules", "dep", "index.js"), "module.exports = 1\n")
	put(t, filepath.Join(dir, "__pycache__", "a.pyc"), "x")
	past(dir)
	return dir
}

// The full round trip a person takes: sweep, then undo, with real files and the real Trash folders.
func TestSweepThenUndoPutsEverythingBack(t *testing.T) {
	a, b := testApp(t, "linux")
	dir := project(t, a, "app")
	root := a.E.Path("Developer")
	if code := a.dispatch([]string{"sweep", root, "--min-size", "0B", "--all", "--yes"}); code != ExitOK {
		t.Fatalf("%d\n%s", code, b.String())
	}
	if host.Exists(filepath.Join(dir, "node_modules")) || host.Exists(filepath.Join(dir, "__pycache__")) {
		t.Fatalf("not moved\n%s", b.String())
	}
	if !host.Exists(filepath.Join(dir, "package.json")) {
		t.Fatal("source was touched")
	}
	if !host.Exists(a.E.Path(".local/share/Trash/files/node_modules/dep/index.js")) {
		t.Fatal("not in the Trash")
	}
	b.Reset()
	if code := a.dispatch([]string{"undo", "--yes"}); code != ExitOK {
		t.Fatalf("%d\n%s", code, b.String())
	}
	if !host.Exists(filepath.Join(dir, "node_modules/dep/index.js")) || !host.Exists(filepath.Join(dir, "__pycache__/a.pyc")) {
		t.Fatalf("not restored\n%s", b.String())
	}
	b.Reset()
	a.dispatch([]string{"undo", "--yes"})
	if !strings.Contains(b.String(), "Nothing to undo") {
		t.Fatal(b.String())
	}
	b.Reset()
	a.dispatch([]string{"log"})
	if !strings.Contains(b.String(), "Node packages in app") {
		t.Fatal(b.String())
	}
}

func TestYesOnlyTakesWhatRebuildsItself(t *testing.T) {
	a, b := testApp(t, "linux")
	dir := project(t, a, "app")
	if code := a.dispatch([]string{"sweep", a.E.Path("Developer"), "--min-size", "0B", "--yes"}); code != ExitOK {
		t.Fatalf("%d\n%s", code, b.String())
	}
	if !host.Exists(filepath.Join(dir, "node_modules")) {
		t.Fatal("--yes took something that needs a reinstall")
	}
	if host.Exists(filepath.Join(dir, "__pycache__")) {
		t.Fatal("--yes should take what rebuilds itself")
	}
}

func TestDryRunMovesNothing(t *testing.T) {
	a, b := testApp(t, "linux")
	dir := project(t, a, "app")
	if code := a.dispatch([]string{"sweep", a.E.Path("Developer"), "--min-size", "0B", "--all", "--yes", "--dry-run"}); code != ExitOK {
		t.Fatal(code)
	}
	if !host.Exists(filepath.Join(dir, "node_modules")) || !strings.Contains(b.String(), "nothing was moved") {
		t.Fatal(b.String())
	}
}

func TestNoPersonNoYesChangesNothing(t *testing.T) {
	a, _ := testApp(t, "linux")
	dir := project(t, a, "app")
	if code := a.dispatch([]string{"sweep", a.E.Path("Developer"), "--min-size", "0B", "--all"}); code != ExitOK {
		t.Fatal(code)
	}
	if !host.Exists(filepath.Join(dir, "node_modules")) {
		t.Fatal("moved without being asked")
	}
}

func TestSweepJSONIsValid(t *testing.T) {
	a, b := testApp(t, "linux")
	project(t, a, "app")
	if code := a.dispatch([]string{"sweep", a.E.Path("Developer"), "--min-size", "0B", "--json"}); code != ExitOK {
		t.Fatal(code)
	}
	var r struct {
		Items []struct{ Path string } `json:"items"`
	}
	if err := json.Unmarshal(b.Bytes(), &r); err != nil || len(r.Items) != 2 {
		t.Fatalf("%v\n%s", err, b.String())
	}
}

func TestBadFlagsAreUsageErrors(t *testing.T) {
	a, _ := testApp(t, "linux")
	for _, args := range [][]string{{"sweep", "--older-than", "soon"}, {"sweep", "/no/such/folder"}, {"doctor", "--nope"}, {"ports", "kill", "abc"}, {"config", "set", "x", "y"}} {
		if code := a.dispatch(args); code != ExitUsage {
			t.Errorf("%v: %d", args, code)
		}
	}
}

func TestChmodFixIsUndoable(t *testing.T) {
	a, _ := testApp(t, "linux")
	p := a.E.Path(".ssh")
	os.MkdirAll(p, 0o755)
	os.Chmod(p, 0o755)
	f := doctor.Fix{Kind: doctor.FixChmod, Title: "x", Path: p, Mode: 0o700}
	if err := a.applyFix(f, "1"); err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o700 {
		t.Fatal(st.Mode())
	}
	a.U.Yes = true
	if code := a.dispatch([]string{"undo"}); code != ExitOK {
		t.Fatal(code)
	}
	st, _ = os.Stat(p)
	if st.Mode().Perm() != 0o755 {
		t.Fatal(st.Mode())
	}
}

func TestAFailedRunFixIsReported(t *testing.T) {
	a, _ := testApp(t, "linux")
	f := doctor.Fix{Kind: doctor.FixRun, Title: "x", Command: []string{"sh", "-c", "echo nope >&2; exit 2"}}
	err := a.applyFix(f, "1")
	if err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatal(err)
	}
	if len(a.Journal.All()) != 0 {
		t.Fatal("a failure must not read as a change")
	}
}

func TestManualFixesNeverRun(t *testing.T) {
	a, _ := testApp(t, "linux")
	f := doctor.Fix{Kind: doctor.FixManual, Command: []string{"sh", "-c", "touch " + a.E.Path("ran")}}
	if err := a.applyFix(f, "1"); err == nil {
		t.Fatal("no error")
	}
	if host.Exists(a.E.Path("ran")) {
		t.Fatal("ran it")
	}
}

func TestLegacyEditKeepsAGoodZshrcAndBacksUp(t *testing.T) {
	a, _ := testApp(t, "darwin")
	rc := a.E.Path(".zshrc")
	text := "export A=1\n[[ -f ~/.zshrc_catalyst ]] && source ~/.zshrc_catalyst\nalias b=c\n"
	put(t, rc, text)
	if err := a.removeSourceLine(rc, text); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(rc)
	if strings.Contains(string(got), "catalyst") || !strings.Contains(string(got), "alias b=c") {
		t.Fatalf("%q", got)
	}
	back, _ := os.ReadFile(rc + ".catalyst-backup")
	if string(back) != text {
		t.Fatalf("%q", back)
	}
}

func TestLegacyEditPutsItBackWhenZshObjects(t *testing.T) {
	a, _ := testApp(t, "darwin")
	f := &run.Fake{Replies: map[string]run.Result{}}
	a.E.Run = f
	a.E.Look = func(string) (string, error) { return "/bin/zsh", nil }
	rc := a.E.Path(".zshrc")
	text := "if x; then\n[[ -f ~/.zshrc_catalyst ]] && source ~/.zshrc_catalyst\nfi\n"
	put(t, rc, text)
	f.Replies["zsh -n "+rc] = run.Result{Code: 1}
	if err := a.removeSourceLine(rc, text); err == nil {
		t.Fatal("no error")
	}
	got, _ := os.ReadFile(rc)
	if string(got) != text {
		t.Fatalf("%q", got)
	}
}
