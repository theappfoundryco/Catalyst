// Package rcfile reads shell startup files the way the shell will, closely enough to find the slips that people and
// installers make in them: a line glued onto a closing brace, Windows line endings, quotes pasted from a web page, an
// assignment with spaces around =. Each slip names the line it starts on, and most carry the exact edit that mends it.
//
// It is not a full shell parser. The slips that depend on how blocks nest (Unclosed) should only be shown when the
// shell itself rejects the file, so a construct this package does not understand never becomes a false alarm.
package rcfile

import (
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Edit replaces one line with Now, which may be several lines, but only while the line still reads Was. A file changed
// since it was read is never edited blindly.
type Edit struct {
	Line int      `json:"line"`
	Was  string   `json:"was"`
	Now  []string `json:"now"`
}

// The kinds of slip.
const (
	GluedClose  = "glued-close"  // }export PATH=...: the brace no longer closes anything
	GluedLine   = "glued-line"   // "..."export PATH=...: two lines run together
	Unclosed    = "unclosed"     // a block or quote that never ends
	NoNewline   = "no-newline"   // the last line has no line break, so the next one added is glued to it
	CRLF        = "crlf"         // Windows line endings
	BOM         = "bom"          // an invisible mark before the first command
	SmartQuotes = "smart-quotes" // “ ” or ‘ ’ where the shell needs " or '
	SpacedEq    = "spaced-equals"
	TildeQuoted = "tilde-quoted" // "~/bin" is a folder literally named ~
	PathReset   = "path-reset"   // PATH set without $PATH and without the system's folders
	Exit        = "exit"         // exit at the top of a startup file closes every new terminal
)

// Slip is one mistake, on the line it starts on.
type Slip struct {
	Kind  string `json:"kind"`
	Line  int    `json:"line"`
	Title string `json:"title"` // what is wrong, without the file's name
	Why   string `json:"why"`
	// Stops is true when the shell rejects the file or stops reading it there, so the lines after it never run.
	Stops bool   `json:"stops,omitempty"`
	Edits []Edit `json:"edits,omitempty"` // empty when only a person can tell what was meant
}

// Shell is the shell that reads a startup file, by its name: "zsh", "bash", "sh", "fish", or "" when it is not one.
func Shell(path string) string {
	b := strings.TrimPrefix(filepath.Base(path), ".")
	switch {
	case strings.HasSuffix(b, ".fish"):
		return "fish"
	case strings.HasPrefix(b, "zsh") || strings.HasPrefix(b, "zprofile") || strings.HasPrefix(b, "zlogin") || strings.HasSuffix(b, ".zsh"):
		return "zsh"
	case strings.HasPrefix(b, "bash"):
		return "bash"
	case b == "profile":
		return "sh"
	}
	return ""
}

// Lines splits a file the way edits count lines. A final line break gives a last, empty line, so joining with "\n"
// gives back the same bytes.
func Lines(text string) []string { return strings.Split(text, "\n") }

// Apply makes the edits. It reports false, and changes nothing, when a line no longer reads as it did. A line that moved
// (another fix above it split a line in two) is still found, but only when exactly one line reads that way.
func Apply(lines []string, edits []Edit) ([]string, bool) {
	at := make([]int, len(edits))
	for k, e := range edits {
		at[k] = -1
		if e.Line >= 1 && e.Line <= len(lines) && lines[e.Line-1] == e.Was {
			at[k] = e.Line - 1
			continue
		}
		for i, l := range lines {
			if l == e.Was {
				if at[k] >= 0 {
					return lines, false // two candidates: never guess
				}
				at[k] = i
			}
		}
		if at[k] < 0 {
			return lines, false
		}
	}
	out := append([]string{}, lines...)
	for {
		k := -1 // the lowest edit left, last line first, so earlier line numbers stay true
		for j := range edits {
			if at[j] >= 0 && (k < 0 || at[j] > at[k]) {
				k = j
			}
		}
		if k < 0 {
			return out, true
		}
		i := at[k]
		out = append(out[:i], append(append([]string{}, edits[k].Now...), out[i+1:]...)...)
		at[k] = -1
	}
}

var closes = map[string]string{"}": "{", "fi": "if", "esac": "case", "done": "do"}

// startsStatement is what installers append. A word glued onto fi, done or esac that begins with one of these was
// meant to be the next line; anything else may be an ordinary word like file or finger.
var startsStatement = regexp.MustCompile(`^(export\s|alias\s|source\s|eval\s|unset\s|typeset\s|declare\s|PATH=|path=|\.\s)`)

var (
	gluedAfterQuote = regexp.MustCompile(`^(export|alias|source|eval|unset)\s`)
	gluedAfterPath  = regexp.MustCompile(`\$\{?PATH\}?(export|alias|source|eval)\s`)
	spacedEq        = regexp.MustCompile(`^(\s*)(export\s+|typeset\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_][A-Za-z0-9_]*)(\s+=\s*|=\s+)(\S.*)$`)
	pathAssign      = regexp.MustCompile(`^\s*(export\s+)?PATH=`)
)

// Scan finds the slips in one startup file's text. path picks the shell's rules and is not read.
func Scan(path, text string) []Slip {
	if text == "" {
		return nil
	}
	var out []Slip
	lines := Lines(text)
	shell := Shell(path)
	if strings.HasPrefix(lines[0], "\ufeff") {
		out = append(out, Slip{Kind: BOM, Line: 1, Stops: true,
			Title: "An invisible mark (a byte order mark) sits before the first command",
			Why:   "Some Windows editors add it. The shell reads it as part of the first word, so the first line fails with command not found.",
			Edits: []Edit{{Line: 1, Was: lines[0], Now: []string{strings.TrimPrefix(lines[0], "\ufeff")}}}})
	}
	var crlf []Edit
	for i, l := range lines {
		if strings.HasSuffix(l, "\r") {
			crlf = append(crlf, Edit{Line: i + 1, Was: l, Now: []string{strings.TrimRight(l, "\r")}})
		}
	}
	if len(crlf) > 0 {
		out = append(out, Slip{Kind: CRLF, Line: crlf[0].Line,
			Title: "It has Windows line endings (" + count(len(crlf), "line", "lines") + ")",
			Why:   "The shell keeps the hidden \\r at the end of each line, so a folder added to PATH ends in it and is never found, and some lines fail with $'\\r': command not found.",
			Edits: crlf})
	}
	if last := lines[len(lines)-1]; last != "" {
		out = append(out, Slip{Kind: NoNewline, Line: len(lines),
			Title: "The last line has no line break after it",
			Why:   "Harmless today, but the next tool that adds a line here will glue it onto this one. That is how lines like }export PATH=... happen.",
			Edits: []Edit{{Line: len(lines), Was: last, Now: []string{last, ""}}}})
	}
	if shell == "fish" { // a different grammar, and fish -n is the only judge of it
		return sortSlips(out)
	}
	s := scanner{shell: shell}
	for i, raw := range lines {
		s.line(i+1, strings.TrimSuffix(strings.TrimPrefix(raw, "\ufeff"), "\r"), raw)
	}
	out = append(out, s.slips...)
	switch {
	case len(s.nests) > 0:
		o := s.nests[0]
		what := map[byte]string{'\'': "A quote (')", 'e': "A quote ($')", '"': `A quote (")`, '`': "A backtick (`)", '(': "A $( or (", '{': "A ${"}[o.kind]
		out = append(out, Slip{Kind: Unclosed, Line: o.line, Stops: true,
			Title: what + " that opens on this line is never closed",
			Why:   "So the shell reads everything after it, to the end of the file, as part of it, and rejects the file."})
	case len(s.stack) > 0:
		o := s.stack[len(s.stack)-1]
		out = append(out, Slip{Kind: Unclosed, Line: o.line, Stops: true,
			Title: "The " + blockName(o.word) + " that starts on this line is never closed",
			Why:   "So the shell reaches the end of the file still inside it, and rejects the whole file. Add the missing " + endOf(o.word) + " where it should end."})
	}
	return sortSlips(out)
}

func blockName(w string) string {
	switch w {
	case "{":
		return "{ block"
	case "do":
		return "loop"
	case "case-in":
		return "case block"
	}
	return w + " block"
}

func endOf(w string) string {
	switch w {
	case "if":
		return "fi"
	case "case", "case-in":
		return "esac"
	case "do":
		return "done"
	}
	return "}"
}

func count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// sortSlips orders by line, and on one line puts first what stops the shell.
func sortSlips(s []Slip) []Slip {
	before := func(a, b Slip) bool { return a.Line < b.Line || (a.Line == b.Line && a.Stops && !b.Stops) }
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && before(s[j], s[j-1]); j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
	return s
}

// restore puts back what a line had around its text, so one fix never undoes another: the byte order mark on the first
// line and a Windows line ending have fixes of their own.
func restore(raw, s string, first bool) string {
	if first && strings.HasPrefix(raw, "\ufeff") {
		s = "\ufeff" + s
	}
	if strings.HasSuffix(raw, "\r") {
		s += "\r"
	}
	return s
}

func indentOf(s string) string { return s[:len(s)-len(strings.TrimLeft(s, " \t"))] }

type opener struct {
	word  string // "{", "if", "case", "case-in" (after its in), "do"
	line  int
	then  bool // an if has reached its then
	short bool // a zsh { that is an if's whole body: if [[ ... ]] { ... }, with no fi
}

// nest is one context the scanner is inside: a quote, $( ), ${ } or backticks. They nest, and they span lines.
type nest struct {
	kind byte // '\'', 'e' ($'...'), '"', '`', '(' or '{'
	line int
}

// scanner walks the file a character at a time, keeping what spans lines: open quotes and substitutions, a
// here-document, the blocks that are still open, whether a case is reading patterns.
type scanner struct {
	shell   string
	nests   []nest
	heredoc []string // terminators still to come on later lines, in order
	inDoc   string
	docTabs bool
	stack   []opener
	cont    bool // the last line ended with a backslash
	casePat bool // the next word is a case pattern, not a command
	fnName  bool // the next word names a function
	slips   []Slip
}

func (s *scanner) top() string {
	if len(s.stack) == 0 {
		return ""
	}
	return s.stack[len(s.stack)-1].word
}

func (s *scanner) push(w string, n int) {
	o := opener{word: w, line: n}
	if w == "{" && s.shell == "zsh" && s.top() == "if" && !s.stack[len(s.stack)-1].then {
		o.short = true
	}
	s.stack = append(s.stack, o)
}

func (s *scanner) pop() opener {
	o := s.stack[len(s.stack)-1]
	s.stack = s.stack[:len(s.stack)-1]
	if o.short && s.top() == "if" { // its else { ... } and elif ... { ... } close themselves
		s.stack = s.stack[:len(s.stack)-1]
	}
	return o
}

func (s *scanner) enter(k byte, n int) { s.nests = append(s.nests, nest{k, n}) }

// inside reads the character at i while some quote or substitution is open, and returns the index it ends on.
func (s *scanner) inside(n int, text, raw string, i int) int {
	c := text[i]
	next := byte(0)
	if i+1 < len(text) {
		next = text[i+1]
	}
	k := s.nests[len(s.nests)-1].kind
	leave := func() {
		s.nests = s.nests[:len(s.nests)-1]
		if len(s.nests) == 0 && (k == '"' || k == '\'') {
			s.afterQuote(n, text, raw, i+1)
		}
	}
	switch k {
	case '\'':
		if c == '\'' {
			leave()
		}
		return i
	case 'e', '`':
		switch {
		case c == '\\':
			return i + 1
		case (k == 'e' && c == '\'') || (k == '`' && c == '`'):
			leave()
		}
		return i
	}
	// '"', '(' and '{' can all hold substitutions; only ( and { hold quotes of their own.
	switch {
	case c == '\\':
		return i + 1
	case c == '$' && next == '(':
		s.enter('(', n)
		return i + 1
	case c == '$' && next == '{':
		s.enter('{', n)
		return i + 1
	case c == '`':
		s.enter('`', n)
	case k == '"' && c == '"':
		leave()
	case k == '"':
	case c == '$' && next == '\'':
		s.enter('e', n)
		return i + 1
	case c == '\'':
		s.enter('\'', n)
	case c == '"':
		s.enter('"', n)
	case k == '(' && c == '(':
		s.enter('(', n)
	case k == '(' && c == ')', k == '{' && c == '}':
		leave()
	}
	return i
}

// line reads one line. text has the \r and the byte order mark taken off; raw is the line as the file has it.
func (s *scanner) line(n int, text, raw string) {
	if s.inDoc != "" {
		t := text
		if s.docTabs {
			t = strings.TrimLeft(t, "\t")
		}
		if t == s.inDoc {
			s.inDoc = ""
			s.nextDoc()
		}
		return
	}
	inCode := len(s.nests) == 0 && !s.cont
	if inCode {
		s.lineChecks(n, text, raw)
	}
	cmd := inCode
	s.cont = false
	var word strings.Builder
	start := -1
	quoted := len(s.nests) > 0 // the word holds a quote or an expansion, so it is never a keyword
	if quoted {
		start = 0
	}
	redirect := false
	var curly []int // where “ ” ‘ ’ sit outside any quote
	flush := func(end int) {
		if start < 0 {
			return
		}
		w, at, wasQuoted := word.String(), start, quoted
		word.Reset()
		start, quoted = -1, false
		switch {
		case redirect:
			redirect = false
		case w == "}" && !wasQuoted && s.shell == "zsh" && s.top() == "{":
			s.pop() // zsh closes a block with a lone } anywhere on the line: f() { ls }
			cmd = false
		case s.casePat && w != "esac":
			// a pattern; its ) ends the patterns
		case s.fnName:
			s.fnName = false
			cmd = true
		case w == "in" && s.top() == "case":
			s.stack[len(s.stack)-1].word = "case-in"
			s.casePat = true
		case !cmd && w != "esac":
		case wasQuoted:
			if !strings.Contains(w, "=") {
				cmd = false
			}
		default:
			s.word(n, w, at, end, text, raw, &cmd)
		}
	}
	for i := 0; i < len(text); i++ {
		if len(s.nests) > 0 {
			i = s.inside(n, text, raw, i)
			continue
		}
		c := text[i]
		next := byte(0)
		if i+1 < len(text) {
			next = text[i+1]
		}
		if start < 0 && !strings.ContainsRune(" \t;&|()<>#", rune(c)) {
			start = i
		}
		switch {
		case c == '\\':
			if i == len(text)-1 {
				s.cont = true
				continue
			}
			word.WriteByte(c)
			word.WriteByte(next)
			i++
		case c == '$' && (next == '\'' || next == '(' || next == '{'):
			quoted = true
			s.enter(map[byte]byte{'\'': 'e', '(': '(', '{': '{'}[next], n)
			i++
		case c == '\'' || c == '"' || c == '`':
			quoted = true
			s.enter(c, n)
		case c == '#' && start < 0:
			flush(i)
			s.endLine(n, curly, text, raw)
			return
		case c == ' ' || c == '\t':
			flush(i)
		case c == ';' || c == '&' || c == '|':
			flush(i)
			if c == ';' && (next == ';' || next == '&') {
				i++
				if s.top() == "case-in" {
					s.casePat = true
				}
				cmd = false
				continue
			}
			if next == c {
				i++
			}
			cmd = true
		case c == '(':
			if next == ')' && start >= 0 { // name() defines a function, and its body comes next
				word.Reset()
				start, quoted = -1, false
				s.fnName = false
				i++
				cmd = true
				continue
			}
			if start >= 0 { // an array, or a glob group: one word, whatever is inside
				quoted = true
				s.enter('(', n)
				continue
			}
			cmd = true
		case c == ')':
			flush(i)
			s.casePat = false
			cmd = true
		case c == '<' || c == '>':
			flush(i)
			if strings.HasPrefix(text[i:], "<<") && !strings.HasPrefix(text[i:], "<<<") {
				i = s.hereDoc(text, i) - 1
				continue
			}
			for i+1 < len(text) && strings.ContainsRune("<>&|", rune(text[i+1])) {
				i++
			}
			if i+1 < len(text) && text[i+1] == '(' { // <(...) and >(...) are the word a redirect reads
				start, quoted = i, true
				s.enter('(', n)
				i++
				continue
			}
			redirect = true
		default:
			if r := curlyAt(text, i); r > 0 {
				curly = append(curly, i)
				quoted = true
				i += r - 1
				continue
			}
			word.WriteByte(c)
		}
	}
	if len(s.nests) == 0 {
		flush(len(text))
	}
	s.endLine(n, curly, text, raw)
}

// hereDoc reads <<WORD at i and returns where the word ends. The document's lines are skipped, starting on the next line.
func (s *scanner) hereDoc(text string, i int) int {
	j := i + 2
	tabs := false
	if j < len(text) && text[j] == '-' {
		tabs = true
		j++
	}
	for j < len(text) && (text[j] == ' ' || text[j] == '\t') {
		j++
	}
	k := j
	for k < len(text) && !strings.ContainsRune(" \t;&|<>)", rune(text[k])) {
		k++
	}
	if term := strings.Trim(text[j:k], `'"\`); term != "" {
		s.heredoc = append(s.heredoc, term)
		s.docTabs = tabs
	}
	return k
}

func (s *scanner) endLine(n int, curly []int, text, raw string) {
	if len(curly) > 0 {
		var b strings.Builder
		last := 0
		for _, at := range curly {
			b.WriteString(text[last:at])
			if strings.HasPrefix(text[at:], "‘") || strings.HasPrefix(text[at:], "’") {
				b.WriteByte('\'')
			} else {
				b.WriteByte('"')
			}
			last = at + curlyAt(text, at)
		}
		b.WriteString(text[last:])
		s.slips = append(s.slips, Slip{Kind: SmartQuotes, Line: n,
			Title: "It has curly quotes (“ ” or ‘ ’), usually pasted from a web page or a chat",
			Why:   "The shell does not read them as quotes. They become part of the text, so a folder added to PATH starts with “ and is never found.",
			Edits: []Edit{{Line: n, Was: raw, Now: []string{restore(raw, b.String(), n == 1)}}}})
	}
	if s.inDoc == "" {
		s.nextDoc()
	}
}

func (s *scanner) nextDoc() {
	if len(s.heredoc) > 0 {
		s.inDoc, s.heredoc = s.heredoc[0], s.heredoc[1:]
	}
}

// word handles a word in a command's place. Keywords open and close blocks, and a closing keyword with more glued onto
// it is the slip this package exists for.
func (s *scanner) word(n int, w string, start, end int, text, raw string, cmd *bool) {
	switch w {
	case "{", "if", "do":
		s.push(w, n)
		return
	case "case":
		s.push(w, n)
		*cmd = false
		return
	case "then":
		if s.top() == "if" {
			s.stack[len(s.stack)-1].then = true
		}
		return
	case "else", "elif", "!", "time", "while", "until":
		return
	case "function":
		s.fnName = true
		*cmd = false
		return
	case "for", "select", "foreach":
		*cmd = false
		return
	case "}", "fi", "done", "esac":
		if t := s.top(); t == closes[w] || (w == "esac" && t == "case-in") {
			s.pop()
			if w == "esac" {
				s.casePat = false
			}
		}
		*cmd = false
		return
	}
	for kw, want := range closes {
		rest := text[start:]
		if !strings.HasPrefix(w, kw) || len(w) == len(kw) {
			continue
		}
		if t := s.top(); t != want && !(kw == "esac" && t == "case-in") {
			continue
		}
		if kw != "}" && !startsStatement.MatchString(rest[len(kw):]) {
			continue // fi, done and esac also begin ordinary words
		}
		o := s.pop()
		var edits []Edit
		if strings.TrimSpace(text[:start]) == "" {
			ind := indentOf(text)
			edits = []Edit{{Line: n, Was: raw, Now: []string{restore(raw, ind+kw, n == 1), restore(raw, ind+strings.TrimLeft(rest[len(kw):], " \t"), false)}}}
		}
		s.slips = append(s.slips, Slip{Kind: GluedClose, Line: n, Stops: true,
			Title: "The " + kw + " that closes the " + blockName(o.word) + " from line " + strconv.Itoa(o.line) + " has the next line glued onto it",
			Why:   "With text right after it, " + kw + " is no longer a closing word, so the block never ends and the shell rejects the whole file. It usually happens when a tool adds a line to a file whose last line has no line break.",
			Edits: edits})
		*cmd = false
		return
	}
	if !strings.Contains(w, "=") || strings.HasPrefix(w, "=") {
		*cmd = false // a command; an assignment before one keeps the place
	}
	if w == "exit" && len(s.stack) == 0 && strings.TrimSpace(text[:start]) == "" && !strings.Contains(text[end:], "&&") && !strings.Contains(text[end:], "||") {
		s.slips = append(s.slips, Slip{Kind: Exit, Line: n, Stops: true,
			Title: "It runs exit outside any function or condition",
			Why:   "A startup file runs inside your terminal's own shell, so exit closes the terminal as soon as it opens, and nothing after this line runs.",
			Edits: []Edit{{Line: n, Was: raw, Now: []string{restore(raw, indentOf(text)+"# "+strings.TrimLeft(text, " \t")+"  # turned off by Catalyst: exit here closes every new terminal", n == 1)}}}})
	}
}

// afterQuote looks right after a closing quote for a second statement glued on: "..."export PATH=...
func (s *scanner) afterQuote(n int, text, raw string, at int) {
	if gluedAfterQuote.MatchString(text[at:]) {
		s.split(n, text, raw, at)
	}
}

func (s *scanner) split(n int, text, raw string, at int) {
	for _, sl := range s.slips {
		if sl.Line == n && sl.Kind == GluedLine {
			return
		}
	}
	s.slips = append(s.slips, Slip{Kind: GluedLine, Line: n,
		Title: "Two lines are run together",
		Why:   "The first one's value takes the start of the second as part of itself, so neither does what it should. It usually happens when a tool adds a line to a file whose last line has no line break.",
		Edits: []Edit{{Line: n, Was: raw, Now: []string{restore(raw, text[:at], n == 1), restore(raw, indentOf(text)+text[at:], false)}}}})
}

// lineChecks are the slips that one line shows on its own, read only on lines that start outside a quote.
func (s *scanner) lineChecks(n int, text, raw string) {
	t := strings.TrimSpace(text)
	if t == "" || strings.HasPrefix(t, "#") {
		return
	}
	if loc := gluedAfterPath.FindStringSubmatchIndex(text); loc != nil {
		s.split(n, text, raw, loc[2])
	}
	if m := spacedEq.FindStringSubmatch(text); m != nil && !strings.HasPrefix(m[5], "=") {
		spaceBefore := strings.HasPrefix(m[4], " ") || strings.HasPrefix(m[4], "\t")
		declared := m[2] != ""
		// NAME= cmd runs cmd with NAME empty, which is real shell. Only a declaration rules that out.
		if (spaceBefore && (declared || strings.ToUpper(m[3]) == m[3])) || (!spaceBefore && declared) {
			why := "The shell does not allow spaces around =, so " + m[3] + " is never set."
			stops := s.shell == "zsh"
			if stops {
				why = "zsh stops reading the file at this line (bad assignment), so nothing after it runs."
			} else if !declared {
				why = "With spaces, the shell tries to run a command called " + m[3] + ", and " + m[3] + " is never set."
			}
			s.slips = append(s.slips, Slip{Kind: SpacedEq, Line: n, Stops: stops,
				Title: "There are spaces around the = in " + m[3] + "=",
				Why:   why,
				Edits: []Edit{{Line: n, Was: raw, Now: []string{restore(raw, m[1]+m[2]+m[3]+"="+m[5], n == 1)}}}})
		}
	}
	if pathAssign.MatchString(text) {
		s.pathLine(n, text, raw)
	}
}

// pathLine checks a line that sets PATH.
func (s *scanner) pathLine(n int, text, raw string) {
	value := strings.TrimSpace(text[strings.Index(text, "PATH=")+len("PATH="):])
	if j := strings.IndexAny(value, ";&|#"); j >= 0 && !strings.ContainsAny(value[:j], `"'`) {
		value = strings.TrimSpace(value[:j])
	}
	if strings.HasPrefix(value, `"`) && (strings.Contains(value, `"~/`) || strings.Contains(value, ":~/") || strings.Contains(value, `"~:`)) {
		fixed := strings.NewReplacer(`"~/`, `"$HOME/`, `:~/`, `:$HOME/`, `"~:`, `"$HOME:`).Replace(text)
		s.slips = append(s.slips, Slip{Kind: TildeQuoted, Line: n,
			Title: "A ~ inside quotes is added to PATH",
			Why:   "Inside quotes the shell keeps ~ as it is, so the folder searched is one literally named ~, not your home folder. $HOME works inside quotes.",
			Edits: []Edit{{Line: n, Was: raw, Now: []string{restore(raw, fixed, n == 1)}}}})
	}
	if value == "" || strings.Contains(value, "PATH") || strings.Contains(value, "$path") || strings.Contains(value, "$(") || strings.Contains(value, "`") {
		return
	}
	bare := strings.Trim(value, `"'`)
	for _, d := range strings.Split(bare, ":") {
		if d == "/usr/bin" || d == "/bin" {
			return // a full list of its own, which some people keep on purpose
		}
	}
	var edits []Edit
	switch {
	case strings.HasSuffix(text, value) && strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) && strings.Count(value, `"`) == 2:
		edits = []Edit{{Line: n, Was: raw, Now: []string{restore(raw, strings.TrimSuffix(text, `"`)+`:$PATH"`, n == 1)}}}
	case strings.HasSuffix(text, value) && !strings.ContainsAny(value, `"' `):
		edits = []Edit{{Line: n, Was: raw, Now: []string{restore(raw, text+":$PATH", n == 1)}}}
	}
	s.slips = append(s.slips, Slip{Kind: PathReset, Line: n,
		Title: "It sets PATH without keeping what was already on it",
		Why:   "Every folder added before this line, the system's own included, is dropped, so commands like ls and git stop being found in new terminals. Ending the value with :$PATH keeps them.",
		Edits: edits})
}

