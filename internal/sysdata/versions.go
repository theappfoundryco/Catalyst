package sysdata

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/project"
)

// A language version manager keeps every version ever installed, at a few hundred MB each, and none of them says which
// are still used. These are offered one by one, each removed by its own manager's command, and only when Catalyst can
// see it is not the default, not what runs now and not pinned by a project in the usual code folders. When it cannot
// tell, the version stays out of the list.

// manager is one version manager and where it keeps versions.
type manager struct {
	name  string // nvm, pyenv
	lang  string // Node, Python
	tool  string // the project pin it answers to: node, python, ruby, java
	dirs  []string
	strip string // a prefix on the folder names, such as nvm's "v"
}

// projectRoots are the folders people keep code in. Only these are read for pins, two levels deep, so a home folder
// with years of projects stays quick.
var projectRoots = []string{"code", "Code", "Developer", "dev", "src", "projects", "Projects", "work", "repos", "git", "Documents/GitHub", "workspace"}

// safeVersion is what a version folder may be called before its name is passed to a command.
var safeVersion = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]*$`)

// versionFloor leaves out versions too small to be worth a row.
const versionFloor = 20_000_000

func versionAreas(e *host.Env, size Measure) []Area {
	nvm := e.NvmDir
	if nvm == "" {
		nvm = e.Path(".nvm")
	}
	fnm := []string{e.Path(".local", "share", "fnm", "node-versions"), e.Path("Library", "Application Support", "fnm", "node-versions")}
	managers := []manager{
		{"nvm", "Node", "node", []string{filepath.Join(nvm, "versions", "node")}, "v"},
		{"fnm", "Node", "node", fnm, "v"},
		{"pyenv", "Python", "python", []string{e.Path(".pyenv", "versions")}, ""},
		{"rbenv", "Ruby", "ruby", []string{e.Path(".rbenv", "versions")}, ""},
		{"SDKMAN", "Java", "java", []string{e.Path(".sdkman", "candidates", "java")}, ""},
	}
	pins := projectPins(e)
	var out []Area
	for _, m := range managers {
		for _, dir := range m.dirs {
			out = append(out, unusedIn(e, m, dir, nvm, pins, size)...)
		}
	}
	for _, t := range []struct{ name, dir string }{{"mise", e.Path(".local", "share", "mise", "installs")}, {"asdf", e.Path(".asdf", "installs")}} {
		out = append(out, unusedShared(e, t.name, t.dir, pins, size)...)
	}
	return append(out, simRuntimes(e)...)
}

// unusedIn lists one manager's versions that nothing is seen to use.
func unusedIn(e *host.Env, m manager, dir, nvm string, pins map[string][]string, size Measure) []Area {
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var versions []string
	for _, it := range items {
		if it.IsDir() && it.Type()&os.ModeSymlink == 0 && safeVersion.MatchString(it.Name()) && it.Name() != "current" && it.Name() != "system" {
			versions = append(versions, it.Name())
		}
	}
	keep := defaultsOf(e, m.name, dir, nvm)
	if keep == nil {
		return nil // no default can be read, so which one is in use is unknown: offer nothing
	}
	var out []Area
	for _, v := range versions {
		path := filepath.Join(dir, v)
		if kept(strings.TrimPrefix(v, m.strip), keep, pins[m.tool]) || running(e, path) {
			continue
		}
		cmd, how := uninstall(e, m.name, v, nvm)
		a := Area{Name: m.lang + " " + strings.TrimPrefix(v, m.strip) + " (" + m.name + ")", Path: path, Way: Owner, Command: cmd, Shows: shown(m.name, v),
			About: "Not your " + m.name + " default, not what runs now, and no project in your code folders asks for it.",
			Cost:  "If a project needs it again: " + how}
		if cmd == nil {
			a.Way, a.Cost = Locked, m.name+" is not set up in this shell, so there is no safe way to remove it from here."
		}
		if a.Bytes = size(path); a.Bytes >= versionFloor {
			out = append(out, a)
		}
	}
	return out
}

// defaultsOf reads which versions a manager treats as the default. nil means it could not be told.
func defaultsOf(e *host.Env, name, dir, nvm string) []string {
	first := func(p string) []string {
		b, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		var out []string
		for _, l := range strings.Split(string(b), "\n") {
			if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
				out = append(out, l)
			}
		}
		return out
	}
	link := func(p string) []string {
		if t, err := os.Readlink(p); err == nil {
			return []string{filepath.Base(t)}
		}
		return nil
	}
	switch name {
	case "nvm":
		d := first(filepath.Join(nvm, "alias", "default"))
		if len(d) == 0 || !numeric(d[0]) {
			return nil // lts/* or node: nvm resolves those itself, and a wrong guess would offer the one in use
		}
		return d
	case "fnm":
		return link(filepath.Join(filepath.Dir(dir), "aliases", "default"))
	case "pyenv":
		if d := first(e.Path(".pyenv", "version")); d != nil {
			return d
		}
		return []string{"system"}
	case "rbenv":
		if d := first(e.Path(".rbenv", "version")); d != nil {
			return d
		}
		return []string{"system"}
	case "SDKMAN":
		return link(filepath.Join(dir, "current"))
	}
	return nil
}

func numeric(v string) bool { return regexp.MustCompile(`^v?\d+(\.\d+)*$`).MatchString(v) }

// kept is true when a version answers to the default or to a pin: "20" keeps every 20.x, so nothing a project might
// resolve to is offered.
func kept(v string, keep, pins []string) bool {
	for _, want := range append(append([]string{}, keep...), pins...) {
		want = strings.TrimPrefix(want, "v")
		if want == v {
			return true
		}
		if m, ok := project.Matches(want, v); ok && m {
			return true
		}
		if m, ok := project.Satisfies(want, v); ok && m {
			return true
		}
	}
	return false
}

// running is true when the PATH a new terminal gets goes through that version's folder.
func running(e *host.Env, dir string) bool {
	for _, p := range e.Entries {
		if p == dir || strings.HasPrefix(p, dir+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// uninstall is the manager's own command for one version, and how to get it back. nvm and SDKMAN are shell functions,
// so their script is fixed and the version only ever arrives as an argument, never as part of the script.
func uninstall(e *host.Env, name, v, nvm string) (cmd []string, back string) {
	bin := func(tool string, alt ...string) string {
		if p, err := e.Look(tool); err == nil {
			return p
		}
		for _, a := range alt {
			if host.Exists(a) {
				return a
			}
		}
		return ""
	}
	switch name {
	case "nvm":
		if host.Exists(filepath.Join(nvm, "nvm.sh")) {
			return []string{"bash", "-c", `. "$1/nvm.sh" && nvm uninstall "$2"`, "nvm", nvm, v}, "nvm install " + v
		}
		return nil, "nvm install " + v
	case "fnm":
		if p := bin("fnm"); p != "" {
			return []string{p, "uninstall", v}, "fnm install " + v
		}
		return nil, "fnm install " + v
	case "pyenv":
		if p := bin("pyenv", e.Path(".pyenv", "bin", "pyenv")); p != "" {
			return []string{p, "uninstall", "-f", v}, "pyenv install " + v
		}
		return nil, "pyenv install " + v
	case "rbenv":
		if p := bin("rbenv", e.Path(".rbenv", "bin", "rbenv")); p != "" {
			return []string{p, "uninstall", "-f", v}, "rbenv install " + v
		}
		return nil, "rbenv install " + v
	case "SDKMAN":
		init := e.Path(".sdkman", "bin", "sdkman-init.sh")
		if host.Exists(init) {
			return []string{"bash", "-c", `. "$1" && sdk uninstall java "$2"`, "sdk", init, v}, "sdk install java " + v
		}
		return nil, "sdk install java " + v
	}
	return nil, ""
}

// shown is the command as a person reads it: the tool's own name, not the path it was found at, and not the fixed
// shell script nvm and SDKMAN need.
func shown(name, v string) []string {
	switch name {
	case "nvm":
		return []string{"nvm", "uninstall", v}
	case "SDKMAN":
		return []string{"sdk", "uninstall", "java", v}
	case "fnm":
		return []string{"fnm", "uninstall", v}
	case "pyenv", "rbenv":
		return []string{name, "uninstall", "-f", v}
	}
	return nil
}

// unusedShared covers mise and asdf, which keep every language in one folder: installs/TOOL/VERSION.
func unusedShared(e *host.Env, name, dir string, pins map[string][]string, size Measure) []Area {
	tools, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	global := map[string][]string{}
	if name == "mise" {
		for t, v := range miseAll(readText(e.Path(".config", "mise", "config.toml"))) {
			global[t] = append(global[t], v...)
		}
	}
	for t, v := range toolVersionsAll(readText(e.Path(".tool-versions"))) { // mise reads it too
		global[t] = append(global[t], v...)
	}
	bin, _ := e.Look(name)
	for _, p := range map[string][]string{"mise": {e.Path(".local", "bin", "mise")}, "asdf": {e.Path(".asdf", "bin", "asdf")}}[name] {
		if bin == "" && host.Exists(p) {
			bin = p // where its own installer puts it, which a shell may not have on PATH yet
		}
	}
	var out []Area
	for _, t := range tools {
		if !t.IsDir() || !safeVersion.MatchString(t.Name()) {
			continue
		}
		if len(global[t.Name()]) == 0 {
			continue // no global version for this tool, so which one is in use cannot be told
		}
		lang := map[string]string{"nodejs": "node", "node": "node", "python": "python", "ruby": "ruby", "java": "java"}[t.Name()]
		versions, _ := os.ReadDir(filepath.Join(dir, t.Name()))
		for _, v := range versions {
			if !v.IsDir() || v.Type()&os.ModeSymlink != 0 || !safeVersion.MatchString(v.Name()) {
				continue // mise links "20" and "latest" to a real version: only real folders count
			}
			path := filepath.Join(dir, t.Name(), v.Name())
			if kept(v.Name(), global[t.Name()], pins[lang]) || running(e, path) {
				continue
			}
			label := map[string]string{"nodejs": "Node", "node": "Node", "python": "Python", "ruby": "Ruby", "java": "Java", "go": "Go", "golang": "Go", "rust": "Rust"}[t.Name()]
			if label == "" {
				label = t.Name()
			}
			a := Area{Name: label + " " + v.Name() + " (" + name + ")", Path: path, Way: Owner,
				About: "Not your global " + t.Name() + " in " + name + ", not what runs now, and no project in your code folders asks for it.",
				Cost:  "If a project needs it again: " + name + " install " + t.Name() + "@" + v.Name()}
			switch {
			case bin == "":
				a.Way, a.Cost = Locked, name+" is not on your PATH, so there is no safe way to remove it from here."
			case name == "mise":
				a.Command = []string{bin, "uninstall", t.Name() + "@" + v.Name()}
				a.Shows = []string{"mise", "uninstall", t.Name() + "@" + v.Name()}
			default:
				a.Command = []string{bin, "uninstall", t.Name(), v.Name()}
				a.Shows = []string{"asdf", "uninstall", t.Name(), v.Name()}
				a.Cost = "If a project needs it again: asdf install " + t.Name() + " " + v.Name()
			}
			if a.Bytes = size(path); a.Bytes >= versionFloor {
				out = append(out, a)
			}
		}
	}
	return out
}

func readText(p string) string { b, _ := os.ReadFile(p); return string(b) }

// toolVersionsAll reads .tool-versions for every tool and every version listed, since asdf may keep several.
func toolVersionsAll(text string) map[string][]string {
	out := map[string][]string{}
	for _, l := range strings.Split(text, "\n") {
		if f := strings.Fields(strings.SplitN(l, "#", 2)[0]); len(f) >= 2 {
			out[f[0]] = append(out[f[0]], f[1:]...)
		}
	}
	return out
}

var miseAny = regexp.MustCompile(`^\s*"?([a-z0-9_-]+)"?\s*=\s*(?:"([^"]+)"|\[([^\]]*)\])`)

