// Package shellpath puts the catalyst command on the terminal's PATH: one marked line in the shell's startup file if
// ~/.local/bin is not on the PATH yet. It comes out again with Remove, and only if it is ours. Check looks first and changes nothing.
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
	return err == nil && strings.Contains(string(b), Mark)
}

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

// Add writes the marked line. Nothing else in the file changes.
func Add(rc string) error {
	if hasLine(rc) {
		return nil
	}
	b, err := os.ReadFile(rc)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	text := string(b)
	if err := os.MkdirAll(filepath.Dir(rc), 0o755); err != nil {
		return err
	}
	line := Line
	if strings.HasSuffix(rc, ".fish") {
		line = Fish
	}
	sep := "\n"
	if text != "" && !strings.HasSuffix(text, "\n") {
		sep = "\n\n"
	}
	if text == "" {
		sep = ""
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(rc); err == nil {
		mode = st.Mode().Perm()
	}
	return os.WriteFile(rc, []byte(text+sep+Mark+"\n"+line+"\n"), mode)
}

// Remove takes our line out of a startup file. It reports whether anything changed.
func Remove(rc string) (bool, error) {
	b, err := os.ReadFile(rc)
	if err != nil {
		return false, nil
	}
	lines := strings.Split(string(b), "\n")
	i := -1
	for n, l := range lines {
		if l == Mark {
			i = n
			break
		}
	}
	if i < 0 {
		return false, nil
	}
	drop := map[int]bool{i: true}
	if i+1 < len(lines) && (lines[i+1] == Line || lines[i+1] == Fish) {
		drop[i+1] = true
	}
	if i > 0 && lines[i-1] == "" {
		drop[i-1] = true
	}
	var keep []string
	for n, l := range lines {
		if !drop[n] {
			keep = append(keep, l)
		}
	}
	st, err := os.Stat(rc)
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(rc, []byte(strings.Join(keep, "\n")), st.Mode().Perm())
}