// curlyAt is the length in bytes of a curly quote at i, or 0.
func curlyAt(text string, i int) int {
	for _, q := range []string{"“", "”", "‘", "’"} {
		if strings.HasPrefix(text[i:], q) {
			return len(q)
		}
	}
	return 0
}

// skipParens is the index of the ) that closes the ( at i, outside quotes, or the last index of the line.
func skipParens(text string, i int) int {
	depth := 0
	var q byte
	for j := i; j < len(text); j++ {
		c := text[j]
		switch {
		case q != 0:
			if c == q {
				q = 0
			} else if c == '\\' && q == '"' {
				j++
			}
		case c == '\'' || c == '"':
			q = c
		case c == '(':
			depth++
		case c == ')':
			depth--
			if depth == 0 {
				return j
			}
		}
	}
	return len(text) - 1
}

// Again finds a slip in text as it is now: the same kind, on the nearest line. Fixes are offered one at a time, and
// one fix can move or change the lines another was worked out for, so each is worked out again just before it is shown.
func Again(path, text, kind string, line int) (Slip, bool) {
	var best Slip
	found := false
	for _, s := range Scan(path, text) {
		if s.Kind != kind {
			continue
		}
		if !found || abs(s.Line-line) < abs(best.Line-line) {
			best, found = s, true
		}
	}
	return best, found
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// Trust keeps the slips that depend on how blocks nest only when the shell itself rejected the file. If the shell reads
// it fine, this package misread something, and saying otherwise would be a false alarm.
func Trust(slips []Slip, rejected bool) []Slip {
	if rejected {
		return slips
	}
	var out []Slip
	for _, s := range slips {
		if s.Kind != Unclosed && s.Kind != GluedClose {
			out = append(out, s)
		}
	}
	return out
}
