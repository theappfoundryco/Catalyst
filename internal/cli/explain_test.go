package cli

import (
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/explain"
)

func TestExplainSaysCauseCheckAndFix(t *testing.T) {
	a, out := testApp(t, "linux")
	code := a.dispatch([]string{"explain", "Error: listen EADDRINUSE: address already in use :::3000 note=do-not-echo-me"})
	got := out.String()
	if code != ExitOK || !strings.Contains(got, "Something is already listening on that port") || !strings.Contains(got, "catalyst ports") {
		t.Fatalf("%d\n%s", code, got)
	}
	if strings.Contains(got, "do-not-echo-me") || strings.Contains(got, ":::3000") {
		t.Fatalf("the pasted text is never printed back:\n%s", got)
	}
	a, out = testApp(t, "linux")
	if code := a.dispatch([]string{"explain", "Segmentation fault"}); code != ExitIssues || !strings.Contains(out.String(), "does not know this message") {
		t.Fatalf("%d\n%s", code, out.String())
	}
	a, out = testApp(t, "linux")
	if code := a.dispatch([]string{"explain", "--json", "zsh: command not found: nvm"}); code != ExitOK || !strings.Contains(out.String(), `"run": "catalyst why nvm"`) {
		t.Fatalf("%d\n%s", code, out.String())
	}
}

func TestExplainPointsOnlyAtChecksThatExist(t *testing.T) {
	ids := map[string]bool{}
	for _, c := range doctor.All() {
		ids[c.ID] = true
	}
	for _, id := range explain.Checks() {
		if !ids[id] {
			t.Errorf("explain points at %s, which is not a check", id)
		}
	}
	names := map[string]bool{}
	for _, c := range commands() {
		names[c.Name] = true
	}
	for _, text := range []string{"Error: listen EADDRINUSE", "GLIBC_2.38' not found", "Could not resolve host: example.com", "zsh: command not found: x", "The engine \"node\" is incompatible", "No module named 'x'"} {
		for _, m := range explain.Find(text) {
			if f := strings.Fields(m.Run); len(f) > 1 && !names[f[1]] {
				t.Errorf("%s runs %q, which is not a command", m.ID, m.Run)
			}
		}
	}
}
