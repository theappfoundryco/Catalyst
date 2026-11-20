package checks

import (
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// xcrun's answer when Xcode is installed and its licence is not agreed to.
const xcrunLicence = "You have not agreed to the Xcode license agreements. You must agree to both license agreements below in order to use Xcode.\n"

func TestXcodeAfterAnUpdate(t *testing.T) {
	replies := map[string]run.Result{"xcode-select -p": {Stdout: "/Applications/Xcode-beta.app/Contents/Developer\n"}}
	e, _ := env(t, "darwin", nil, replies)
	e.SetCLT(true)
	none := func(string) bool { return false }
	all := func(string) bool { return true }
	if r := one(t, xcodeState(e, none)); r.Severity != d.Critical || r.Fix.Preview() != "sudo xcode-select --reset" {
		t.Fatalf("%+v", r)
	}
	replies["xcrun --find clang"] = run.Result{Code: 69, Stderr: xcrunLicence}
	if r := one(t, xcodeState(e, all)); r.Severity != d.Critical || r.Fix.Preview() != "sudo xcodebuild -license" {
		t.Fatalf("%+v", r)
	}
	replies["xcrun --find clang"] = run.Result{Stdout: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang\n"}
	if r := one(t, xcodeState(e, all)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	replies["xcode-select -p"] = run.Result{Stdout: "/Library/Developer/CommandLineTools\n"}
	delete(replies, "xcrun --find clang")
	if r := one(t, xcodeState(e, all)); r.State != d.Passed {
		t.Fatalf("Command Line Tools alone never run xcrun: %+v", r)
	}
	for _, c := range e.Run.(*run.Fake).Calls[len(e.Run.(*run.Fake).Calls)-1:] {
		if c == "xcrun --find clang" {
			t.Fatal("ran xcrun without Xcode")
		}
	}
}
