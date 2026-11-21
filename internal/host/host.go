// Package host describes the machine: which OS, what the user's shell really sees, and how to read disks, memory,
// batteries and ports on macOS and Linux. Parsers are plain functions over text, so both systems test anywhere.
package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// Env is everything a check needs from the outside world. Tests build their own.
type Env struct {
	OS, Arch string // "darwin" or "linux"; "arm64" or "amd64"
	Home     string
	Shell    string // full path of the user's shell
	Run      run.Runner
	Look     func(string) (string, error)
	Getenv   func(string) string
	Now      func() time.Time
	Entries  []string          // the PATH a new terminal gets, in order
	JavaHome string            // JAVA_HOME as a new terminal sees it
	NvmDir   string            // NVM_DIR as a new terminal sees it
	Vars     map[string]string // ShellVars as a new terminal sees them, set only by LoadShell
	Hostname func() string
	hasCLT   *bool
	platMu   sync.Mutex
	plat     *Platform
}

// New reads the real machine. It asks a login shell for the environment, because a tool started from anywhere
// else would diagnose the wrong PATH. That is the most common reason an environment check lies.
func New() *Env {
	home, _ := os.UserHomeDir()
	if !filepath.IsAbs(home) { // HOME unset, empty or relative: every path built on it would land in the current folder
		home = passwdField("/etc/passwd", os.Getuid(), 5)
		if home != "" {
			os.Setenv("HOME", home) // git, ssh and the login shell read it too
		}
	}
	e := &Env{
		OS: runtime.GOOS, Arch: runtime.GOARCH, Home: home, Shell: os.Getenv("SHELL"),
		Run: run.Real{}, Look: exec.LookPath, Getenv: os.Getenv, Now: time.Now,
		Hostname: func() string { n, _ := os.Hostname(); return n },
	}
	if e.Shell == "" {
		e.Shell = passwdShell("/etc/passwd", os.Getuid())
	}
	e.Entries = splitPath(os.Getenv("PATH"))
	e.JavaHome = os.Getenv("JAVA_HOME")
	e.NvmDir = os.Getenv("NVM_DIR")
	return e
}

// passwdShell is the login shell the user database gives this user. docker exec, cron, dev containers and some IDE
// tasks start programs without SHELL, and without a shell to ask every PATH check would read the wrong PATH. A Mac
// keeps its users elsewhere, but Terminal always sets SHELL there.
func passwdShell(file string, uid int) string {
	if s := passwdField(file, uid, 6); !strings.HasSuffix(s, "nologin") && !strings.HasSuffix(s, "/false") {
		return s
	}
	return ""
}

// passwdField is one field of this user's line in the user database: 5 is the home folder, 6 the login shell. Only an
// absolute path counts.
func passwdField(file string, uid, field int) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	want := strconv.Itoa(uid)
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Split(line, ":"); len(f) == 7 && f[2] == want && filepath.IsAbs(f[field]) {
			return f[field]
		}
	}
	return ""
}

const pathMark = "__CATALYST_ENV__"

// shellScript prints, between markers, what a new terminal sees: PATH, JAVA_HOME and NVM_DIR in one block, then each of
// ShellVars in its own. The last marker closes the last value, so whatever the shell prints on exit is not in it.
func shellScript() string {
	s := `printf '\n` + pathMark + `%s\n%s\n%s\n` + pathMark + `\n' "$PATH" "$JAVA_HOME" "$NVM_DIR"`
	for _, v := range ShellVars {
		s += `; printf '` + pathMark + `%s\n' "$` + v + `"`
	}
	return s + `; printf '` + pathMark + `\n'`
}

// LoadShell replaces the inherited environment with what a new terminal sees. Interactive and login, since nvm and most
// PATH lines live in .zshrc. The markers skip anything the startup files print. It can take seconds, so commands that do
// not care about the environment do not call it.
func (e *Env) LoadShell() {
	if e.Shell == "" {
		return
	}
	script := shellScript()
	r := e.Run.Run(12*time.Second, e.Shell, "-l", "-i", "-c", script)
	if !r.OK() && r.Stdout == "" {
		return
	}
	parts := strings.Split(r.Stdout, pathMark)
	if len(parts) < 3 {
		return
	}
	lines := strings.Split(parts[1], "\n")
	if len(lines) < 3 {
		return
	}
	if p := splitPath(lines[0]); len(p) > 0 {
		e.Entries = p
		if e.Getenv != nil { // the real process only: from here on, programs resolve exactly as in a terminal
			os.Setenv("PATH", strings.Join(p, ":"))
		}
	}
	e.JavaHome, e.NvmDir = lines[1], lines[2]
	// parts[2] is the newline after the first block, and each variable follows in its own part.
	if extra := parts[3:]; len(extra) > len(ShellVars) {
		e.Vars = map[string]string{}
		for i, v := range ShellVars {
			e.Vars[v] = strings.TrimSuffix(strings.TrimPrefix(extra[i], "\n"), "\n")
		}
	}
}

