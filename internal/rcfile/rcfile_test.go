package rcfile

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// fixAll mends each slip in turn the way doctor --fix offers them: each is worked out again on the file as the fixes
// before it left it.
func fixAll(t *testing.T, name, text string, slips []Slip) string {
	t.Helper()
	for _, first := range slips {
		s, ok := Again(name, text, first.Kind, first.Line)
		if !ok || len(s.Edits) == 0 {
			continue // an earlier fix mended this one too
		}
		next, ok := Apply(Lines(text), s.Edits)
		if !ok {
			t.Fatalf("%s on line %d did not apply to %q", s.Kind, s.Line, text)
		}
		text = strings.Join(next, "\n")
	}
	return text
}

func kinds(ss []Slip) string {
	var k []string
	for _, s := range ss {
		k = append(k, s.Kind+"@"+itoa(s.Line))
	}
	return strings.Join(k, " ")
}

func itoa(n int) string { return strconv.Itoa(n) }

func writeFile(p, s string) error { return os.WriteFile(p, []byte(s), 0o644) }

func TestEachSlipIsFoundOnItsLineAndMended(t *testing.T) {
	cases := []struct {
		name, file, text, want, fixed string
	}{
		{"export glued onto a closing brace", ".bashrc",
			"greet() {\n  echo hi\n}export PATH=\"$HOME/go/bin:$PATH\"\n",
			"glued-close@3", "greet() {\n  echo hi\n}\nexport PATH=\"$HOME/go/bin:$PATH\"\n"},
		{"brace on its own line, export glued, no final newline", ".bashrc",
			"greet() {\n  echo hi\n\n}export PATH=\"$HOME/go/bin:$PATH\"",
			"glued-close@4 no-newline@4", "greet() {\n  echo hi\n\n}\nexport PATH=\"$HOME/go/bin:$PATH\"\n"},
		{"Catalyst's own mark glued onto a brace", ".bashrc",
			"greet() {\n  echo hi\n}# added by catalyst\nexport PATH=\"$HOME/.local/bin:$PATH\"\n",
			"glued-close@3", "greet() {\n  echo hi\n}\n# added by catalyst\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"},
		{"fi with an export glued on, indented", ".zshrc",
			"if true; then\n  echo a\n  fiexport A=1\n",
			"glued-close@3", "if true; then\n  echo a\n  fi\n  export A=1\n"},
		{"two exports run together after a quote", ".bashrc",
			"export PATH=\"/opt/a/bin:$PATH\"export PATH=\"/opt/b/bin:$PATH\"\n",
			"glued-line@1", "export PATH=\"/opt/a/bin:$PATH\"\nexport PATH=\"/opt/b/bin:$PATH\"\n"},
		{"two exports run together with no quotes", ".profile",
			"export PATH=/opt/a/bin:$PATHexport PATH=/opt/b/bin:$PATH\n",
			"glued-line@1", "export PATH=/opt/a/bin:$PATH\nexport PATH=/opt/b/bin:$PATH\n"},
		{"Windows line endings", ".bashrc",
			"export PATH=\"$HOME/go/bin:$PATH\"\r\nalias ll=\"ls -l\"\r\n",
			"crlf@1", "export PATH=\"$HOME/go/bin:$PATH\"\nalias ll=\"ls -l\"\n"},
		{"a byte order mark", ".bashrc",
			"\ufeffexport PATH=\"$HOME/go/bin:$PATH\"\n",
			"bom@1", "export PATH=\"$HOME/go/bin:$PATH\"\n"},
		{"curly quotes", ".bashrc",
			"export PATH=“$HOME/go/bin:$PATH”\nalias x=‘ls’\n",
			"smart-quotes@1 smart-quotes@2", "export PATH=\"$HOME/go/bin:$PATH\"\nalias x='ls'\n"},
		{"spaces around = in zsh stop the file", ".zshrc",
			"export PATH = \"$HOME/go/bin:$PATH\"\nalias ll=\"ls -l\"\n",
			"spaced-equals@1", "export PATH=\"$HOME/go/bin:$PATH\"\nalias ll=\"ls -l\"\n"},
		{"a space after = in export empties PATH", ".bashrc",
			"export PATH= \"$HOME/go/bin:$PATH\"\n",
			"spaced-equals@1", "export PATH=\"$HOME/go/bin:$PATH\"\n"},
		{"~ inside quotes", ".bashrc",
			"export PATH=\"~/go/bin:~/bin:$PATH\"\n",
			"tilde-quoted@1", "export PATH=\"$HOME/go/bin:$HOME/bin:$PATH\"\n"},
		{"PATH replaced instead of extended", ".bashrc",
			"export PATH=\"/opt/tool/bin\"\n",
			"path-reset@1", "export PATH=\"/opt/tool/bin:$PATH\"\n"},
		{"PATH replaced, unquoted", ".zshrc",
			"PATH=/opt/tool/bin\n",
			"path-reset@1", "PATH=/opt/tool/bin:$PATH\n"},
		{"exit at the top of the file", ".bashrc",
			"alias ll=\"ls -l\"\nexit 0\n",
			"exit@2", "alias ll=\"ls -l\"\n# exit 0  # turned off by Catalyst: exit here closes every new terminal\n"},
		{"several at once, fixed one after another", ".bashrc",
			"\ufeffexport PATH=“$HOME/go/bin:$PATH”\r\ngreet() {\r\n}export A=1\r\n",
			"bom@1 crlf@1 smart-quotes@1 glued-close@3", "export PATH=\"$HOME/go/bin:$PATH\"\ngreet() {\n}\nexport A=1\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Scan(c.file, c.text)
			if kinds(got) != c.want {
				t.Fatalf("found %q, want %q", kinds(got), c.want)
			}
			if fixed := fixAll(t, c.file, c.text, got); fixed != c.fixed {
				t.Fatalf("fixed to\n%q\nwant\n%q", fixed, c.fixed)
			}
			if again := Scan(c.file, c.fixed); len(again) != 0 {
				t.Fatalf("the mended file still has %s", kinds(again))
			}
			for _, s := range got {
				for _, txt := range []string{s.Title, s.Why} {
					if strings.Contains(txt, "\u2014") || txt == "" {
						t.Errorf("%s: %q", s.Kind, txt)
					}
				}
			}
		})
	}
}

