// Package project diagnoses the repository you are standing in: the versions it pins against the ones that run here,
// lockfiles that disagree, settings files left uncopied and git hooks that point nowhere. It only reads, and it never
// installs anything: each finding names the command to run.
package project

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Level is how a finding reads.
type Level string

// The levels.
const (
	OK   Level = "ok"
	Note Level = "note"
	Warn Level = "warn"
)

// Finding is one thing about the project.
type Finding struct {
	Level Level  `json:"level"`
	Title string `json:"title"`
	Hint  string `json:"hint,omitempty"`
	File  string `json:"file,omitempty"` // the file that says so, relative to the project
}

// Report is what Check found.
type Report struct {
	Dir      string    `json:"dir"`
	Kinds    []string  `json:"kinds"` // node, python, ruby, go, rust
	Findings []Finding `json:"findings"`
}

// Pin is one version a project asks for.
type Pin struct {
	Tool, Want, File string
}

// Root walks up from dir to the folder that holds .git, or returns dir when there is none.
func Root(dir string) string {
	for d := dir; ; d = filepath.Dir(d) {
		if host.Exists(filepath.Join(d, ".git")) {
			return d
		}
		if filepath.Dir(d) == d {
			return dir
		}
	}
}

// Check reads the project at dir.
func Check(e *host.Env, dir string) Report {
	r := Report{Dir: dir, Kinds: []string{}}
	has := func(f string) bool { return host.Exists(filepath.Join(dir, f)) }
	read := func(f string) string { b, _ := os.ReadFile(filepath.Join(dir, f)); return string(b) }
	for kind, markers := range map[string][]string{
		"node": {"package.json"}, "python": {"pyproject.toml", "requirements.txt", "setup.py", "Pipfile"},
		"ruby": {"Gemfile"}, "go": {"go.mod"}, "rust": {"Cargo.toml"},
	} {
		for _, m := range markers {
			if has(m) {
				r.Kinds = append(r.Kinds, kind)
				break
			}
		}
	}
	sort.Strings(r.Kinds)
	for _, p := range Pins(dir) {
		r.Findings = append(r.Findings, comparePin(e, dir, p))
	}
	if has("go.mod") {
		if f, ok := goVersion(e, dir, read("go.mod")); ok {
			r.Findings = append(r.Findings, f)
		}
	}
	if has("package.json") {
		r.Findings = append(r.Findings, nodeProject(dir, read("package.json"))...)
	}
	r.Findings = append(r.Findings, envFiles(dir)...)
	if f, ok := hooks(e, dir); ok {
		r.Findings = append(r.Findings, f)
	}
	return r
}

// Pins reads every version file a project may have. The first file that names a tool wins, in the order version
// managers themselves look: their own file, then the shared ones.
func Pins(dir string) []Pin {
	var out []Pin
	seen := map[string]bool{}
	add := func(tool, want, file string) {
		want = strings.TrimSpace(want)
		if want == "" || seen[tool] {
			return
		}
		seen[tool] = true
		out = append(out, Pin{tool, want, file})
	}
	first := func(f string) string {
		b, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return ""
		}
		for _, l := range strings.Split(string(b), "\n") {
			if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
				return l
			}
		}
		return ""
	}
	add("node", first(".nvmrc"), ".nvmrc")
	add("node", first(".node-version"), ".node-version")
	add("python", first(".python-version"), ".python-version")
	add("ruby", strings.TrimPrefix(first(".ruby-version"), "ruby-"), ".ruby-version")
	for _, f := range []string{"mise.toml", ".mise.toml"} {
		for tool, v := range MiseTools(readFile(filepath.Join(dir, f))) {
			add(tool, v, f)
		}
	}
	for tool, v := range ToolVersions(readFile(filepath.Join(dir, ".tool-versions"))) {
		add(tool, v, ".tool-versions")
	}
	return out
}

func readFile(p string) string { b, _ := os.ReadFile(p); return string(b) }

