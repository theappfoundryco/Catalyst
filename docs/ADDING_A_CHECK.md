# Adding a check

A check is one small file in `internal/doctor/checks` and a test. It takes about fifteen minutes.

## A good check

It catches something that wastes real time and that people do not think to look for. It should be cheap to run, right on every machine, and say what to do in plain words. If a check might be wrong on some setups, it should stay quiet or read as a note rather than a warning, because one false alarm costs more trust than one miss.

## The file

```go
package checks

import (
	"os"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "keys.aws", Group: d.GroupKeys, Name: "Checking your AWS credentials", Run: awsCreds})
}

func awsCreds(e *host.Env) []d.Result {
	p := e.Path(".aws", "credentials")
	st, err := os.Stat(p)
	if err != nil {
		return []d.Result{d.Skip("No AWS credentials here")}
	}
	if st.Mode().Perm()&0o077 != 0 {
		return []d.Result{d.Warn("~/.aws/credentials can be read by other users").Chmod(p, 0o600)}
	}
	return []d.Result{d.Pass("Your AWS credentials are private")}
}
```

## What goes in it

| Field | Meaning |
|---|---|
| `ID` | `group.name`, used by `catalyst doctor --only` |
| `Group` | `GroupShell`, `GroupTools`, `GroupKeys` or `GroupMachine` |
| `Name` | What the spinner says while it runs |
| `OS` | `"darwin"` or `"linux"` to limit it, empty for both |

Results: `d.Pass`, `d.Note` (worth knowing), `d.Warn` (worth fixing), `d.Crit` (fix this), `d.Skip` (does not apply, say why) and `d.Err` (could not tell). `.With("...")` adds a line of advice.

Fixes: `.Chmod(path, mode)` and `.Trash(path)` can be undone. `.Run("docker", "image", "prune", "-f")` cannot, and is shown first. `.Manual("sudo", "...")` prints the command for the person.

## Rules that keep it trustworthy

- Run programs through `e.Run` or `e.Out`, never directly, so tests can answer for them.
- Use `e.SafeTool("git")` for anything Apple ships as a stub. Running a stub on a Mac with no Command Line Tools opens an install dialog.
- Use `e.Path` for anything in the home folder, and `e.Entries` for the PATH a new terminal gets. Do not read `os.Getenv("PATH")`.
- Never put the value of a secret in a result. Counts only.
- No network. No writing. A check only reads.

## The test

Add it to `checks_test.go`, using the output of the real tool with personal values taken out. This is how a Linux contributor can test macOS parsing.

```go
func TestAWSCredentials(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	if r := one(t, awsCreds(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	write(t, e.Path(".aws", "credentials"), "[default]\n", 0o644)
	r := one(t, awsCreds(e))
	if r.Severity != d.Warning || r.Fix.Mode != 0o600 {
		t.Fatalf("%+v", r)
	}
}
```

Then `make check` and `make test`, and open a pull request.

## Adding a sweep rule

One line in the `Rules` table in `internal/sweep/sweep.go`:

```go
{Dir: "target", Needs: []string{"Cargo.toml"}, Title: "Rust build output", Restore: "cargo build", Cost: Rebuild},
```

`Needs` is what must sit beside the folder to prove what it is. `Inside` is the same for a file within it. `Cost` is `Safe` if it rebuilds by itself or `Rebuild` if it needs a command. Set `NeedsGit: true` for a name too common to trust alone, like `build`. Then add a case to `sweep_test.go`, including one where it must not be offered.