func TestUnclosedNamesTheLineItOpensOn(t *testing.T) {
	for text, want := range map[string]string{
		"greet() {\n  echo hi\n":                                  "unclosed@1",
		"export PATH=\"$HOME/go/bin:$PATH\nalias ll=\"ls -l\"\n":  "unclosed@2", // the second " opens a quote that never closes
		"if [ -d ~/go ]; then\n  export PATH=\"$HOME/go/bin\"\n":  "unclosed@1",
		"x=$(echo \"a\n  b\"\n":                                   "unclosed@1",
		"for f in a b; do\n  echo \"$f\"\n\ncase $x in\n a) ;;\n": "unclosed@4",
	} {
		got := Scan(".bashrc", text)
		var k []string
		for _, s := range got {
			if s.Kind == Unclosed {
				k = append(k, s.Kind+"@"+itoa(s.Line))
			}
		}
		if strings.Join(k, " ") != want {
			t.Errorf("%q: %v, want %s", text, kinds(got), want)
		}
	}
}

// Real startup files, written the way tools and people really write them, must come back clean.
func TestNoFalseAlarmsOnOrdinaryFiles(t *testing.T) {
	files := map[string]string{
		".bashrc": `# ~/.bashrc
case $- in
    *i*) ;;
      *) return;;
esac
HISTCONTROL=ignoreboth
shopt -s histappend
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
fi
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
# >>> conda initialize >>>
__conda_setup="$('/home/alex/miniconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/home/alex/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/home/alex/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="/home/alex/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<
mkcd() { mkdir -p "$1" && cd "$1"; }
function up {
  local n=${1:-1}
  while [ "$n" -gt 0 ]; do cd ..; n=$((n - 1)); done
}
cat <<'EOF' > /dev/null
}export not code, a here-document "
EOF
while read -r l; do echo "$l"; done < <(printf 'a\nb\n')
[ -z "$PS1" ] && return
export PATH=/usr/local/bin:/usr/bin:/bin
fixit=1
donelist=2
echo "it’s fine inside quotes"
`,
		".zshrc": `export ZSH="$HOME/.oh-my-zsh"
plugins=(git docker
  kubectl)
source $ZSH/oh-my-zsh.sh
eval "$(/opt/homebrew/bin/brew shellenv)"
typeset -U path
path=($HOME/bin $path)
() {
  local f
  for f in ~/.zsh.d/*.zsh(N); do source $f; done
}
f() { ls }
if [[ -n $SSH_CONNECTION ]] { export EDITOR=vim } else { export EDITOR=code }
precmd() {
  print -P "%F{blue}%~%f"
}
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
export PATH="$HOME/.local/bin:$PATH"
`,
		".profile": `if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
. "$HOME/.cargo/env"
`,
	}
	for name, text := range files {
		if got := Scan(name, text); len(got) != 0 {
			for _, s := range got {
				t.Errorf("%s line %d: %s (%s)", name, s.Line, s.Kind, s.Title)
			}
		}
	}
}

