package checks

import (
	"os"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
)

func TestAnEmptySSHFolderDoesNotCountZeroKeys(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	os.MkdirAll(e.Path(".ssh"), 0o700)
	if r := one(t, sshPerms(e)); r.State != d.Passed || r.Title != "~/.ssh has safe permissions, and holds no private keys" {
		t.Fatalf("%+v", r)
	}
}
