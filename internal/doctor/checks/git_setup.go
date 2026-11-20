package checks

import (
	"fmt"
	"os"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.gitsetup", Group: d.GroupTools, Name: "Checking git signing and credentials", Run: gitSetup})
}

// Two git settings fail in ways that do not point at themselves. Signing turned on with a key that is gone makes every
// commit fail with "gpg failed to sign the data" or "error: Load key". And credential.helper=store keeps tokens in plain
// text in ~/.git-credentials, which is fine only while no one else can read that file.
func gitSetup(e *host.Env) []d.Result {
	git, ok := e.SafeTool("git")
	if !ok {
		return []d.Result{d.Skip("git is not installed")}
	}
	get := func(k string) string {
		v, _ := e.Out(git, "config", "--global", "--get", k)
		return strings.TrimSpace(v)
	}
	var out []d.Result
	if strings.EqualFold(get("commit.gpgsign"), "true") {
		if r, bad := signingProblem(e, get("gpg.format"), get("user.signingkey"), get("gpg.ssh.program"), get("gpg.program")); bad {
			out = append(out, r)
		}
	}
	if strings.Contains(get("credential.helper"), "store") {
		p := e.Path(".git-credentials")
		if st, err := os.Stat(p); err == nil && st.Mode().Perm()&0o077 != 0 {
			out = append(out, d.Crit(fmt.Sprintf("~/.git-credentials holds your git tokens in plain text, and other users can read it (%o)", st.Mode().Perm())).
				With("Replace any token that may have been seen. A keychain helper keeps them safer: osxkeychain on a Mac, libsecret or Git Credential Manager on Linux.").
				Chmod(p, 0o600))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("git signing and credentials are set up cleanly")}
	}
	return out
}

// signingProblem says whether commits that must be signed can be.
func signingProblem(e *host.Env, format, key, sshProgram, gpgProgram string) (d.Result, bool) {
	fail := func(title, hint string) (d.Result, bool) {
		return d.Crit(title).With(hint + " Or stop signing: git config --global commit.gpgsign false"), true
	}
	switch strings.ToLower(format) {
	case "ssh":
		if sshProgram != "" { // 1Password, Secretive and others sign through their own program, with the key inside
			return d.Result{}, false
		}
		if key == "" {
			return fail("git signs every commit with SSH, but no signing key is set, so commits fail", "Set one: git config --global user.signingkey ~/.ssh/id_ed25519.pub.")
		}
		if strings.HasPrefix(key, "key::") || strings.HasPrefix(key, "ssh-") {
			return d.Result{}, false // the key itself, written inline
		}
		p := key
		if strings.HasPrefix(p, "~/") {
			p = e.Path(p[2:])
		}
		if !host.Exists(p) {
			return fail("git signs every commit with "+key+", which is gone, so commits fail", "Point user.signingkey at a key you have.")
		}
	case "", "openpgp":
		prog := gpgProgram
		if prog == "" {
			prog = "gpg"
		}
		if _, err := e.Look(prog); err != nil {
			return fail("git signs every commit with GPG, but "+prog+" is not installed, so commits fail", "Install GnuPG, or sign with SSH instead.")
		}
		if key != "" {
			if r := e.Run.Run(0, prog, "--list-secret-keys", key); !r.OK() {
				return fail("git signs every commit with a GPG key this machine does not have, so commits fail", "Import that key, or point user.signingkey at one you have: gpg --list-secret-keys.")
			}
		}
	}
	return d.Result{}, false
}
