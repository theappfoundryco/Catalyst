package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Recorded from pip 23 on Debian 12 after pip config set global.break-system-packages true, and with the variable set.
func TestBreakSystemKeys(t *testing.T) {
	got := BreakSystemKeys(":env:.break-system-packages='1'\nglobal.break-system-packages='true'\nglobal.index-url='https://example.com/simple'\nuser.break-system-packages='false'\n")
	if strings.Join(got, ",") != ":env:.break-system-packages,global.break-system-packages" {
		t.Fatal(got)
	}
}

func TestPipSystem(t *testing.T) {
	ask := "/usr/bin/python3 -c import os, sysconfig; print(os.path.exists(os.path.join(sysconfig.get_path('stdlib'), 'EXTERNALLY-MANAGED')))"
	replies := map[string]run.Result{
		ask:                                   {Stdout: "True\n"},
		"/usr/bin/python3 -m pip config list": {Stdout: "global.break-system-packages='true'\n"},
	}
	e, _ := env(t, "linux", map[string]string{"python3": "/usr/bin/python3"}, replies)
	r := one(t, pipSystem(e))
	if r.Severity != d.Warning || r.Fix == nil || r.Fix.Preview() != "/usr/bin/python3 -m pip config unset global.break-system-packages" {
		t.Fatalf("%+v", r)
	}
	replies["/usr/bin/python3 -m pip config list"] = run.Result{Stdout: ":env:.break-system-packages='1'\n"}
	if r := one(t, pipSystem(e)); r.Fix != nil || !strings.Contains(r.Hint, "PIP_BREAK_SYSTEM_PACKAGES") {
		t.Fatalf("%+v", r)
	}
	replies["/usr/bin/python3 -m pip config list"] = run.Result{Stdout: ""}
	if r := one(t, pipSystem(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	replies[ask] = run.Result{Stdout: "False\n"}
	if r := one(t, pipSystem(e)); r.State != d.Skipped {
		t.Fatalf("a Python of your own may take anything: %+v", r)
	}
}
