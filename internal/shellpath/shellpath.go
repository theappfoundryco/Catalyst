// Package shellpath puts the catalyst command on the terminal's PATH: one marked line in the shell's startup file if
// ~/.local/bin is not on the PATH yet. It comes out again with RemoveLines, and only if it is ours. Check looks first and
// changes nothing, and this package never writes a file: the caller does that the careful way, with a copy kept.
//
// Every case it knows:
//
//	ready    a new terminal finds this command
//	missing  ~/.local/bin is not on the PATH and the startup file lacks our line
//	clash    something else called catalyst comes first on the PATH: never touched
package shellpath

import (
	"os"
	"path/filepath"
	"strings"
)

// The marked line. Only lines under this mark are ever removed.
const (
	Mark = "# added by catalyst, remove with: catalyst path remove"
	Line = `export PATH="$HOME/.local/bin:$PATH"`
	Fish = "fish_add_path $HOME/.local/bin"
)

// RCFile is the startup file a new terminal reads for this shell.
func RCFile(home, shell, goos, zdotdir string) string {
	switch filepath.Base(shell) {
	case "zsh":
		if zdotdir != "" {
			return filepath.Join(zdotdir, ".zshrc")
		}
		return filepath.Join(home, ".zshrc")
	case "bash":
		if goos == "darwin" {
			return filepath.Join(home, ".bash_profile")
		}
		return filepath.Join(home, ".bashrc")
	case "fish":
		return filepath.Join(home, ".config", "fish", "config.fish")
	}
	return filepath.Join(home, ".profile")
}

// Status is what Check found.
type Status struct {
	State  string // "ready", "missing" or "clash"
	RC     string
	Found  string
	BinDir string
}

func hasLine(rc string) bool {
	b, err := os.ReadFile(rc)
	return err == nil && Has(string(b))
}

// markAt is the line our mark is on: alone, or glued onto the end of another line, such as a } a tool left without a
// line break. -1 when it is not there. Has and RemoveLines both use it, so they always agree on whether the line is ours.
func markAt(lines []string) int {
	for i, l := range lines {
		if strings.HasSuffix(strings.TrimRight(l, " \t\r"), Mark) {
			return i
		}
	}
	return -1
}

// Has reports whether a startup file's text holds our line.
func Has(text string) bool { return markAt(strings.Split(text, "\n")) >= 0 }

// Check says where things stand. entries is the PATH a new terminal gets, self is this program's own path.
func Check(home, shell, goos, zdotdir string, entries []string, self string, look func(string) (string, error)) Status {
	bin := filepath.Join(home, ".local", "bin")
	st := Status{RC: RCFile(home, shell, goos, zdotdir), BinDir: bin}
	if found, err := look("catalyst"); err == nil {
		st.Found = found
		a, _ := filepath.EvalSymlinks(found)
		b, _ := filepath.EvalSymlinks(self)
		if a != b {
			st.State = "clash"
			return st
		}
		st.State = "ready"
		return st
	}
	for _, e := range entries {
		if filepath.Clean(e) == bin {
			st.State = "ready"
			return st
		}
	}
	if hasLine(st.RC) {
		st.State = "ready"
		return st
	}
	st.State = "missing"
	return st
}

// AddLines adds the marked line at the end. Nothing else in the file changes, and a file that already has it is left
// as it is. The last line gets its missing line break, so ours is never glued onto it.
func AddLines(lines []string, fish bool) []string {
	if markAt(lines) >= 0 {
		return lines
	}
	line := Line
	if fish {
		line = Fish
	}
	if len(lines) == 1 && lines[0] == "" {
		return []string{Mark, line, ""}
	}
	if lines[len(lines)-1] != "" {
		lines = append(lines, "")
	}
	return append(lines[:len(lines)-1], "", Mark, line, "")
}

// RemoveLines takes our mark and our line out, and the blank line AddLines put before them. If the line under the mark
// was changed by hand, it is someone's own now: it stays, and kept says what it reads.
func RemoveLines(lines []string) (out []string, kept string) {
	i := markAt(lines)
	if i < 0 {
		return lines, ""
	}
	drop := map[int]bool{}
	if before := strings.TrimSuffix(strings.TrimRight(lines[i], " \t\r"), Mark); strings.TrimSpace(before) != "" {
		lines = append([]string{}, lines...)
		lines[i] = strings.TrimRight(before, " \t") // what the mark was glued onto stays
	} else {
		drop[i] = true
		if i > 0 && strings.TrimRight(lines[i-1], "\r") == "" {
			drop[i-1] = true
		}
	}
	if i+1 < len(lines) {
		switch next := strings.TrimRight(lines[i+1], "\r"); {
		case next == Line || next == Fish:
			drop[i+1] = true
		case strings.Contains(next, ".local/bin"):
			kept = next
		}
	}
	for n, l := range lines {
		if !drop[n] {
			out = append(out, l)
		}
	}
	return out, kept
}