// miseAll reads the [tools] table of mise's global config, with every version of a list.
func miseAll(text string) map[string][]string {
	out := map[string][]string{}
	in := false
	for _, l := range strings.Split(text, "\n") {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "[") && !strings.Contains(t, "=") {
			in = t == "[tools]"
			continue
		}
		if m := miseAny.FindStringSubmatch(t); in && m != nil {
			if m[2] != "" {
				out[m[1]] = append(out[m[1]], m[2])
			}
			for _, v := range strings.Split(m[3], ",") {
				if v = strings.Trim(strings.TrimSpace(v), `"`); v != "" {
					out[m[1]] = append(out[m[1]], v)
				}
			}
		}
	}
	return out
}

// projectPins collects the versions projects in the usual code folders ask for, by tool.
func projectPins(e *host.Env) map[string][]string {
	out := map[string][]string{}
	var visit func(dir string, depth int)
	visit = func(dir string, depth int) {
		for _, p := range project.Pins(dir) {
			out[p.Tool] = append(out[p.Tool], p.Want)
		}
		if depth == 0 {
			return
		}
		items, _ := os.ReadDir(dir)
		for _, it := range items {
			if it.IsDir() && !strings.HasPrefix(it.Name(), ".") && it.Name() != "node_modules" && it.Name() != "vendor" {
				visit(filepath.Join(dir, it.Name()), depth-1)
			}
		}
	}
	for _, r := range projectRoots {
		if dir := e.Path(strings.Split(r, "/")...); host.Exists(dir) {
			visit(dir, 2)
		}
	}
	return out
}

