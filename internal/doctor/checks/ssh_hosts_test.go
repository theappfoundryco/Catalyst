package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

type testEnv struct{ e *host.Env }

func sshEnv(t *testing.T, agent run.Result) (*testEnv, map[string]run.Result) {
	t.Helper()
	tools := map[string]string{"ssh": "/usr/bin/ssh", "ssh-keygen": "/usr/bin/ssh-keygen", "ssh-add": "/usr/bin/ssh-add"}
	replies := map[string]run.Result{"/usr/bin/ssh-add -l": agent}
	e, _ := env(t, "darwin", tools, replies)
	return &testEnv{e}, replies
}

func sshDefaults() string {
	return "user alex\nhostname github.com\nidentitiesonly no\nidentityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ed25519\n"
}

func TestSSHHostsQuietForHTTPSPeople(t *testing.T) {
	te, _ := sshEnv(t, run.Result{Code: 1})
	if r := one(t, sshGitHosts(te.e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
}

func TestSSHHostsNoKeyToOffer(t *testing.T) {
	te, replies := sshEnv(t, run.Result{Code: 1, Stdout: "The agent has no identities.\n"})
	e := te.e
	known := e.Path(".ssh", "known_hosts")
	write(t, known, "|1|hashed|entry ssh-ed25519 AAAA\n", 0o644)
	replies["/usr/bin/ssh-keygen -F github.com -f "+known] = run.Result{Stdout: "# Host github.com found: line 1\n"}
	replies["/usr/bin/ssh -G github.com"] = run.Result{Stdout: sshDefaults()}
	replies["/usr/bin/ssh-keygen -l -F github.com -f "+known] = run.Result{Stdout: "# Host github.com found: line 1\ngithub.com ED25519 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU\n"}
	if r := one(t, sshGitHosts(e)); r.State != d.Skipped {
		t.Fatalf("known_hosts alone, with no key anywhere, is someone who does not use SSH: %+v", r)
	}
	write(t, e.Path(".ssh", "config"), "Host github.com\n  User git\n", 0o644)
	r := one(t, sshGitHosts(e))
	if r.Severity != d.Warning || !strings.Contains(r.Title, "no key to offer") || !strings.Contains(r.Hint, "ssh-keygen -t ed25519") {
		t.Fatalf("%+v", r)
	}
	replies["/usr/bin/ssh-add -l"] = run.Result{Stdout: "256 SHA256:abc alex@example.com (ED25519)\n"}
	if r := one(t, sshGitHosts(e)); r.State != d.Passed {
		t.Fatalf("a key in the agent is offered: %+v", r)
	}
	replies["/usr/bin/ssh-add -l"] = run.Result{Code: 1}
	write(t, e.Path(".ssh", "id_ed25519"), "key\n", 0o600)
	if r := one(t, sshGitHosts(e)); r.State != d.Passed {
		t.Fatalf("a default key file is offered: %+v", r)
	}
}

func TestSSHHostsConfiguredKeyIsGone(t *testing.T) {
	te, replies := sshEnv(t, run.Result{Stdout: "256 SHA256:abc other (ED25519)\n"})
	e := te.e
	write(t, e.Path(".ssh", "config"), "Host gh-work\n  HostName github.com\n  IdentityFile ~/.ssh/work\n  IdentitiesOnly yes\n\nHost *\n  AddKeysToAgent yes\n", 0o644)
	replies["/usr/bin/ssh -G gh-work"] = run.Result{Stdout: "hostname github.com\nidentitiesonly yes\nidentityfile ~/.ssh/work\n"}
	r := one(t, sshGitHosts(e))
	if !strings.Contains(r.Title, "gh-work will be refused: the key it is set to use is gone") || !strings.Contains(r.Hint, "~/.ssh/work") {
		t.Fatalf("%+v", r)
	}
	replies["/usr/bin/ssh -G gh-work"] = run.Result{Stdout: "hostname github.com\nidentityagent ~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\nidentityfile ~/.ssh/work\n"}
	if r := one(t, sshGitHosts(e)); r.State != d.Passed {
		t.Fatalf("an agent of its own cannot be asked, so nothing is said: %+v", r)
	}
}

func TestSSHHostsOldGitHubKey(t *testing.T) {
	te, replies := sshEnv(t, run.Result{Stdout: "256 SHA256:abc alex@example.com (ED25519)\n"})
	e := te.e
	known := e.Path(".ssh", "known_hosts")
	write(t, known, "github.com ssh-rsa AAAA\n", 0o644)
	replies["/usr/bin/ssh-keygen -F github.com -f "+known] = run.Result{Stdout: "# Host github.com found: line 1\n"}
	replies["/usr/bin/ssh -G github.com"] = run.Result{Stdout: sshDefaults()}
	replies["/usr/bin/ssh-keygen -l -F github.com -f "+known] = run.Result{Stdout: "# Host github.com found: line 1\ngithub.com RSA " + githubOldRSA + "\n"}
	r := one(t, sshGitHosts(e))
	if !strings.Contains(r.Title, "old RSA key") || !strings.Contains(r.Hint, "ssh-keygen -R github.com") {
		t.Fatalf("%+v", r)
	}
}
