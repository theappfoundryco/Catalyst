package doctor

import (
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestScoreDecays(t *testing.T) {
	if s := Score(nil); s != 100 {
		t.Fatal(s)
	}
	if s := Score([]Result{Pass("x"), Skip("y"), Err("z")}); s != 100 {
		t.Fatalf("skipped and failed say nothing about health: %d", s)
	}
	if s := Score([]Result{Crit("a")}); s != 70 {
		t.Fatal(s)
	}
	if s := Score([]Result{Warn("a"), Note("b")}); s != 88 {
		t.Fatal(s)
	}
	var many []Result
	for i := 0; i < 8; i++ {
		many = append(many, Crit("x"))
	}
	if a, b := Score(many), Score(many[:5]); a == 0 || a >= b {
		t.Fatalf("a worse machine must read worse and stay above zero: %d %d", a, b)
	}
}

func TestACrashIsNeverAPass(t *testing.T) {
	e := host.ForTest(t.TempDir(), "linux", &run.Fake{})
	checks := []Check{{ID: "a", Name: "Boom", Group: GroupTools, Run: func(*host.Env) []Result { panic("bad parse") }}}
	r := Start(e, checks, nil)
	rs := r.Wait(0)
	if len(rs) != 1 || rs[0].State != Failed || rs[0].Check != "a" {
		t.Fatalf("%+v", rs)
	}
	c := Count(rs)
	if c.Fine != 0 || c.Failed != 1 {
		t.Fatalf("%+v", c)
	}
}

func TestOSFilterAndOnly(t *testing.T) {
	e := host.ForTest(t.TempDir(), "linux", &run.Fake{})
	ok := func(*host.Env) []Result { return []Result{Pass("x")} }
	checks := []Check{
		{ID: "tools.a", Group: GroupTools, Run: ok},
		{ID: "keys.b", Group: GroupKeys, Run: ok},
		{ID: "mac.c", Group: GroupMachine, OS: "darwin", Run: ok},
	}
	if r := Start(e, checks, nil); len(r.Checks) != 2 {
		t.Fatalf("%d checks", len(r.Checks))
	}
	if r := Start(e, checks, []string{"keys"}); len(r.Checks) != 1 || r.Checks[0].ID != "keys.b" {
		t.Fatalf("%+v", r.Checks)
	}
}

func TestFixPreview(t *testing.T) {
	r := Warn("x").Chmod("/home/alex/.ssh", 0o700)
	if got := r.Fix.Preview(); got != "chmod 700 /home/alex/.ssh" {
		t.Fatal(got)
	}
	r = Note("x").Run("docker", "image", "prune", "-f")
	if got := r.Fix.Preview(); got != "docker image prune -f" {
		t.Fatal(got)
	}
}
