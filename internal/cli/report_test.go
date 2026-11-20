package cli

import (
	"os/user"
	"strings"
	"testing"
)

func TestScrubTakesOutHomeHostAndUser(t *testing.T) {
	a, _ := testApp(t, "linux")
	u, err := user.Current()
	if err != nil || u.Username == "root" || len(u.Username) <= 2 {
		t.Skip("needs a named user that is not root") // a container user with no passwd entry has no name to take out
	}
	name := u.Username
	in := a.E.Home + "/.bashrc on alex-laptop.local, owned by " + name + "; keep " + name + "ville and my_" + name + "_x"
	got := a.Scrub(in)
	if strings.Contains(got, a.E.Home) || strings.Contains(got, "alex-laptop") || !strings.HasPrefix(got, "~/.bashrc on this-machine") {
		t.Fatal(got)
	}
	if !strings.Contains(got, "owned by you;") || !strings.Contains(got, name+"ville") {
		t.Fatalf("a user name is replaced only where it stands alone: %s", got)
	}
}

func TestReportIsMarkdownWithNoHome(t *testing.T) {
	a, b := testApp(t, "linux")
	a.E.Shell = ""
	a.E.Entries = []string{a.E.Home + "/.local/bin", "/usr/bin"}
	if code := cmdReport(a, nil); code != ExitOK {
		t.Fatal(code)
	}
	out := b.String()
	for _, want := range []string{"# Catalyst report", "## This machine", "## Doctor", "1. `~/.local/bin`"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(out, a.E.Home) {
		t.Fatal("home folder left in the report")
	}
}

func TestScrubLeavesRootAlone(t *testing.T) {
	a, _ := testApp(t, "linux")
	if got := a.Scrub("npm's global folder belongs to root"); got != "npm's global folder belongs to root" {
		t.Fatal(got)
	}
}
