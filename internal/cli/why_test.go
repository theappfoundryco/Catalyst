package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWhyListsEveryCopyInPathOrder(t *testing.T) {
	a, b := testApp(t, "linux")
	mk := func(dir string) string {
		d := filepath.Join(a.E.Home, dir)
		os.MkdirAll(d, 0o755)
		os.WriteFile(filepath.Join(d, "mytool"), []byte("#!/bin/sh\necho hi\n"), 0o755)
		return d
	}
	first, second := mk(".volta/bin"), mk("other/bin")
	linked := filepath.Join(a.E.Home, "linked")
	os.Symlink(second, linked) // the same folder twice, as /bin and /usr/bin are on most systems
	put(t, filepath.Join(a.E.Home, ".bashrc"), "export PATH=\""+second+":$PATH\"\n")
	a.E.Shell = ""
	a.E.Entries = []string{first, second, linked}
	if code := cmdWhy(a, []string{"--json", "mytool"}); code != ExitOK {
		t.Fatal(code)
	}
	var rep whyReport
	if err := json.Unmarshal(b.Bytes(), &rep); err != nil {
		t.Fatal(err)
	}
	if len(rep.Copies) != 2 {
		t.Fatalf("a folder reached twice counts once: %+v", rep.Copies)
	}
	c0, c1 := rep.Copies[0], rep.Copies[1]
	if c0.Shadowed || !c1.Shadowed || c0.Manager != "volta" || c0.Kind != "script (sh)" || c1.Line != 1 || !strings.HasSuffix(c1.AddedBy, ".bashrc") {
		t.Fatalf("%+v %+v", c0, c1)
	}
	if c0.Runs != nil {
		t.Fatal("an unknown program is never run")
	}
}

func TestWhyRefusesAPath(t *testing.T) {
	a, _ := testApp(t, "linux")
	if code := cmdWhy(a, []string{"/usr/bin/env"}); code != ExitUsage {
		t.Fatal(code)
	}
}
