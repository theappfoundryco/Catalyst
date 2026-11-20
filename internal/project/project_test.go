package project

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func files(t *testing.T, fs map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for p, text := range fs {
		os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755)
		os.WriteFile(filepath.Join(dir, p), []byte(text), 0o644)
	}
	return dir
}

func env(t *testing.T, tools []string, replies map[string]run.Result) *host.Env {
	e := host.ForTest(t.TempDir(), "linux", &run.Fake{Replies: replies})
	e.Look = func(n string) (string, error) {
		for _, x := range tools {
			if x == n {
				return "/usr/bin/" + n, nil
			}
		}
		return "", exec.ErrNotFound
	}
	return e
}

func TestMatches(t *testing.T) {
	cases := []struct {
		want, have string
		match, ok  bool
	}{
		{"20", "v20.11.1", true, true},
		{"v20.11", "v20.11.1", true, true},
		{"20.1", "v20.11.1", false, true},
		{"3.12", "Python 3.12.4", true, true},
		{"3.11", "Python 3.12.4", false, true},
		{"lts/iron", "v20.11.1", false, false},
		{"system", "Python 3.12.4", false, false},
		{">=18", "v20.0.0", false, false},
	}
	for _, c := range cases {
		m, ok := Matches(c.want, c.have)
		if m != c.match || ok != c.ok {
			t.Errorf("%q vs %q: %v %v", c.want, c.have, m, ok)
		}
	}
}

func TestPinFiles(t *testing.T) {
	dir := files(t, map[string]string{
		".nvmrc":          "# pinned\nv20.11.1\n",
		".tool-versions":  "nodejs 18.0.0\npython 3.12.2 3.11.8 # two\nruby 3.3.0\nterraform 1.7.0\n",
		"mise.toml":       "[env]\nNODE_ENV = \"dev\"\n[tools]\npython = [\"3.11\", \"3.10\"]\n\"node\" = \"22\"\n",
		".python-version": "",
	})
	got := map[string]string{}
	for _, p := range Pins(dir) {
		got[p.Tool] = p.Want + " from " + p.File
	}
	want := map[string]string{"node": "v20.11.1 from .nvmrc", "python": "3.11 from mise.toml", "ruby": "3.3.0 from .tool-versions"}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %q", k, got[k])
		}
	}
	if len(got) != 3 {
		t.Errorf("%v", got)
	}
}

func TestVersionsAreAskedFromInsideTheProject(t *testing.T) {
	dir := files(t, map[string]string{".python-version": "3.12\n", "pyproject.toml": ""})
	e := env(t, []string{"python3"}, map[string]run.Result{
		"cd " + dir + " && python3 --version": {Stdout: "Python 3.12.4\n"}, // what the pyenv shim says in this folder
		"python3 --version":                   {Stdout: "Python 3.10.0\n"},
	})
	r := Check(e, dir)
	if len(r.Findings) != 1 || r.Findings[0].Level != OK || r.Kinds[0] != "python" {
		t.Fatalf("%+v", r)
	}
}

func TestAMessyNodeProject(t *testing.T) {
	dir := files(t, map[string]string{
		".nvmrc": "18\n", "package.json": `{"packageManager":"pnpm@9.1.0"}`, "package-lock.json": "{}",
		".env.example": "API_URL=https://example.com\nexport API_KEY=\n# a comment\nDEBUG=false\n", ".env": "API_URL=https://example.com\nSECRET=hunter2\n",
	})
	e := env(t, []string{"node"}, map[string]run.Result{"node --version": {Stdout: "v22.3.0\n"}})
	r := Check(e, dir)
	text := ""
	for _, f := range r.Findings {
		text += string(f.Level) + " " + f.Title + " | " + f.Hint + "\n"
	}
	for _, want := range []string{
		"warn .nvmrc asks for Node 18, but 22.3.0 runs here",
		"warn package.json says to use pnpm, but the lockfile is package-lock.json",
		"note Dependencies are not installed yet | Run: pnpm install",
		"warn .env is missing 2 settings that .env.example lists | API_KEY, DEBUG",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	if strings.Contains(text, "hunter2") {
		t.Fatal("a value from .env was shown")
	}
}

func TestGoToolchains(t *testing.T) {
	dir := files(t, map[string]string{"go.mod": "module x\n\ngo 1.24.0\n"})
	for have, level := range map[string]Level{"go1.22.1 auto": OK, "go1.22.1 local": Warn, "go1.20.3 auto": Warn, "go1.25.0 auto": OK} {
		e := env(t, []string{"go"}, map[string]run.Result{"go env GOVERSION GOTOOLCHAIN": {Stdout: strings.ReplaceAll(have, " ", "\n") + "\n"}})
		f, ok := goVersion(e, dir, "module x\n\ngo 1.24.0\n")
		if !ok || f.Level != level {
			t.Errorf("%s: %+v", have, f)
		}
	}
}

func TestRootFindsTheRepository(t *testing.T) {
	dir := files(t, map[string]string{".git/HEAD": "ref: refs/heads/main\n", "src/app/x.go": ""})
	if Root(filepath.Join(dir, "src", "app")) != dir {
		t.Fatal("root")
	}
}
