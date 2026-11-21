package cli

import (
	"io"
	"os"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/explain"
	"github.com/theappfoundryco/catalyst/internal/session"
)

// explainLimit is how much of a pasted or piped log is read. The cause is nearly always near the top.
const explainLimit = 1 << 20

// cmdExplain says what an error message means. The text can come as arguments, through a pipe, or pasted when asked.
// Catalyst never prints it back, since an error can hold a token or a path someone would rather not share.
func cmdExplain(a *App, args []string) int {
	fs := a.flags("explain", "[ERROR TEXT] [--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	text := strings.Join(fs.Args(), " ")
	if text == "" && !u.InTTY {
		b, _ := io.ReadAll(io.LimitReader(os.Stdin, explainLimit))
		text = string(b)
	}
	if text == "" && u.InTTY && !*asJSON {
		if !a.inSession {
			u.Blank()
		}
		text = u.Text("Paste the error, then press Enter: ")
	}
	if strings.TrimSpace(text) == "" {
		u.Stop("There is no error to explain.")
		u.Hint("catalyst explain \"the message\", or pipe it in: npm install 2>&1 | catalyst explain")
		return ExitUsage
	}
	found := explain.Find(text)
	if *asJSON {
		if found == nil {
			found = []explain.Match{}
		}
		emit(a, struct {
			Matches []explain.Match `json:"matches"`
		}{found})
		if len(found) == 0 {
			return ExitIssues
		}
		return ExitOK
	}
	u.Hdr("What this error means")
	if len(found) == 0 {
		u.Note("Catalyst does not know this message.")
		u.Hint("It only explains errors it knows exactly, so it never guesses. To look over the whole machine: catalyst doctor")
		u.Blank()
		return ExitIssues
	}
	for i, m := range found {
		if i > 0 {
			u.Blank()
		}
		var keys []session.Action
		if len(m.Checks) > 0 {
			keys = append(keys, goTo("c", "run the check", "Doctor", "doctor", "--only", strings.Join(m.Checks, ",")))
		}
		if m.Run != "" {
			f := strings.Fields(m.Run)
			keys = append(keys, goTo("s", "see it", strings.ToUpper(f[1][:1])+f[1][1:], f[1:]...))
		}
		u.Say("  " + a.row(keys...) + u.Bold(m.Title))
		u.Row("Why", m.Cause)
		if len(m.Checks) > 0 {
			u.Row("Check", "catalyst doctor --only "+strings.Join(m.Checks, ","))
		}
		if m.Run != "" {
			u.Row("See", m.Run)
		}
		u.Row("Fix", m.Fix)
	}
	u.Blank()
	return ExitOK
}