// The shell has the last word on what parses. Where it is installed, the files this package calls broken must be the
// ones it rejects, and every mended one must be accepted.
func TestTheShellAgrees(t *testing.T) {
	cases := map[string]string{
		".bashrc":  "greet() {\n  echo hi\n}export PATH=\"$HOME/go/bin:$PATH\"\n",
		".zshrc":   "greet() {\n  echo hi\n}export PATH=\"$HOME/go/bin:$PATH\"\n",
		".profile": "if true; then\n  echo a\nfiexport A=1\n",
	}
	ran := 0
	for name, text := range cases {
		sh := Shell(name)
		if _, err := exec.LookPath(sh); err != nil {
			continue
		}
		ran++
		dir := t.TempDir()
		write := func(s string) bool {
			p := filepath.Join(dir, name)
			if err := writeFile(p, s); err != nil {
				t.Fatal(err)
			}
			return exec.Command(sh, "-n", p).Run() == nil
		}
		if write(text) {
			t.Errorf("%s accepted %q", sh, text)
		}
		if fixed := fixAll(t, name, text, Scan(name, text)); !write(fixed) {
			t.Errorf("%s rejected the mended %q", sh, fixed)
		}
	}
	if ran == 0 {
		t.Skip("no shell here to compare with")
	}
}

func TestTrustDropsWhatTheShellAccepted(t *testing.T) {
	ss := []Slip{{Kind: Unclosed}, {Kind: GluedClose}, {Kind: CRLF}}
	if got := Trust(ss, false); len(got) != 1 || got[0].Kind != CRLF {
		t.Fatal(got)
	}
	if got := Trust(ss, true); len(got) != 3 {
		t.Fatal(got)
	}
}

func TestApplyNeverEditsALineThatChanged(t *testing.T) {
	lines := []string{"a", "}export A=1", "b"}
	if _, ok := Apply(lines, []Edit{{Line: 2, Was: "}export B=1", Now: []string{"}", "export B=1"}}}); ok {
		t.Fatal("edited a line that no longer reads the same")
	}
	// A line that moved down is found again, but only when exactly one line reads that way.
	moved := []string{"x", "a", "}export A=1", "b"}
	got, ok := Apply(moved, []Edit{{Line: 2, Was: "}export A=1", Now: []string{"}", "export A=1"}}})
	if !ok || strings.Join(got, "|") != "x|a|}|export A=1|b" {
		t.Fatal(got, ok)
	}
	twice := []string{"}export A=1", "}export A=1"}
	if _, ok := Apply(twice, []Edit{{Line: 5, Was: "}export A=1", Now: []string{"}"}}}); ok {
		t.Fatal("guessed between two equal lines")
	}
}

func TestShellByName(t *testing.T) {
	for in, want := range map[string]string{
		"/h/.zshrc": "zsh", "/h/.zshenv": "zsh", "/h/.zprofile": "zsh", "/z/.zlogin": "zsh",
		"/h/.bashrc": "bash", "/h/.bash_profile": "bash", "/h/.bash_login": "bash",
		"/h/.profile": "sh", "/h/.config/fish/config.fish": "fish", "/h/notes.txt": "",
	} {
		if got := Shell(in); got != want {
			t.Errorf("%s: %q", in, got)
		}
	}
}

func TestFishGetsOnlyTheFileLevelSlips(t *testing.T) {
	got := Scan("/h/.config/fish/config.fish", "function f\n  echo }export\nend\r\n")
	if kinds(got) != "crlf@3" {
		t.Fatal(kinds(got))
	}
}
