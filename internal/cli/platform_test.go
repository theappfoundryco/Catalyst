package cli

import (
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
)

func TestSmartmontoolsInstallsWithThisDistributionsTool(t *testing.T) {
	a, _ := testApp(t, "linux")
	a.E.SetPlatform(host.Platform{OS: "linux", ID: "opensuse-leap", Family: "suse", Managers: []string{"zypper"}})
	if cmd, _ := a.smartInstall(); strings.Join(cmd, " ") != "zypper --non-interactive install smartmontools" {
		t.Fatalf("%v", cmd)
	}
	a.E.SetPlatform(host.Platform{OS: "linux", ID: "alpine", Pretty: "Alpine Linux v3.20", Family: "alpine", Libc: "musl", Arch: "amd64", Managers: []string{}})
	cmd, why := a.smartInstall()
	if cmd != nil || !strings.Contains(why, "Homebrew needs glibc") {
		t.Fatalf("%v %q", cmd, why)
	}
}

func TestRootCommandsSkipSudoWhenAlreadyRoot(t *testing.T) {
	a, _ := testApp(t, "linux")
	a.E.SetPlatform(host.Platform{OS: "linux", Root: true})
	if got := a.rootCmd([]string{"apk", "add", "x"}); strings.Join(got, " ") != "apk add x" {
		t.Fatal(got)
	}
	a.E.SetPlatform(host.Platform{OS: "linux", Sudo: true})
	if got := a.rootCmd([]string{"apk", "add", "x"}); got[0] != "sudo" {
		t.Fatal(got)
	}
}

func TestFirewallGuideFollowsTheFamily(t *testing.T) {
	a, _ := testApp(t, "linux")
	a.E.Look = func(string) (string, error) { return "", errNo }
	a.E.SetPlatform(host.Platform{OS: "linux", Family: "fedora", Sudo: true, Managers: []string{"dnf"}})
	c, steps := a.firewallSteps()
	if c != "sudo dnf install -y firewalld" || !strings.Contains(steps[0], "firewalld") {
		t.Fatalf("%q %v", c, steps)
	}
}

var errNo = &notFound{}

type notFound struct{}

func (*notFound) Error() string { return "not found" }