// asdfNames maps asdf and mise plugin names to the tool Catalyst asks.
var asdfNames = map[string]string{"nodejs": "node", "node": "node", "python": "python", "ruby": "ruby"}

// ToolVersions reads asdf's .tool-versions: "nodejs 20.11.1", taking the first version when several are listed.
func ToolVersions(text string) map[string]string {
	out := map[string]string{}
	for _, l := range strings.Split(text, "\n") {
		f := strings.Fields(strings.SplitN(l, "#", 2)[0])
		if len(f) >= 2 {
			if t, ok := asdfNames[f[0]]; ok {
				out[t] = f[1]
			}
		}
	}
	return out
}

var miseLine = regexp.MustCompile(`^\s*"?([a-z]+)"?\s*=\s*(?:"([^"]+)"|\[\s*"([^"]+)")`)

// MiseTools reads the [tools] table of mise.toml: node = "20", python = ["3.12", "3.11"].
func MiseTools(text string) map[string]string {
	out := map[string]string{}
	in := false
	for _, l := range strings.Split(text, "\n") {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "[") && !strings.Contains(t, "=") {
			in = t == "[tools]"
			continue
		}
		if !in {
			continue
		}
		if m := miseLine.FindStringSubmatch(t); m != nil {
			if tool, ok := asdfNames[m[1]]; ok {
				out[tool] = m[2] + m[3]
			}
		}
	}
	return out
}

// askVersion asks a tool its version from inside the project, so shims answer for this folder.
var askVersion = map[string][]string{"node": {"node", "--version"}, "python": {"python3", "--version"}, "ruby": {"ruby", "--version"}}

var versionNumber = regexp.MustCompile(`(\d+(?:\.\d+)*)`)

// Matches says whether a running version satisfies a pin: "20" and "20.11" are prefixes of "20.11.1", "v" is
// ignored. Pins Catalyst cannot judge offline (lts/iron, latest, system, a range) return ok false.
func Matches(want, have string) (match, ok bool) {
	want = strings.TrimPrefix(strings.TrimSpace(want), "v")
	if want == "" || !regexp.MustCompile(`^\d+(\.\d+)*$`).MatchString(want) {
		return false, false
	}
	m := versionNumber.FindString(have)
	if m == "" {
		return false, false
	}
	return m == want || strings.HasPrefix(m, want+"."), true
}

func runIn(e *host.Env, dir string, argv ...string) run.Result {
	if r, ok := e.Run.(run.InDir); ok {
		return r.RunIn(dir, 8*time.Second, argv[0], argv[1:]...)
	}
	return e.Run.Run(8*time.Second, argv[0], argv[1:]...)
}

func comparePin(e *host.Env, dir string, p Pin) Finding {
	ask := askVersion[p.Tool]
	label := map[string]string{"node": "Node", "python": "Python", "ruby": "Ruby"}[p.Tool]
	if _, ok := e.SafeTool(ask[0]); !ok {
		return Finding{Level: Warn, File: p.File, Title: p.File + " asks for " + label + " " + p.Want + ", and " + ask[0] + " is not installed",
			Hint: installHint(p)}
	}
	r := runIn(e, dir, ask...)
	have := strings.TrimSpace(r.Stdout + " " + r.Stderr)
	if !r.OK() {
		return Finding{Level: Warn, File: p.File, Title: p.File + " asks for " + label + " " + p.Want + ", and " + ask[0] + " does not run here",
			Hint: firstLine(have) + ". " + installHint(p)}
	}
	got := versionNumber.FindString(have)
	match, judged := Matches(p.Want, have)
	switch {
	case !judged:
		return Finding{Level: OK, File: p.File, Title: p.File + " asks for " + label + " " + p.Want + ", and " + got + " runs here"}
	case match:
		return Finding{Level: OK, File: p.File, Title: label + " " + got + " runs here, as " + p.File + " asks"}
	}
	return Finding{Level: Warn, File: p.File, Title: p.File + " asks for " + label + " " + p.Want + ", but " + got + " runs here",
		Hint: installHint(p)}
}

