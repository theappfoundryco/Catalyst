package sysdata

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func versionsEnv(t *testing.T, tools ...string) *host.Env {
	t.Helper()
	e := host.ForTest(t.TempDir(), "linux", &run.Fake{})
	e.Look = func(n string) (string, error) {
		for _, x := range tools {
			if x == n {
				return "/usr/local/bin/" + n, nil
			}
		}
		return "", exec.ErrNotFound
	}
	return e
}

func mkdirs(t *testing.T, root string, dirs ...string) {
	t.Helper()
	for _, d := range dirs {
		os.MkdirAll(filepath.Join(root, d), 0o755)
	}
}

func names(as []Area) string {
	var out []string
	for _, a := range as {
		out = append(out, a.Name)
	}
	return strings.Join(out, ", ")
}

func big(string) int64 { return 200_000_000 }

func TestUnusedNodeVersionsInNvm(t *testing.T) {
	e := versionsEnv(t)
	nvm := e.Path(".nvm")
	mkdirs(t, nvm, "versions/node/v18.19.0", "versions/node/v20.11.0", "versions/node/v20.12.2", "versions/node/v22.3.0", "versions/node/x;rm -rf ~")
	os.WriteFile(filepath.Join(nvm, "nvm.sh"), nil, 0o644)
	os.MkdirAll(filepath.Join(nvm, "alias"), 0o755)
	os.WriteFile(filepath.Join(nvm, "alias", "default"), []byte("20\n"), 0o644)
	mkdirs(t, e.Home, "code/shop")
	os.WriteFile(e.Path("code", "shop", ".nvmrc"), []byte("22\n"), 0o644)
	got := versionAreas(e, big)
	if names(got) != "Node 18.19.0 (nvm)" {
		t.Fatalf("the default's 20.x, the pinned 22 and an unsafe name all stay: %s", names(got))
	}
	cmd := got[0].Command
	if got[0].Said() != "nvm uninstall v18.19.0" || got[0].Way != Owner || cmd[0] != "bash" || !strings.Contains(cmd[2], `nvm uninstall "$2"`) || cmd[len(cmd)-1] != "v18.19.0" || strings.Contains(cmd[2], "18.19") {
		t.Fatalf("the version is an argument, never part of the script: %q", cmd)
	}
	os.WriteFile(filepath.Join(nvm, "alias", "default"), []byte("lts/*\n"), 0o644)
	if got := versionAreas(e, big); len(got) != 0 {
		t.Fatalf("a default Catalyst cannot resolve means nothing is offered: %s", names(got))
	}
}

func TestUnusedPythonSkipsWhatRuns(t *testing.T) {
	e := versionsEnv(t, "pyenv")
	mkdirs(t, e.Path(".pyenv", "versions"), "3.11.4", "3.12.1", "3.13.0")
	os.WriteFile(e.Path(".pyenv", "version"), []byte("3.13.0\n"), 0o644)
	e.Entries = []string{e.Path(".pyenv", "versions", "3.12.1", "bin"), "/usr/bin"}
	got := versionAreas(e, big)
	if names(got) != "Python 3.11.4 (pyenv)" || strings.Join(got[0].Command, " ") != "/usr/local/bin/pyenv uninstall -f 3.11.4" || got[0].Said() != "pyenv uninstall -f 3.11.4" {
		t.Fatalf("%s %q", names(got), got[0].Command)
	}
	if got := versionAreas(e, func(string) int64 { return 1000 }); len(got) != 0 {
		t.Fatalf("too small to be worth a row: %s", names(got))
	}
}

func TestUnusedMiseVersionsIgnoreItsLinks(t *testing.T) {
	e := versionsEnv(t, "mise")
	inst := e.Path(".local", "share", "mise", "installs", "node")
	mkdirs(t, inst, "20.1.0", "22.0.0")
	os.Symlink(filepath.Join(inst, "22.0.0"), filepath.Join(inst, "22"))
	mkdirs(t, e.Home, ".config/mise")
	os.WriteFile(e.Path(".config", "mise", "config.toml"), []byte("[tools]\nnode = \"22\"\n"), 0o644)
	got := versionAreas(e, big)
	if names(got) != "Node 20.1.0 (mise)" || strings.Join(got[0].Command, " ") != "/usr/local/bin/mise uninstall node@20.1.0" || got[0].Said() != "mise uninstall node@20.1.0" {
		t.Fatalf("%s %+v", names(got), got)
	}
	os.Remove(e.Path(".config", "mise", "config.toml"))
	if got := versionAreas(e, big); len(got) != 0 {
		t.Fatalf("no global version means which is in use is unknown: %s", names(got))
	}
}

func TestOlderSimulatorRuntimes(t *testing.T) {
	text := `{
	  "A1B2C3D4-0000-0000-0000-000000000001": {"identifier": "A1B2C3D4-0000-0000-0000-000000000001", "version": "17.5", "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 7300000000, "deletable": true},
	  "A1B2C3D4-0000-0000-0000-000000000002": {"identifier": "A1B2C3D4-0000-0000-0000-000000000002", "version": "18.2", "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 8100000000, "deletable": true},
	  "A1B2C3D4-0000-0000-0000-000000000003": {"identifier": "A1B2C3D4-0000-0000-0000-000000000003", "version": "17.10", "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 7000000000, "deletable": false},
	  "A1B2C3D4-0000-0000-0000-000000000004": {"identifier": "A1B2C3D4-0000-0000-0000-000000000004", "version": "11.0", "platformIdentifier": "com.apple.platform.watchsimulator", "sizeBytes": 4000000000, "deletable": true}
	}`
	got := ParseSimRuntimes(text)
	if names(got) != "iOS 17.5 simulator runtime" || strings.Join(got[0].Command, " ") != "xcrun simctl runtime delete A1B2C3D4-0000-0000-0000-000000000001" {
		t.Fatalf("the newest of each platform and anything Xcode will not delete stay: %s", names(got))
	}
	if !newer("17.10", "17.9") || newer("17.9", "17.10") {
		t.Fatal("17.10 is newer than 17.9")
	}
}