// ShellVars are the variables checks read as a new terminal sees them: proxies and certificate bundles, which break
// installs when they point at nothing. Values stay in memory and are never printed.
var ShellVars = []string{
	"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy",
	"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO",
	"PIP_CERT", "AWS_CA_BUNDLE", "NPM_CONFIG_CAFILE", "npm_config_cafile",
}

// Var is a variable as a new terminal sees it, or as Catalyst was started with when the shell was not asked.
func (e *Env) Var(name string) string {
	if e.Vars != nil {
		return e.Vars[name]
	}
	if e.Getenv != nil {
		return e.Getenv(name)
	}
	return ""
}

func splitPath(p string) []string {
	var out []string
	for _, s := range strings.Split(p, ":") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// Path is a location inside the home folder.
func (e *Env) Path(parts ...string) string {
	return filepath.Join(append([]string{e.Home}, parts...)...)
}

// Tilde shortens the home folder to ~ for display.
func (e *Env) Tilde(p string) string {
	if p == e.Home {
		return "~"
	}
	if strings.HasPrefix(p, e.Home+"/") {
		p = "~" + p[len(e.Home):]
	}
	return ui.Printable(p) // a name can hold a newline or an escape, and this is how paths reach the screen
}

// Out runs a program with the default time limit and returns its trimmed output and whether it worked.
func (e *Env) Out(name string, args ...string) (string, bool) {
	r := e.Run.Run(run.Default, name, args...)
	return r.Text(), r.OK()
}

// Mac and Linux say which system this is.
func (e *Env) Mac() bool   { return e.OS == "darwin" }
func (e *Env) Linux() bool { return e.OS == "linux" }

// Exists reports whether a path is there.
func Exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// HasCLT reports whether Apple's Command Line Tools or Xcode are present, without running anything that could open
// Apple's install dialog. Always true on Linux.
func (e *Env) HasCLT() bool {
	if !e.Mac() {
		return true
	}
	if e.hasCLT == nil {
		v := Exists("/Library/Developer/CommandLineTools/usr/bin") || Exists("/Applications/Xcode.app/Contents/Developer")
		e.hasCLT = &v
	}
	return *e.hasCLT
}

// SetCLT fixes the answer for tests.
func (e *Env) SetCLT(v bool) { e.hasCLT = &v }

// macStubs are the programs in /usr/bin that, on a Mac with no Command Line Tools, open a dialog instead of running.
var macStubs = map[string]bool{"git": true, "python3": true, "pip3": true, "cc": true, "gcc": true, "clang": true, "make": true, "swift": true, "ld": true}

// SafeTool finds a program and says whether running it is safe. A stub on a Mac with no tools is treated as not installed.
func (e *Env) SafeTool(name string) (string, bool) {
	p, err := e.Look(name)
	if err != nil {
		return "", false
	}
	if e.Mac() && !e.HasCLT() && macStubs[name] && strings.HasPrefix(p, "/usr/bin/") {
		return "", false
	}
	return p, true
}

// RCFiles are the startup files of the shells people use, whether or not they exist.
func (e *Env) RCFiles() []string {
	return []string{
		e.Path(".zshenv"), e.Path(".zprofile"), e.Path(".zshrc"), e.Path(".zlogin"),
		e.Path(".profile"), e.Path(".bash_profile"), e.Path(".bash_login"), e.Path(".bashrc"),
		e.Path(".config", "fish", "config.fish"),
	}
}

// ForTest builds an environment with no real programs behind it.
func ForTest(home, goos string, r run.Runner) *Env {
	return &Env{
		OS: goos, Arch: "arm64", Home: home, Run: r,
		Look:     func(string) (string, error) { return "", exec.ErrNotFound },
		Now:      time.Now,
		Hostname: func() string { return "alex-laptop" },
		plat:     testPlatform(goos),
	}
}

// testPlatform keeps tests from reading the machine they run on. Tests that care set their own with SetPlatform.
func testPlatform(goos string) *Platform {
	p := Platform{OS: goos, Arch: "arm64", Pretty: "Linux", Family: "unknown", Sudo: true, Managers: []string{}}
	if goos == "darwin" {
		p.Pretty, p.Family, p.Init = "macOS 15.1", "macos", "launchd"
	}
	return &p
}
