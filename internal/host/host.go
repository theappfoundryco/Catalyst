// Package host describes the machine: which OS, what the user's shell really sees, and how to read disks, memory,
// batteries and ports on macOS and Linux. Parsers are plain functions over text, so both systems test anywhere.
package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/run"
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
	Entries  []string // the PATH a new terminal gets, in order
	JavaHome string   // JAVA_HOME as a new terminal sees it
	NvmDir   string   // NVM_DIR as a new terminal sees it
	hasCLT   *bool
}

// New reads the real machine. It asks a login shell for the environment, because a tool started from anywhere
// else would diagnose the wrong PATH. That is the most common reason an environment check lies.
func New() *Env {
	home, _ := os.UserHomeDir()
	e := &Env{
		OS: runtime.GOOS, Arch: runtime.GOARCH, Home: home, Shell: os.Getenv("SHELL"),
		Run: run.Real{}, Look: exec.LookPath, Getenv: os.Getenv, Now: time.Now,
	}
	e.Entries = splitPath(os.Getenv("PATH"))
	e.JavaHome = os.Getenv("JAVA_HOME")
	e.NvmDir = os.Getenv("NVM_DIR")
	return e
}

const pathMark = "__CATALYST_ENV__"

// LoadShell replaces the inherited environment with what a new terminal sees. Interactive and login, since nvm and most
// PATH lines live in .zshrc. The markers skip anything the startup files print. It can take seconds, so commands that do
// not care about the environment do not call it.
func (e *Env) LoadShell() {
	if e.Shell == "" {
		return
	}
	script := `printf '\n` + pathMark + `%s\n%s\n%s\n` + pathMark + `\n' "$PATH" "$JAVA_HOME" "$NVM_DIR"`
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
		return "~" + p[len(e.Home):]
	}
	return p
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
		Look: func(string) (string, error) { return "", exec.ErrNotFound },
		Now:  time.Now,
	}
}
