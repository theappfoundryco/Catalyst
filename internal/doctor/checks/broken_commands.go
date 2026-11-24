package checks

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "tools.broken", Group: d.GroupTools, Name: "Checking that the commands on your PATH can start", Run: brokenCommands})
}

// The system's own folders are kept whole by its updates, so only the folders people and their tools install into are
// read. A dead link in /usr/bin is the package manager's to sort out, and would only be noise here.
var (
	systemBins     = []string{"/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/games", "/usr/local/games", "/snap/bin", "/usr/libexec"}
	systemPrefixes = []string{"/System/", "/Library/Apple/", "/Applications/Xcode", "/Library/Developer/CommandLineTools/", "/var/run/com.apple.", "/nix/", "/run/current-system/", "/etc/profiles/"}
)

// CommandFolders is where commands are looked for: the PATH a new terminal gets. The demo points it at its invented
// machine, since this check reads files rather than asking a program.
var CommandFolders = func(e *host.Env) []string { return e.Entries }

// A folder rarely holds more than a few hundred commands. The cap keeps a PATH that includes a huge folder by mistake
// from making the checkup slow.
const brokenBudget = 6000

// A program that is still on the PATH but can no longer start: a pip tool whose Python was upgraded away, a binary
// linked to a Homebrew library that was removed, an Intel-only tool on a Mac without Rosetta. It only reads file
// headers, never runs anything, and reports the copy that actually runs, the first one on the PATH.
func brokenCommands(e *host.Env) []d.Result {
	m := MachineOf(e)
	seen := map[string]bool{}
	type broken struct{ name, path, why string }
	var bad []broken
	var intel []string
	dead := map[string]string{} // a link to nothing: the shell skips it, so it matters only if nothing later has the name
	checked := 0
	for _, dir := range CommandFolders(e) {
		if !filepath.IsAbs(dir) || isSystemBin(dir) {
			continue
		}
		items, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, it := range items {
			name := it.Name()
			if seen[name] || strings.HasPrefix(name, ".") {
				continue
			}
			p := filepath.Join(dir, name)
			st, err := os.Stat(p)
			if err != nil && it.Type()&os.ModeSymlink != 0 {
				if _, ok := dead[name]; !ok {
					dead[name] = p
				}
				continue
			}
			if err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
				continue // not a command, so it does not hide a later one either
			}
			seen[name] = true
			if checked++; checked > brokenBudget {
				break
			}
			why, isIntel := host.Broken(p, m)
			why = strings.ReplaceAll(why, e.Home+"/", "~/") // paths are said the way the rest of Catalyst says them
			if why != "" {
				bad = append(bad, broken{name, p, why})
			} else if isIntel {
				intel = append(intel, name)
			}
		}
	}
	for name, p := range dead {
		if !seen[name] {
			why, _ := host.Broken(p, m)
			bad = append(bad, broken{name, p, strings.ReplaceAll(why, e.Home+"/", "~/")})
		}
	}
	sort.Slice(bad, func(i, j int) bool { return bad[i].name < bad[j].name })
	var out []d.Result
	const shown = 3
	for i, b := range bad {
		if i == shown {
			rest := make([]string, 0, len(bad)-shown)
			for _, x := range bad[shown:] {
				rest = append(rest, x.name+": "+e.Tilde(x.path)+", "+x.why)
			}
			out = append(out, d.Warn(ui.Count(len(rest), "more command on your PATH cannot start", "more commands on your PATH cannot start")).
				With("Reinstall each with the tool that installed it, or remove it if you no longer use it.").
				List(rest...).See("catalyst why NAME, for any one of them"))
			break
		}
		out = append(out, d.Warn(b.name+" is on your PATH but cannot start").
			With(e.Tilde(b.path)+": "+b.why+". Reinstall it with the tool that installed it, or remove it if you no longer use it."))
	}
	if len(intel) > 0 {
		out = append(out, d.Note(ui.Count(len(intel), "command is", "commands are")+" built only for Intel, and run through Rosetta").
			With("Apple has said Rosetta stays fully available only through macOS 27, so look for Apple silicon versions.").
			List(intel...).See("file $(command -v NAME), which says x86_64 for these"))
	}
	if len(out) == 0 {
		if checked == 0 {
			return []d.Result{d.Skip("No commands outside the system's own folders")}
		}
		return []d.Result{d.Pass("All " + ui.Count(checked, "command", "commands") + " in your own PATH folders can start")}
	}
	return out
}

func isSystemBin(dir string) bool {
	clean := filepath.Clean(dir)
	for _, s := range systemBins {
		if clean == s {
			return true
		}
	}
	for _, s := range systemPrefixes {
		if strings.HasPrefix(clean+"/", s) {
			return true
		}
	}
	return false
}

// MachineOf is what a program on this machine needs in order to start, for host.Broken. why uses it too.
func MachineOf(e *host.Env) host.Machine {
	return host.Machine{
		OS: e.OS, Arch: e.Platform().Arch,
		Exists: host.Exists,
		OnPath: func(name string) bool {
			for _, dir := range e.Entries {
				if st, err := os.Stat(filepath.Join(dir, name)); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
					return true
				}
			}
			return false
		},
		Rosetta:  e.OS == "darwin" && host.Exists("/Library/Apple/usr/share/rosetta/rosetta"),
		Emulates: linuxEmulates,
	}
}

// linuxEmulates is whether binfmt_misc hands programs for arch to an emulator such as qemu.
func linuxEmulates(arch string) bool {
	name := map[string]string{"arm64": "aarch64", "amd64": "x86_64", "arm": "arm", "riscv64": "riscv64", "386": "i386"}[arch]
	return name != "" && host.Exists("/proc/sys/fs/binfmt_misc/qemu-"+name)
}