// installHint names the command for whichever manager reads that file. Catalyst never runs it.
func installHint(p Pin) string {
	switch p.File {
	case ".nvmrc":
		return "With nvm: nvm install && nvm use. With fnm: fnm use --install-if-missing"
	case ".node-version":
		return "With fnm: fnm use --install-if-missing. With nodenv: nodenv install. With mise: mise install"
	case ".python-version":
		return "With pyenv: pyenv install " + p.Want + ". With uv: uv python install " + p.Want
	case ".ruby-version":
		return "With rbenv: rbenv install " + p.Want + ". With chruby: ruby-install " + p.Want
	case ".tool-versions":
		return "With asdf: asdf install. With mise: mise install"
	}
	return "With mise: mise install"
}

var goLine = regexp.MustCompile(`(?m)^go\s+(\d+\.\d+(?:\.\d+)?)\s*$`)

// goVersion compares go.mod's go line with the installed go. Since Go 1.21, go downloads a newer toolchain by itself
// when a module asks for one (unless GOTOOLCHAIN=local), so only an older go, or local-only, is a problem.
func goVersion(e *host.Env, dir, mod string) (Finding, bool) {
	m := goLine.FindStringSubmatch(mod)
	if m == nil {
		return Finding{}, false
	}
	want := m[1]
	if _, err := e.Look("go"); err != nil {
		return Finding{Level: Warn, File: "go.mod", Title: "go.mod asks for Go " + want + ", and go is not installed"}, true
	}
	r := runIn(e, dir, "go", "env", "GOVERSION", "GOTOOLCHAIN")
	f := strings.Fields(r.Stdout)
	if !r.OK() || len(f) == 0 {
		return Finding{}, false
	}
	have, toolchain := strings.TrimPrefix(f[0], "go"), ""
	if len(f) > 1 {
		toolchain = f[1]
	}
	if newerOrSame(have, want) {
		return Finding{Level: OK, File: "go.mod", Title: "Go " + have + " runs here, and go.mod asks for " + want}, true
	}
	if newerOrSame(have, "1.21") && !strings.HasPrefix(toolchain, "local") {
		return Finding{Level: OK, File: "go.mod", Title: "go.mod asks for Go " + want + ". Go " + have + " downloads it by itself on the first build"}, true
	}
	return Finding{Level: Warn, File: "go.mod", Title: "go.mod asks for Go " + want + ", but " + have + " runs here",
		Hint: "Install a newer Go, or allow toolchain downloads: go env -w GOTOOLCHAIN=auto"}, true
}

func newerOrSame(have, want string) bool {
	a, b := strings.Split(have, "."), strings.Split(want, ".")
	for i := 0; i < len(b); i++ {
		x, y := 0, 0
		if i < len(a) {
			x, _ = strconv.Atoi(strings.TrimLeft(a[i], "rcbeta"))
		}
		y, _ = strconv.Atoi(b[i])
		if x != y {
			return x > y
		}
	}
	return true
}

// lockfiles are what each package manager writes. Two at once means two people install with different tools, and
// each gets a different tree.
var lockfiles = []struct{ file, manager string }{
	{"package-lock.json", "npm"}, {"npm-shrinkwrap.json", "npm"}, {"yarn.lock", "yarn"}, {"pnpm-lock.yaml", "pnpm"},
	{"bun.lockb", "bun"}, {"bun.lock", "bun"},
}

