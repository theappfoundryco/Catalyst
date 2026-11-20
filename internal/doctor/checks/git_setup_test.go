package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func gitConfig(r map[string]run.Result, kv map[string]string) {
	for k, v := range kv {
		r["/usr/bin/git config --global --get "+k] = run.Result{Stdout: v + "\n"}
	}
}

func TestGitSigning(t *testing.T) {
	replies := map[string]run.Result{}
	e, _ := env(t, "linux", map[string]string{"git": "/usr/bin/git"}, replies)
	if r := one(t, gitSetup(e)); r.State != d.Passed {
		t.Fatalf("nothing set is fine: %+v", r)
	}
	gitConfig(replies, map[string]string{"commit.gpgsign": "true", "gpg.format": "ssh", "user.signingkey": "~/.ssh/id_ed25519.pub"})
	if r := one(t, gitSetup(e)); r.Severity != d.Critical || !strings.Contains(r.Title, "which is gone") || !strings.Contains(r.Hint, "commit.gpgsign false") {
		t.Fatalf("%+v", r)
	}
	write(t, e.Path(".ssh", "id_ed25519.pub"), "ssh-ed25519 AAAA alex@example.com\n", 0o644)
	if r := one(t, gitSetup(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	gitConfig(replies, map[string]string{"user.signingkey": "/nowhere/key.pub", "gpg.ssh.program": "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"})
	if r := one(t, gitSetup(e)); r.State != d.Passed {
		t.Fatalf("a signing program holds its own key: %+v", r)
	}
	delete(replies, "/usr/bin/git config --global --get gpg.ssh.program")
	gitConfig(replies, map[string]string{"gpg.format": "openpgp", "user.signingkey": "ABCDEF0123456789"})
	if r := one(t, gitSetup(e)); r.Severity != d.Critical || !strings.Contains(r.Title, "gpg is not installed") {
		t.Fatalf("%+v", r)
	}
}

func TestGitCredentialsInPlainText(t *testing.T) {
	replies := map[string]run.Result{}
	e, _ := env(t, "linux", map[string]string{"git": "/usr/bin/git"}, replies)
	gitConfig(replies, map[string]string{"credential.helper": "store"})
	write(t, e.Path(".git-credentials"), "https://alex:token@example.com\n", 0o644)
	r := one(t, gitSetup(e))
	if r.Severity != d.Critical || r.Fix == nil || r.Fix.Mode != 0o600 || strings.Contains(r.Title+r.Hint, "token@") {
		t.Fatalf("%+v", r)
	}
	write(t, e.Path(".git-credentials"), "https://alex:token@example.com\n", 0o600)
	if r := one(t, gitSetup(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}
