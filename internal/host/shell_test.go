package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPasswdShell(t *testing.T) {
	f := filepath.Join(t.TempDir(), "passwd")
	os.WriteFile(f, []byte("root:x:0:0:root:/root:/bin/bash\nalex:x:1000:1000:Alex,,,:/home/alex:/usr/bin/zsh\nsvc:x:998:998::/srv:/usr/sbin/nologin\nbad:x:997:997::/x:sh\n"), 0o644)
	for uid, want := range map[int]string{1000: "/usr/bin/zsh", 0: "/bin/bash", 998: "", 997: "", 42: ""} {
		if got := passwdShell(f, uid); got != want {
			t.Errorf("uid %d: got %q, want %q", uid, got, want)
		}
	}
	if got := passwdShell(filepath.Join(t.TempDir(), "none"), 1000); got != "" {
		t.Errorf("a missing file gave %q", got)
	}
}

func TestPasswdHome(t *testing.T) {
	f := filepath.Join(t.TempDir(), "passwd")
	os.WriteFile(f, []byte("alex:x:1000:1000:Alex:/home/alex:/bin/bash\nodd:x:1001:1001::relative:/bin/sh\n"), 0o644)
	if got := passwdField(f, 1000, 5); got != "/home/alex" {
		t.Errorf("got %q", got)
	}
	if got := passwdField(f, 1001, 5); got != "" {
		t.Errorf("a relative home is no home: %q", got)
	}
}
