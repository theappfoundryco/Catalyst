package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/doctor"
)

func TestAllSafeFixesAreAskedOnceAndUndoneTogether(t *testing.T) {
	a, b := testApp(t, "linux")
	a.U.Yes = true
	k1, k2 := filepath.Join(a.E.Home, ".ssh", "id_a"), filepath.Join(a.E.Home, ".ssh", "id_b")
	os.MkdirAll(filepath.Dir(k1), 0o700)
	for _, k := range []string{k1, k2} {
		os.WriteFile(k, []byte("key"), 0o644)
		os.Chmod(k, 0o644)
	}
	all := []doctor.Result{
		doctor.Crit("key a").Chmod(k1, 0o600),
		doctor.Crit("key b").Chmod(k2, 0o600),
		doctor.Note("stopped containers").Run("true"),
		doctor.Note("only you").Manual("sudo", "something"),
		doctor.Crit("muted key").Chmod(k1, 0o600),
	}
	all[4].Muted = true
	a.applyFixes(all, true)
	out := b.String()
	head, rest, _ := strings.Cut(out, "  Fixes\n")
	if !strings.Contains(head, "Fixes that can be undone") || strings.Count(head, "chmod 600") != 2 || strings.Count(head, "Done") != 1 || strings.Contains(rest, "chmod") {
		t.Fatalf("both shown together, done once, and not offered again:\n%s", out)
	}
	for _, k := range []string{k1, k2} {
		if st, _ := os.Stat(k); st.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %o", k, st.Mode().Perm())
		}
	}
	if !strings.Contains(out, "Only you can do this one: sudo something") || strings.Contains(out, "muted key") {
		t.Fatalf("%s", out)
	}
	if last := a.Journal.LastUndoable(); len(last) != 2 {
		t.Fatalf("both in one batch, so one undo reverses both: %d", len(last))
	}
}
