package cli

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// The completion scripts are written from the command table, so a new command or flag completes without anyone
// editing three shell languages by hand.

var (
	flagWord = regexp.MustCompile(`(?:^|[\s\[|])(--?[a-z][a-z-]*)`)
	subWord  = regexp.MustCompile(`(?:\[|\|)\s*([a-z]+)\b`)
)

// placeholders are lowercase words in a usage line that stand for a value, not a word to type.
var placeholders = map[string]bool{"paths": true, "host": true, "on": true, "off": true}

// compSpec is what one command accepts.
type compSpec struct {
	name, help  string
	flags, subs []string
}

func completionSpecs() []compSpec {
	var out []compSpec
	for _, c := range commands() {
		s := compSpec{name: c.Name, help: c.Help}
		seen := map[string]bool{}
		for _, m := range flagWord.FindAllStringSubmatch(c.Args, -1) {
			if !seen[m[1]] {
				seen[m[1]] = true
				s.flags = append(s.flags, m[1])
			}
		}
		for _, m := range subWord.FindAllStringSubmatch(c.Args, -1) {
			if w := m[1]; !placeholders[w] && !seen[w] {
				seen[w] = true
				s.subs = append(s.subs, w)
			}
		}
		out = append(out, s)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
}

func cmdCompletion(a *App, args []string) int {
	fs := a.flags("completion", "bash|zsh|fish")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	var script string
	switch fs.Arg(0) {
	case "bash":
		script = bashCompletion()
	case "zsh":
		script = zshCompletion()
	case "fish":
		script = fishCompletion()
	default:
		a.U.Stop("Say which shell: catalyst completion bash, zsh or fish.")
		a.U.Hint("zsh:  catalyst completion zsh > \"${fpath[1]}/_catalyst\"")
		a.U.Hint("bash: catalyst completion bash > ~/.local/share/bash-completion/completions/catalyst")
		a.U.Hint("fish: catalyst completion fish > ~/.config/fish/completions/catalyst.fish")
		return ExitUsage
	}
	fmt.Fprint(a.U.Out, script)
	return ExitOK
}

func bashCompletion() string {
	var names []string
	var cases strings.Builder
	for _, s := range completionSpecs() {
		names = append(names, s.name)
		if words := append(append([]string{}, s.subs...), s.flags...); len(words) > 0 {
			fmt.Fprintf(&cases, "    %s) words=%q ;;\n", s.name, strings.Join(words, " "))
		}
	}
	return `# catalyst completion for bash. Written by: catalyst completion bash
_catalyst() {
  local cur words=""
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "` + strings.Join(names, " ") + `" -- "$cur"))
    return
  fi
  case "${COMP_WORDS[1]}" in
` + cases.String() + `  esac
  COMPREPLY=($(compgen -W "$words" -- "$cur"))
}
complete -o default -F _catalyst catalyst kit
`
}

func zshQuote(s string) string { return strings.NewReplacer(`'`, `'\''`, `:`, `\:`).Replace(s) }

func zshCompletion() string {
	var cmds, cases strings.Builder
	for _, s := range completionSpecs() {
		fmt.Fprintf(&cmds, "    '%s:%s'\n", s.name, zshQuote(s.help))
		if words := append(append([]string{}, s.subs...), s.flags...); len(words) > 0 {
			fmt.Fprintf(&cases, "    %s) compadd -- %s ;;\n", s.name, strings.Join(words, " "))
		}
	}
	return `#compdef catalyst kit
# catalyst completion for zsh. Written by: catalyst completion zsh
_catalyst() {
  local -a cmds
  cmds=(
` + cmds.String() + `  )
  if (( CURRENT == 2 )); then
    _describe 'command' cmds
    return
  fi
  case $words[2] in
` + cases.String() + `  esac
}
_catalyst "$@"
`
}

func fishCompletion() string {
	var b strings.Builder
	b.WriteString("# catalyst completion for fish. Written by: catalyst completion fish\n")
	for _, prog := range []string{"catalyst", "kit"} {
		fmt.Fprintf(&b, "complete -c %s -f\n", prog)
		for _, s := range completionSpecs() {
			fmt.Fprintf(&b, "complete -c %s -n __fish_use_subcommand -a %s -d '%s'\n", prog, s.name, strings.ReplaceAll(s.help, "'", `\'`))
			when := "'__fish_seen_subcommand_from " + s.name + "'"
			if len(s.subs) > 0 {
				fmt.Fprintf(&b, "complete -c %s -n %s -a '%s'\n", prog, when, strings.Join(s.subs, " "))
			}
			for _, f := range s.flags {
				if l, ok := strings.CutPrefix(f, "--"); ok {
					fmt.Fprintf(&b, "complete -c %s -n %s -l %s\n", prog, when, l)
				} else {
					fmt.Fprintf(&b, "complete -c %s -n %s -o %s\n", prog, when, strings.TrimPrefix(f, "-"))
				}
			}
		}
	}
	return b.String()
}
