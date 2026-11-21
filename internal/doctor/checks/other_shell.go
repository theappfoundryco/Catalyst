package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "shell.othershell", Group: d.GroupShell, Name: "Checking that your tools are set up for your shell", Run: otherShell})
}

// shellTool is a tool that needs a line in a shell's startup file to work.
type shellTool struct {
	name      string
	word      string   // the name its lines use, to see whether your own files mention it at all
	installed []string // any of these existing means it is installed (relative to home unless absolute)
	onPath    string   // a piece of a PATH folder that proves it already works in a new terminal ("" when it adds none)
	setup     []string // what its own setup line contains, to find it in another shell's files
	fish      string   // the line fish needs instead, since fish cannot run the others
	init      string   // the tool's own command that writes its setup for a shell (%s), when copying lines would not work
}

var shellTools = []shellTool{
	{"Homebrew", "brew", []string{"/opt/homebrew/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew", ".linuxbrew/bin/brew"}, "brew/bin", []string{"brew shellenv"}, "eval (brew shellenv)", ""},
	{"nvm", "nvm", []string{".nvm/nvm.sh"}, "", []string{"nvm.sh"}, "", ""},
	{"pyenv", "pyenv", []string{".pyenv/bin/pyenv", ".pyenv/libexec/pyenv"}, "/.pyenv/", []string{"pyenv init"}, "pyenv init - fish | source", ""},
	{"rbenv", "rbenv", []string{".rbenv/bin/rbenv", "/opt/homebrew/bin/rbenv"}, "/.rbenv/", []string{"rbenv init"}, "rbenv init - fish | source", ""},
	{"conda", "conda", []string{"miniconda3/bin/conda", "anaconda3/bin/conda", "miniforge3/bin/conda", "mambaforge/bin/conda"}, "conda", []string{"conda initialize", "conda.sh", "conda shell."}, "conda init fish", "conda init %s"},
	{"Rust (cargo)", "cargo", []string{".cargo/bin/cargo"}, "/.cargo/bin", []string{".cargo/env", ".cargo/bin"}, "fish_add_path ~/.cargo/bin", ""},
	{"mise", "mise", []string{".local/bin/mise", "/opt/homebrew/bin/mise"}, "/mise/", []string{"mise activate"}, "mise activate fish | source", `eval "$(mise activate %s)"`},
	{"fnm", "fnm", []string{".local/share/fnm/fnm", "/opt/homebrew/bin/fnm"}, "fnm_multishells", []string{"fnm env"}, "fnm env --use-on-cd | source", ""},
	{"SDKMAN", "sdkman", []string{".sdkman/bin/sdkman-init.sh"}, "/.sdkman/", []string{"sdkman-init.sh"}, "", ""},
	{"asdf", "asdf", []string{".asdf/asdf.sh"}, "/.asdf/", []string{"asdf.sh", "asdf/shims"}, "", ""},
	{"Volta", "volta", []string{".volta/bin/volta"}, "/.volta/", []string{"VOLTA_HOME", ".volta/bin"}, "fish_add_path ~/.volta/bin", ""},
	{"Bun", "bun", []string{".bun/bin/bun"}, "/.bun/", []string{"BUN_INSTALL", ".bun/bin"}, "fish_add_path ~/.bun/bin", ""},
}

// The commonest "command not found" after a move to zsh (macOS switched in 2019) or to fish: the tool is installed
// and its setup line is in the old shell's file, so the new shell never runs it. Only that exact case is reported:
// the tool is installed, it is not working in a new terminal, your shell's files never mention it, and another
// shell's files have its setup line.
func otherShell(e *host.Env) []d.Result {
	mine := filepath.Base(e.Shell)
	files := shellFiles(e)
	if _, ok := files[mine]; !ok {
		return []d.Result{d.Skip("Your shell is not bash, zsh or fish")}
	}
	var out []d.Result
	installed := 0
	for _, t := range shellTools {
		if !toolInstalled(e, t) {
			continue
		}
		installed++
		if t.onPath != "" && onPath(e, t.onPath) {
			continue // it already works in a new terminal, however it got there
		}
		if mentions(files[mine], t.word, t.setup) {
			continue
		}
		for _, other := range []string{"zsh", "bash", "fish"} {
			if other == mine {
				continue
			}
			file, lines := setupLines(files[other], t.setup)
			if file == "" {
				continue
			}
			target := filepath.Base(files[mine][0].path)
			hint := "So it is not there in a new " + mine + " terminal. "
			switch {
			case mine == "fish" && t.fish != "":
				hint += "fish needs its own line. Add it to ~/.config/fish/config.fish:\n" + t.fish
			case mine == "fish":
				hint += "Its " + other + " lines do not work in fish. " + t.name + " has its own instructions for fish."
			case t.init != "":
				hint += "Let it write its setup for " + mine + ", then open a new terminal:\n" + fmt.Sprintf(t.init, mine)
			case other == "fish":
				hint += "Its fish line does not work in " + mine + ". Follow " + t.name + "'s instructions for " + mine + ", into ~/" + target + "."
			default:
				for i, l := range lines { // "mise activate bash", "shell.bash": the line names its shell
					lines[i] = shellWord.ReplaceAllStringFunc(l, func(w string) string { return strings.Replace(w, other, mine, 1) })
				}
				hint += "Copy its lines into ~/" + target + ", then open a new terminal:\n" + strings.Join(lines, "\n")
			}
			out = append(out, d.Warn(t.name+" is set up for "+other+" ("+e.Tilde(file)+"), but your shell is "+mine).With(hint))
			break
		}
	}
	if len(out) > 0 {
		return out
	}
	if installed == 0 {
		return []d.Result{d.Skip("None of the tools that need a startup line are installed")}
	}
	return []d.Result{d.Pass("Your tools are set up for " + mine)}
}

