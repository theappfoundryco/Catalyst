package clean

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func put(t *testing.T, home, rel string, n int) {
	t.Helper()
	p := filepath.Join(home, rel)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, make([]byte, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func names(r Report) string {
	var out []string
	for _, i := range r.Items {
		out = append(out, i.Name)
	}
	return strings.Join(out, ",")
}

func TestLinuxOffersClosedAppCachesOnly(t *testing.T) {
	home := t.TempDir()
	put(t, home, ".cache/google-chrome/blob", 3<<20)     // open, so left alone
	put(t, home, ".cache/ms-playwright/chromium", 2<<20) // closed, offered with a known name
	put(t, home, ".cache/pip/http/blob", 4<<20)          // sweep offers this one
	put(t, home, ".cache/huggingface/hub/model", 5<<20)  // models: reported, never offered
	put(t, home, ".cache/tiny/blob", 1000)               // too small to be worth a row
	e := host.ForTest(home, "linux", &run.Fake{Replies: map[string]run.Result{"ps -eo comm=": {Stdout: "bash\n/opt/google/chrome/google-chrome\n"}}})
	r := Scan(Options{Env: e, MinSize: 1 << 20})
	if got := names(r); got != "Playwright browsers" {
		t.Fatalf("offered %q", got)
	}
	if len(r.Open) != 1 || r.Open[0] != "Chrome" {
		t.Fatalf("open: %v", r.Open)
	}
	if r.Skipped != 1 {
		t.Fatalf("skipped %d", r.Skipped)
	}
}

func TestMacLeavesAppleCachesAndOpenAppsAlone(t *testing.T) {
	home := t.TempDir()
	put(t, home, "Library/Caches/com.apple.Safari/blob", 3<<20)
	put(t, home, "Library/Caches/CloudKit/blob", 3<<20)
	put(t, home, "Library/Caches/com.spotify.client/blob", 3<<20)
	put(t, home, "Library/Caches/com.spotify.client.helper/blob", 3<<20) // a helper of an open app
	put(t, home, "Library/Caches/com.adobe.LightroomClassicCC7/blob", 3<<20)
	put(t, home, "Library/Logs/DiagnosticReports/old.ips", 1<<20)
	e := host.ForTest(home, "darwin", &run.Fake{Replies: map[string]run.Result{
		"lsappinfo list": {Stdout: `1) "Spotify" ASN:0x0-0x1: bundleID="com.spotify.client"` + "\n"},
	}})
	r := Scan(Options{Env: e, MinSize: 2 << 20})
	got := names(r)
	if got != "LightroomClassicCC7,DiagnosticReports logs" {
		t.Fatalf("offered %q", got)
	}
	for _, i := range r.Items {
		if strings.Contains(i.Path, "com.apple.") || strings.Contains(i.Path, "spotify") {
			t.Fatalf("offered %s", i.Path)
		}
	}
}

func TestNamesFromBundleIdentifiers(t *testing.T) {
	names := map[string]string{"com.tinyspeck.slackmacgap": "Slack"}
	for folder, want := range map[string]string{
		"com.tinyspeck.slackmacgap":     "Slack",
		"ms-playwright":                 "Playwright browsers",
		"com.adobe.LightroomClassicCC7": "LightroomClassicCC7",
		"SomeTool":                      "SomeTool",
	} {
		if got, _ := label(folder, names); got != want {
			t.Errorf("%s: got %q", folder, got)
		}
	}
}

func TestAdminAreasAreExplainedNeverTouched(t *testing.T) {
	e := host.ForTest(t.TempDir(), "darwin", &run.Fake{Replies: map[string]run.Result{
		"tmutil listlocalsnapshots /": {Stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-06-101010.local\ncom.apple.TimeMachine.2026-11-07-101010.local\n"},
	}})
	got := admin(e)
	if len(got) == 0 || got[0].Count != 2 || !strings.HasPrefix(got[0].Command, "sudo ") {
		t.Fatalf("%+v", got)
	}
}
