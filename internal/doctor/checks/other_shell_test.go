package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func shellEnv(t *testing.T, shell string) *host.Env {
	t.Helper()
	old := etc
	etc = t.TempDir()
	t.Cleanup(func() { etc = old })
	e, _ := env(t, "linux", nil, nil)
	e.Shell = "/bin/" + shell
	e.Entries = []string{"/usr/bin", "/bin"}
	return e
}

func TestOtherShellNvmOnlyInBash(t *testing.T) {
	e := shellEnv(t, "zsh")
	write(t, e.Path(".nvm", "nvm.sh"), "", 0o644)
	write(t, e.Path(".bashrc"), "# nvm\nexport NVM_DIR=\"$HOME/.nvm\"\n[ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\"\n", 0o644)
	write(t, e.Path(".zshrc"), "export EDITOR=vim\n", 0o644)
	r := one(t, otherShell(e))
	if r.Severity != d.Warning || r.Title != "nvm is set up for bash (~/.bashrc), but your shell is zsh" || !strings.Contains(r.Hint, "Copy its lines into ~/.zshrc") || !strings.Contains(r.Hint, `\. "$NVM_DIR/nvm.sh"`) {
		t.Fatalf("%+v", r)
	}
	write(t, e.Path(".zshrc"), "plugins=(git nvm)\nsource $ZSH/oh-my-zsh.sh\n", 0o644)
	if r := one(t, otherShell(e)); r.State != d.Passed {
		t.Fatalf("a plugin that names it counts: %+v", r)
	}
}

func TestOtherShellWorkingIsNeverReported(t *testing.T) {
	e := shellEnv(t, "zsh")
	write(t, e.Path(".cargo", "bin", "cargo"), "", 0o755)
	write(t, e.Path(".bashrc"), ". \"$HOME/.cargo/env\"\n", 0o644)
	e.Entries = append(e.Entries, e.Path(".cargo", "bin"))
	if r := one(t, otherShell(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	e.Entries = e.Entries[:2]
	if r := one(t, otherShell(e)); !strings.Contains(r.Title, "Rust (cargo) is set up for bash") {
		t.Fatalf("%+v", r)
	}
}

func TestOtherShellFishAndToolsThatNameTheirShell(t *testing.T) {
	e := shellEnv(t, "fish")
	write(t, e.Path(".pyenv", "bin", "pyenv"), "", 0o755)
	write(t, e.Path(".zshrc"), "eval \"$(pyenv init -)\"\n", 0o644)
	r := one(t, otherShell(e))
	if !strings.Contains(r.Title, "pyenv is set up for zsh") || !strings.Contains(r.Hint, "pyenv init - fish | source") {
		t.Fatalf("%+v", r)
	}
	e = shellEnv(t, "zsh")
	write(t, e.Path(".local", "bin", "mise"), "", 0o755)
	write(t, e.Path(".bashrc"), "eval \"$(~/.local/bin/mise activate bash)\"\n", 0o644)
	r = one(t, otherShell(e))
	if !strings.Contains(r.Hint, `eval "$(mise activate zsh)"`) {
		t.Fatalf("%+v", r)
	}
	e = shellEnv(t, "bash")
	write(t, e.Path(".rbenv", "bin", "rbenv"), "", 0o755)
	write(t, e.Path(".zshrc"), "eval \"$(rbenv init - zsh)\"\n", 0o644)
	r = one(t, otherShell(e))
	if !strings.Contains(r.Hint, `eval "$(rbenv init - bash)"`) {
		t.Fatalf("the copied line is for bash: %+v", r)
	}
}
