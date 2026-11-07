package run

import (
	"testing"
	"time"
)

func TestRealRun(t *testing.T) {
	r := Real{}.Run(0, "sh", "-c", "echo hi; exit 3")
	if r.Text() != "hi" || r.Code != 3 || r.OK() {
		t.Fatalf("%+v", r)
	}
}

func TestNotFound(t *testing.T) {
	r := Real{}.Run(0, "catalyst-no-such-program")
	if !r.NotFound || r.OK() {
		t.Fatalf("%+v", r)
	}
}

func TestAHiddenPromptFailsInsteadOfWaiting(t *testing.T) {
	start := time.Now()
	r := Real{}.Run(5*time.Second, "sh", "-c", "read x; echo got:$x")
	if time.Since(start) > 2*time.Second || r.TimedOut {
		t.Fatalf("waited: %+v", r)
	}
}

func TestTimeLimitStopsTheWholeGroup(t *testing.T) {
	start := time.Now()
	r := Real{}.Run(200*time.Millisecond, "sh", "-c", "sleep 30 & sleep 30")
	if !r.TimedOut || time.Since(start) > 5*time.Second {
		t.Fatalf("%+v after %v", r, time.Since(start))
	}
}

func TestAChildHoldingThePipeCannotHangUs(t *testing.T) {
	start := time.Now()
	r := Real{}.Run(20*time.Second, "sh", "-c", "(sleep 30 &) ; echo done")
	if time.Since(start) > 5*time.Second {
		t.Fatalf("hung for %v", time.Since(start))
	}
	if r.Text() != "done" {
		t.Fatalf("%+v", r)
	}
}

func TestFixedLocale(t *testing.T) {
	r := Real{}.Run(0, "sh", "-c", "echo $LC_ALL")
	if r.Text() != "C" {
		t.Fatalf("%q", r.Text())
	}
}

func TestAProgramAskingForAPasswordCannotReachTheTerminal(t *testing.T) {
	// With a controlling terminal, this would open /dev/tty and sit waiting. Without one it fails at once.
	start := time.Now()
	r := Real{}.Run(5*time.Second, "sh", "-c", "exec < /dev/tty")
	if r.OK() || time.Since(start) > 2*time.Second {
		t.Fatalf("%+v after %v", r, time.Since(start))
	}
}
