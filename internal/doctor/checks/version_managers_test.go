package checks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
)

func TestManagerOf(t *testing.T) {
	cases := map[string]string{
		"/home/alex/.nvm/versions/node/v20.11.1/bin":              "nvm",
		"/run/user/1000/fnm_multishells/12345_1700000000000/bin":  "fnm",
		"/Users/alex/.volta/bin":                                  "volta",
		"/home/alex/.local/share/mise/shims":                      "mise",
		"/home/alex/.local/share/mise/installs/python/3.12.2/bin": "mise",
		"/home/alex/.pyenv/shims":                                 "pyenv",
		"/opt/homebrew/Caskroom/miniforge/base/bin":               "conda",
		"/home/alex/miniconda3/bin":                               "conda",
		"/Users/alex/.rbenv/shims":                                "rbenv",
		"/usr/bin":                                                "",
		"/opt/homebrew/bin":                                       "",
	}
	for in, want := range cases {
		if got := ManagerOf(in); got != want {
			t.Errorf("%s: %q", in, got)
		}
	}
}

func TestTwoVersionManagersForOneLanguage(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	tool := func(dir, name string) string {
		p := e.Path(dir)
		write(t, filepath.Join(p, name), "#!/bin/sh\n", 0o755)
		return p
	}
	volta := tool(".volta/bin", "node")
	nvm := tool(".nvm/versions/node/v20.11.1/bin", "node")
	pyenv := tool(".pyenv/shims", "python3")
	os.MkdirAll(e.Path(".local/share/mise/shims"), 0o755) // mise installed, but managing no Node: not a conflict
	e.Entries = []string{volta, e.Path(".local/share/mise/shims"), "/usr/bin", nvm, pyenv}
	r := one(t, versionManagers(e))
	if r.Severity != d.Warning || r.Title != "Node comes from volta and nvm at once" || !strings.HasPrefix(r.Hint, "volta is first") {
		t.Fatalf("%+v", r)
	}
	e.Entries = []string{volta, "/usr/bin", pyenv}
	if r := one(t, versionManagers(e)); r.State != d.Passed {
		t.Fatalf("one manager each is the normal setup: %+v", r)
	}
	e.Entries = []string{"/usr/bin", "/bin"}
	if r := one(t, versionManagers(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
}