// shellWord is a shell's name used as a word in a setup line, such as "init - bash" or "shell.zsh".
var shellWord = regexp.MustCompile(`\b(bash|zsh)\b`)

// etc is where the system-wide startup files are. A variable, so tests read their own.
var etc = "/etc"

type rcFile struct {
	path string
	text string
}

// shellFiles reads each shell's own startup files. The first file of each shell is where a new line belongs.
func shellFiles(e *host.Env) map[string][]rcFile {
	zdot := e.Home
	if z := e.Var("ZDOTDIR"); z != "" {
		zdot = z
	}
	paths := map[string][]string{
		"zsh":  {filepath.Join(zdot, ".zshrc"), filepath.Join(zdot, ".zshenv"), filepath.Join(zdot, ".zprofile"), filepath.Join(zdot, ".zlogin"), filepath.Join(etc, "zshrc"), filepath.Join(etc, "zsh", "zshrc"), filepath.Join(etc, "zprofile"), filepath.Join(etc, "zsh", "zprofile")},
		"bash": {e.Path(".bashrc"), e.Path(".bash_profile"), e.Path(".bash_login"), e.Path(".profile"), filepath.Join(etc, "profile"), filepath.Join(etc, "bashrc"), filepath.Join(etc, "bash.bashrc")},
		"fish": {e.Path(".config", "fish", "config.fish")},
	}
	if e.Mac() {
		paths["bash"][0], paths["bash"][1] = paths["bash"][1], paths["bash"][0] // a Mac terminal opens login shells
	}
	if conf, _ := filepath.Glob(e.Path(".config", "fish", "conf.d", "*.fish")); len(conf) > 0 {
		paths["fish"] = append(paths["fish"], conf...)
	}
	if prof, _ := filepath.Glob(filepath.Join(etc, "profile.d", "*.sh")); len(prof) > 0 {
		paths["bash"] = append(paths["bash"], prof...)
		paths["zsh"] = append(paths["zsh"], prof...) // most systems' zprofile reads these too
	}
	out := map[string][]rcFile{}
	for shell, ps := range paths {
		for i, p := range ps {
			b, err := os.ReadFile(p)
			if err != nil && i > 0 {
				continue
			}
			out[shell] = append(out[shell], rcFile{p, string(b)}) // the first is kept even when missing: a line goes there
		}
	}
	return out
}

func toolInstalled(e *host.Env, t shellTool) bool {
	for _, p := range t.installed {
		if !filepath.IsAbs(p) {
			p = e.Path(p)
		}
		if host.Exists(p) {
			return true
		}
	}
	return false
}

func onPath(e *host.Env, piece string) bool {
	for _, dir := range e.Entries {
		if strings.Contains(filepath.ToSlash(dir), piece) {
			return true
		}
	}
	return false
}

// mentions is generous on purpose: any line in your own shell's files that names the tool or holds its setup counts,
// including a plugin list, since a framework such as Oh My Zsh may load it.
func mentions(files []rcFile, word string, setup []string) bool {
	for _, f := range files {
		text := strings.ToLower(f.text)
		if strings.Contains(text, word) {
			return true
		}
		for _, s := range setup {
			if strings.Contains(text, strings.ToLower(s)) {
				return true
			}
		}
	}
	return false
}

// setupLines finds the first file holding the tool's setup, and its lines that do so, comments left out.
func setupLines(files []rcFile, setup []string) (string, []string) {
	for _, f := range files {
		var lines []string
		for _, l := range strings.Split(f.text, "\n") {
			t := strings.TrimSpace(l)
			if t == "" || strings.HasPrefix(t, "#") {
				continue
			}
			for _, s := range setup {
				if strings.Contains(t, s) {
					lines = append(lines, t)
					break
				}
			}
		}
		if len(lines) > 0 {
			if len(lines) > 4 {
				lines = lines[:4]
			}
			return f.path, lines
		}
	}
	return "", nil
}