// simRuntime is one simulator runtime as xcrun simctl runtime list -j reports it.
type simRuntime struct {
	Identifier string `json:"identifier"`
	Version    string `json:"version"`
	Platform   string `json:"platformIdentifier"`
	Size       int64  `json:"sizeBytes"`
	Deletable  bool   `json:"deletable"`
}

// simRuntimes offers simulator runtimes older than the newest of their platform. Each is several GB, Xcode keeps every
// one it ever downloaded, and Xcode's own command removes them.
func simRuntimes(e *host.Env) []Area {
	if !e.Mac() {
		return nil
	}
	if _, err := e.Look("xcrun"); err != nil || !e.HasCLT() {
		return nil
	}
	s, ok := e.Out("xcrun", "simctl", "runtime", "list", "-j")
	if !ok {
		return nil
	}
	return ParseSimRuntimes(s)
}

// ParseSimRuntimes reads simctl's runtime list and returns the older runtimes of each platform as areas.
func ParseSimRuntimes(text string) []Area {
	all := map[string]simRuntime{}
	if json.Unmarshal([]byte(text), &all) != nil {
		return nil
	}
	newest := map[string]string{}
	for _, r := range all {
		if newer(r.Version, newest[r.Platform]) {
			newest[r.Platform] = r.Version
		}
	}
	var out []Area
	for _, r := range all {
		if !r.Deletable || r.Version == newest[r.Platform] || !safeVersion.MatchString(r.Identifier) || r.Size <= 0 {
			continue
		}
		platform := strings.TrimSuffix(strings.TrimPrefix(r.Platform, "com.apple.platform."), "simulator")
		platform = map[string]string{"iphone": "iOS", "appletv": "tvOS", "watch": "watchOS", "xr": "visionOS"}[platform]
		if platform == "" {
			platform = "Simulator"
		}
		out = append(out, Area{Name: platform + " " + r.Version + " simulator runtime", Bytes: r.Size, Way: Owner,
			Command: []string{"xcrun", "simctl", "runtime", "delete", r.Identifier},
			About:   "An older simulator system. Xcode keeps every one it downloaded, and you have a newer " + platform + " one.",
			Cost:    "Simulators that use it go with it. Xcode, Settings, Components downloads it again if you need it."})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Bytes > out[j].Bytes })
	return out
}

// newer compares dotted versions, so 17.10 is newer than 17.9.
func newer(a, b string) bool {
	if b == "" {
		return true
	}
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x = atoi(pa[i])
		}
		if i < len(pb) {
			y = atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	return n
}
