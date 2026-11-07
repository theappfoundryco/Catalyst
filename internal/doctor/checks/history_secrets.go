package checks

import (
	"bufio"
	"os"
	"regexp"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "keys.history", Group: d.GroupKeys, Name: "Reading your shell history for leaked keys", Run: historySecrets})
}

// Secret shapes with a recognisable prefix, so an ordinary long word is not reported. Only line counts ever leave this function.
var secretShapes = []*regexp.Regexp{
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),                   // AWS
	regexp.MustCompile(`\bsk_live_[0-9a-zA-Z]{24,}`),         // Stripe
	regexp.MustCompile(`\bgh[pousr]_[0-9A-Za-z]{36,}`),       // GitHub
	regexp.MustCompile(`\bgithub_pat_[0-9A-Za-z_]{22,}`),     // GitHub fine-grained
	regexp.MustCompile(`\bglpat-[0-9A-Za-z_-]{20,}`),         // GitLab
	regexp.MustCompile(`\bxox[abprs]-[0-9A-Za-z-]{10,}`),     // Slack
	regexp.MustCompile(`\bsk-ant-[0-9A-Za-z_-]{20,}`),        // Anthropic
	regexp.MustCompile(`\bsk-(?:proj-)?[0-9A-Za-z_-]{32,}`),  // OpenAI
	regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}`),            // Google
	regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`), // a private key pasted in
}

// CountSecretLines counts lines in the text that hold a secret.
func CountSecretLines(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if len(line) < 16 {
			continue
		}
		for _, re := range secretShapes {
			if re.MatchString(line) {
				n++
				break
			}
		}
	}
	return n
}

func historySecrets(e *host.Env) []d.Result {
	files := []string{e.Path(".zsh_history"), e.Path(".bash_history"), e.Path(".local", "share", "fish", "fish_history")}
	seen, total := 0, 0
	var where []string
	for _, f := range files {
		if !host.Exists(f) {
			continue
		}
		seen++
		if n := CountSecretLines(f); n > 0 {
			total += n
			where = append(where, e.Tilde(f))
		}
	}
	if seen == 0 {
		return []d.Result{d.Skip("No shell history here")}
	}
	if total > 0 {
		return []d.Result{d.Crit(ui.Count(total, "line in your shell history looks", "lines in your shell history look") + " like an API key or private key").
			With("In " + strings.Join(where, ", ") + ". Values are not shown. Replace those keys, then remove the lines.")}
	}
	return []d.Result{d.Pass("No API keys in your shell history")}
}