func nodeProject(dir, pkgJSON string) []Finding {
	var out []Finding
	var pkg struct {
		PackageManager string `json:"packageManager"`
	}
	json.Unmarshal([]byte(pkgJSON), &pkg)
	var found []string
	managers := map[string]bool{}
	for _, l := range lockfiles {
		if host.Exists(filepath.Join(dir, l.file)) {
			found = append(found, l.file)
			managers[l.manager] = true
		}
	}
	if len(managers) > 1 {
		out = append(out, Finding{Level: Warn, Title: "Two package managers have written lockfiles here: " + strings.Join(found, " and "),
			Hint: "Each one installs a different tree. Keep the one the project uses and delete the other."})
	}
	if want, _, _ := strings.Cut(pkg.PackageManager, "@"); want != "" {
		for _, l := range lockfiles {
			if managers[l.manager] && l.manager != want && len(managers) == 1 {
				out = append(out, Finding{Level: Warn, File: "package.json", Title: "package.json says to use " + want + ", but the lockfile is " + l.file,
					Hint: "Someone installed with " + l.manager + ". Use " + want + " (corepack enable makes it automatic)."})
				break
			}
		}
	}
	if !host.Exists(filepath.Join(dir, "node_modules")) {
		cmd := "npm install"
		declared, _, _ := strings.Cut(pkg.PackageManager, "@")
		switch {
		case declared != "":
			cmd = declared + " install"
		case managers["pnpm"]:
			cmd = "pnpm install"
		case managers["yarn"]:
			cmd = "yarn install"
		case managers["bun"]:
			cmd = "bun install"
		}
		out = append(out, Finding{Level: Note, Title: "Dependencies are not installed yet", Hint: "Run: " + cmd})
	}
	return out
}

var envKey = regexp.MustCompile(`^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=`)

// EnvKeys lists the names set in an env file. Values are never read past the equals sign.
func EnvKeys(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if m := envKey.FindStringSubmatch(l); m != nil {
			out = append(out, m[1])
		}
	}
	return out
}

func envFiles(dir string) []Finding {
	var example string
	for _, f := range []string{".env.example", ".env.sample", ".env.template", ".env.dist"} {
		if host.Exists(filepath.Join(dir, f)) {
			example = f
			break
		}
	}
	if example == "" {
		return nil
	}
	if !host.Exists(filepath.Join(dir, ".env")) {
		return []Finding{{Level: Note, File: example, Title: "There is a " + example + " but no .env", Hint: "Copy it and fill it in: cp " + example + " .env"}}
	}
	have := map[string]bool{}
	for _, k := range EnvKeys(readFile(filepath.Join(dir, ".env"))) {
		have[k] = true
	}
	var missing []string
	for _, k := range EnvKeys(readFile(filepath.Join(dir, example))) {
		if !have[k] {
			missing = append(missing, k)
		}
	}
	if len(missing) == 0 {
		return []Finding{{Level: OK, File: ".env", Title: ".env has every setting " + example + " lists"}}
	}
	return []Finding{{Level: Warn, File: ".env", Title: ".env is missing " + plural(len(missing), "setting") + " that " + example + " lists",
		Hint: strings.Join(missing, ", ")}}
}

// hooks checks core.hooksPath, which tools like husky set. When its folder is missing, git silently runs no hooks.
func hooks(e *host.Env, dir string) (Finding, bool) {
	git, ok := e.SafeTool("git")
	if !ok || !host.Exists(filepath.Join(dir, ".git")) {
		return Finding{}, false
	}
	p, ok := e.Out(git, "-C", dir, "config", "--get", "core.hooksPath")
	if !ok || p == "" {
		return Finding{}, false
	}
	full := p
	if !filepath.IsAbs(full) {
		full = filepath.Join(dir, p)
	}
	if host.Exists(full) {
		return Finding{Level: OK, Title: "git hooks are set up (" + p + ")"}, true
	}
	hint := "Reinstall the hooks, often by installing the project's dependencies."
	if strings.Contains(p, "husky") {
		hint = "husky makes it when dependencies install: npm install (or your package manager's install)."
	}
	return Finding{Level: Warn, Title: "git is set to run hooks from " + p + ", which does not exist, so no hooks run", Hint: hint}, true
}

func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}
