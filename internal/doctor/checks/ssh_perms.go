package checks

import (
	"fmt"
	"os"
	"path/filepath"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "keys.ssh", Group: d.GroupKeys, Name: "Checking your SSH keys", Run: sshPerms})
}

func sshPerms(e *host.Env) []d.Result {
	dir := e.Path(".ssh")
	st, err := os.Stat(dir)
	if err != nil {
		return []d.Result{d.Skip("No ~/.ssh on this machine")}
	}
	var out []d.Result
	if st.Mode().Perm()&0o077 != 0 {
		out = append(out, d.Warn(fmt.Sprintf("~/.ssh can be read by other users (%o)", st.Mode().Perm())).Chmod(dir, 0o700))
	}
	keys := e.PrivateKeyFiles()
	for _, k := range keys {
		ks, err := os.Stat(k)
		if err != nil {
			continue
		}
		if ks.Mode().Perm()&0o077 != 0 {
			out = append(out, d.Crit(fmt.Sprintf("Private key %s can be read by other users (%o)", filepath.Base(k), ks.Mode().Perm())).
				With("ssh also refuses to use a key like this.").Chmod(k, 0o600))
		}
	}
	for _, k := range e.SSHKeys() {
		if k.Weak {
			out = append(out, d.Warn(fmt.Sprintf("SSH key %s is weak (%d-bit %s)", k.Name, k.Bits, k.Type)).With("Make a new one: ssh-keygen -t ed25519"))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("~/.ssh and your " + ui.Count(len(keys), "key have", "keys have") + " safe permissions")}
	}
	return out
}
