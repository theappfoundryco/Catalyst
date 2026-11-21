package cli

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCompletionsCoverEveryCommand(t *testing.T) {
	bash, zsh, fish := bashCompletion(), zshCompletion(), fishCompletion()
	for _, c := range commands() {
		if !strings.Contains(bash, " "+c.Name) || !strings.Contains(zsh, "'"+c.Name+":") || !strings.Contains(fish, "-a "+c.Name+" ") {
			t.Errorf("%s is missing from a completion script", c.Name)
		}
	}
	if !strings.Contains(bash, `path) words="add remove status"`) || !strings.Contains(bash, `config) words="set"`) {
		t.Errorf("subcommands:\n%s", bash)
	}
	if strings.Contains(bash, "paths") || strings.Contains(bash, " host") {
		t.Error("a placeholder became a word to type")
	}
}

// Each shell that is installed here checks its own script's syntax.
func TestCompletionScriptsParse(t *testing.T) {
	dir := t.TempDir()
	for shell, script := range map[string]string{"bash": bashCompletion(), "zsh": zshCompletion(), "fish": fishCompletion()} {
		p, err := exec.LookPath(shell)
		if err != nil {
			continue
		}
		f := filepath.Join(dir, "c."+shell)
		os.WriteFile(f, []byte(script), 0o644)
		if out, err := exec.Command(p, "-n", f).CombinedOutput(); err != nil {
			t.Errorf("%s: %v\n%s", shell, err, out)
		}
	}
}
