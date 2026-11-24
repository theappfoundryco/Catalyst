package checks

import (
	"bufio"
	"os"
	"regexp"
	"strconv"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "keys.history", Group: d.GroupKeys, Name: "Reading your shell history for leaked keys", Run: historySecrets})
}

// Secret shapes with a recognisable prefix, so an ordinary long word is not reported. Only where they are, and what
// kind, ever leaves this file: line numbers and names like "a GitHub token", never a value.
var secretShapes = []struct {
	kind string
	re   *regexp.Regexp
}{
	{"an AWS key", regexp.MustCompile(`AKIA[0-9A-Z]{16}`)},
	{"a Stripe key", regexp.MustCompile(`\bsk_live_[0-9a-zA-Z]{24,}`)},
	{"a GitHub token", regexp.MustCompile(`\bgh[pousr]_[0-9A-Za-z]{36,}`)},
	{"a GitHub token", regexp.MustCompile(`\bgithub_pat_[0-9A-Za-z_]{22,}`)},
	{"a GitLab token", regexp.MustCompile(`\bglpat-[0-9A-Za-z_-]{20,}`)},
	{"a Slack token", regexp.MustCompile(`\bxox[abprs]-[0-9A-Za-z-]{10,}`)},
	{"an Anthropic key", regexp.MustCompile(`\bsk-ant-[0-9A-Za-z_-]{20,}`)},
	{"an OpenAI key", regexp.MustCompile(`\bsk-(?:proj-)?[0-9A-Za-z_-]{32,}`)},
	{"a Google key", regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}`)},
	{"a private key", regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)},
}

// SecretLine is where a secret sits and what kind it looks like. It never holds the value.
type SecretLine struct {
	Line int
	Kind string
}

// SecretLines finds the lines in a file that hold a secret.
func SecretLines(path string) []SecretLine {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []SecretLine
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if len(line) < 16 {
			continue
		}
		for _, s := range secretShapes {
			if s.re.MatchString(line) {
				out = append(out, SecretLine{n, s.kind})
				break
			}
		}
	}
	return out
}

// CountSecretLines counts lines in the text that hold a secret.
func CountSecretLines(path string) int { return len(SecretLines(path)) }

func historySecrets(e *host.Env) []d.Result {
	files := []string{e.Path(".zsh_history"), e.Path(".bash_history"), e.Path(".local", "share", "fish", "fish_history")}
	seen, total := 0, 0
	var where, items []string
	for _, f := range files {
		if !host.Exists(f) {
			continue
		}
		seen++
		if found := SecretLines(f); len(found) > 0 {
			total += len(found)
			where = append(where, e.Tilde(f))
			for _, s := range found {
				items = append(items, e.Tilde(f)+", line "+strconv.Itoa(s.Line)+": looks like "+s.Kind)
			}
		}
	}
	if seen == 0 {
		return []d.Result{d.Skip("No shell history here")}
	}
	if total > 0 {
		return []d.Result{d.Crit(ui.Count(total, "line in your shell history looks", "lines in your shell history look") + " like an API key or private key").
			With("In " + strings.Join(where, ", ") + ". Values are not shown. Replace those keys, then remove the lines in a text editor. Close your other terminals first, or they can write the lines back when they exit.").
			List(items...)}
	}
	return []d.Result{d.Pass("No API keys in your shell history")}
}
