package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	_ "github.com/theappfoundryco/catalyst/internal/doctor/checks" // registers the checks, so their IDs are known
)

func TestMutingACheckTakesItOutOfTheScoreOnly(t *testing.T) {
	rs := []doctor.Result{
		{Check: "tools.git", State: doctor.Issue, Severity: doctor.Warning},
		{Check: "keys.firewall", State: doctor.Issue, Severity: doctor.Info},
		{Check: "tools.node", State: doctor.Passed},
	}
	before := doctor.Score(rs)
	doctor.Mute(rs, func(c string) bool { return c == "tools.git" || c == "tools.node" })
	if !rs[0].Muted || rs[2].Muted {
		t.Fatalf("only issues are muted: %+v", rs)
	}
	c := doctor.Count(rs)
	if c.Muted != 1 || c.Warning != 0 || c.Info != 1 || c.Fine != 1 || doctor.Score(rs) <= before {
		t.Fatalf("%+v score %d", c, doctor.Score(rs))
	}
}

func TestMuteAndUnmuteAreSaved(t *testing.T) {
	a, b := testApp(t, "linux")
	if code := cmdDoctor(a, []string{"--mute", "no.such"}); code != ExitUsage {
		t.Fatal("an unknown check is refused")
	}
	if code := cmdDoctor(a, []string{"--mute", "keys.firewall"}); code != ExitOK || !a.Store.LoadConfig().IsMuted("keys.firewall") {
		t.Fatal(b.String())
	}
	cmdDoctor(a, []string{"--mute", "keys.firewall"})
	if n := len(a.Store.LoadConfig().Muted); n != 1 {
		t.Fatalf("muting twice keeps one: %d", n)
	}
	b.Reset()
	a.E.Shell = ""
	cmdDoctor(a, []string{"--json", "--only", "keys.firewall"})
	var rep doctorReport
	json.Unmarshal(b.Bytes(), &rep)
	for _, r := range rep.Results {
		if r.State == doctor.Issue && !r.Muted {
			t.Fatalf("%+v", r)
		}
	}
	cmdDoctor(a, []string{"--unmute", "keys.firewall"})
	if a.Store.LoadConfig().IsMuted("keys.firewall") || strings.Contains(b.String(), "panic") {
		t.Fatal("unmute")
	}
}
