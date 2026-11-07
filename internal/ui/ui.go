// Package ui is the only code in Catalyst that decides how things look. No command prints on its own, which is how
// every command keeps the same rhythm: a section heading, quiet steps, one tick when done, and a verdict at the end.
//
// The behaviour comes from the personal-homelab-server installer and shell kit: colour only for a person at a terminal,
// symbols with colour and words without, lines that always fit the window, and full output kept back unless a step fails.
package ui

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

// UI writes to one output with one set of decisions about colour and width.
type UI struct {
	Out       io.Writer
	In        *os.File
	Color     bool
	TTY       bool // output is a person's terminal
	InTTY     bool // input is a person's keyboard
	Truecolor bool
	Colors256 bool
	Mascot    bool
	Yes       bool // --yes: answer yes to every question
	FixedW    int  // set by tests and demos
	titled    bool // Title already named this screen, so the command's own first heading would only repeat it

	// Echo, when set, is told what a person typed at a question. The terminal shows it already, but a screen that is
	// redrawn later, such as the session's scrolling view of a result, only knows what was written.
	Echo func(typed string)
}

// New decides everything from the environment. NO_COLOR, a pipe or TERM=dumb all mean plain text.
func New() *UI {
	tty := term.IsTerminal(int(os.Stdout.Fd()))
	dumb := os.Getenv("TERM") == "dumb" || os.Getenv("TERM") == ""
	color := tty && !dumb && os.Getenv("NO_COLOR") == ""
	ct := os.Getenv("COLORTERM")
	return &UI{
		Out: os.Stdout, In: os.Stdin, Color: color, TTY: tty && !dumb,
		InTTY:     term.IsTerminal(int(os.Stdin.Fd())),
		Truecolor: ct == "truecolor" || ct == "24bit",
		Colors256: strings.Contains(os.Getenv("TERM"), "256") || ct != "",
		Mascot:    color && os.Getenv("CI") == "",
	}
}

// Plain is a UI with no colour or animation, for tests and pipes.
func Plain(w io.Writer, width int) *UI { return &UI{Out: w, FixedW: width} }

func (u *UI) wrap(code, s string) string {
	if !u.Color {
		return s
	}
	return "\033[" + code + "m" + s + "\033[0m"
}

// Bold, Dim and the colours below return s styled, or unchanged when colour is off.
func (u *UI) Bold(s string) string   { return u.wrap("1", s) }
func (u *UI) Dim(s string) string    { return u.wrap("2", s) }
func (u *UI) Green(s string) string  { return u.wrap("32", s) }
func (u *UI) Yellow(s string) string { return u.wrap("33", s) }
func (u *UI) Red(s string) string    { return u.wrap("31", s) }
func (u *UI) Cyan(s string) string   { return u.wrap("36", s) }
func (u *UI) Head(s string) string   { return u.wrap("1;36", s) }

func (u *UI) grey(s string) string {
	if u.Color && u.Colors256 {
		return u.wrap("38;5;240", s)
	}
	return u.Dim(s)
}

// fder is anything that sits on a real terminal: a file, or Squeeze around one.
type fder interface{ Fd() uintptr }

// Width is the terminal's width, or 80 when it cannot be told.
func (u *UI) Width() int {
	if u.FixedW > 0 {
		return u.FixedW
	}
	if c, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && c >= 20 {
		return c
	}
	if f, ok := u.Out.(fder); ok {
		if w, _, err := term.GetSize(int(f.Fd())); err == nil && w >= 20 {
			return w
		}
	}
	return 80
}

// Height is the terminal's height, or 0 when it cannot be told.
func (u *UI) Height() int {
	if f, ok := u.Out.(fder); ok {
		if _, h, err := term.GetSize(int(f.Fd())); err == nil {
			return h
		}
	}
	return 0
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;?]*[A-Za-z]`)

// Visible is how many columns s takes once colour codes are ignored.
func Visible(s string) int { return utf8.RuneCountInString(ansi.ReplaceAllString(s, "")) }

// Fit shortens s to the given width. A note in brackets goes first, so a cut never leaves "(" open.
func Fit(s string, width int) string {
	if Visible(s) <= width || width < 2 {
		return s
	}
	plain := ansi.ReplaceAllString(s, "")
	if i := strings.LastIndex(plain, " ("); i > 0 && strings.HasSuffix(plain, ")") && utf8.RuneCountInString(plain[:i]) <= width {
		return plain[:i]
	}
	r := []rune(plain)
	return strings.TrimRight(string(r[:width-1]), " ") + "…"
}

// Line writes one line, indented by nothing and never wider than the window.
func (u *UI) line(s string) { fmt.Fprintln(u.Out, s) }

// Say prints a line, wrapped to the window with the indent carried over.
func (u *UI) Say(s string) {
	for _, l := range u.Wrap(s, u.Width()) {
		u.line(l)
	}
}

// Wrap splits s into lines that fit, keeping its leading spaces on each.
func (u *UI) Wrap(s string, width int) []string {
	if Visible(s) <= width {
		return []string{s}
	}
	trimmed := strings.TrimLeft(s, " ")
	indent := strings.Repeat(" ", len(s)-len(trimmed))
	var out []string
	cur := indent
	for _, w := range strings.Fields(trimmed) {
		if Visible(cur)+Visible(w)+1 > width && strings.TrimSpace(cur) != "" {
			out = append(out, cur)
			cur = indent
		}
		if strings.TrimSpace(cur) != "" {
			cur += " "
		}
		cur += w
	}
	return append(out, cur)
}

// Blank prints an empty line.
func (u *UI) Blank() { fmt.Fprintln(u.Out) }

// Sect starts a section.
func (u *UI) Sect(title string) {
	u.Blank()
	u.line("  " + u.Head(title))
}

func (u *UI) mark(symbol, word string, style func(string) string) string {
	if u.Color {
		return style(symbol) + "    "
	}
	return fmt.Sprintf("%-5s", word)
}

func (u *UI) marked(m, msg string) {
	const left = 7 // two spaces, then the mark and its padding
	pad := strings.Repeat(" ", left)
	lines := u.Wrap(pad+msg, u.Width())
	lines[0] = "  " + m + strings.TrimLeft(lines[0], " ")
	for _, l := range lines {
		u.line(l)
	}
}

// Ok, Warn, Stop and Skip are the four kinds of result line.
func (u *UI) Ok(msg string)   { u.marked(u.mark("✓", "ok", u.Green), msg) }
func (u *UI) Warn(msg string) { u.marked(u.mark("!", "warn", u.Yellow), msg) }
func (u *UI) Stop(msg string) { u.marked(u.mark("✗", "stop", u.Red), msg) }
func (u *UI) Skip(msg string) { u.marked(u.mark("-", "skip", u.Dim), u.Dim(msg)) }
func (u *UI) Note(msg string) { u.marked(u.mark("i", "note", u.Cyan), msg) }

// Hint prints a dim line under a result, lined up with its text.
func (u *UI) Hint(msg string) {
	for _, l := range u.Wrap("       "+msg, u.Width()) {
		u.line(u.Dim(l))
	}
}

// Rule is a thin line, capped at the window.
func (u *UI) Rule(width int) string {
	if w := u.Width() - 4; width > w {
		width = w
	}
	return u.grey(strings.Repeat("─", width))
}

// Hdr is a coloured title with a rule under it.
func (u *UI) Hdr(title string) {
	if u.titled {
		u.titled = false
		return
	}
	u.Blank()
	u.line("  " + u.Bold(u.blue(title)))
	u.line("  " + u.Rule(52))
	u.Blank()
}

// TitleLines names a screen in the session: a blank line, where you are, a rule and a blank line.
func (u *UI) TitleLines(name string) []string {
	return []string{"", "  " + u.Dim("Catalyst") + u.Faint(" › ") + u.Bold(name), "  " + u.Faint(strings.Repeat("─", u.Wide())), ""}
}

// Title prints TitleLines, and tells the next Hdr or Banner that this screen already has its heading.
func (u *UI) Title(name string) {
	for _, l := range u.TitleLines(name) {
		u.line(l)
	}
	u.titled = true
}

func (u *UI) blue(s string) string {
	if u.Color && u.Colors256 {
		return u.wrap("38;5;39", s)
	}
	return u.Cyan(s)
}

// Row is a label and a value, lined up.
func (u *UI) Row(label, value string) {
	head := fmt.Sprintf("  %-16s ", label)
	line := u.grey(head) + value
	if Visible(line) > u.Width() {
		if vs := u.Wrap(value, u.Width()-len(head)); len(vs) > 1 {
			u.line(u.grey(head) + vs[0])
			for _, v := range vs[1:] {
				u.line(strings.Repeat(" ", len(head)) + v)
			}
			return
		}
	}
	u.line(line)
}

// Level colours by threshold: under warn is green, under crit is yellow, else red.
func (u *UI) Level(v, warn, crit int) func(string) string {
	switch {
	case v >= crit:
		return u.Red
	case v >= warn:
		return u.Yellow
	}
	return u.Green
}

// Bar is a progress bar with its percentage. Thresholds decide its colour.
func (u *UI) Bar(pct, width, warn, crit int) string {
	if pct > 100 {
		pct = 100
	}
	if pct < 0 {
		pct = 0
	}
	fill := pct * width / 100
	style := u.Level(pct, warn, crit)
	return style(strings.Repeat("█", fill)) + u.grey(strings.Repeat("░", width-fill)) + " " + style(fmt.Sprintf("%3d%%", pct))
}

// HealthBar is a bar for a score, where high is good.
func (u *UI) HealthBar(score, width int) string {
	fill := score * width / 100
	style := u.ScoreStyle(score)
	return style(strings.Repeat("█", fill)) + u.grey(strings.Repeat("░", width-fill)) + " " + style(strconv.Itoa(score))
}

// ScoreStyle is green for healthy, yellow for a few problems and red for many.
func (u *UI) ScoreStyle(score int) func(string) string {
	switch {
	case score >= 80:
		return u.Green
	case score >= 50:
		return u.Yellow
	}
	return u.Red
}

const bannerArt = ` ██████╗ █████╗ ████████╗ █████╗ ██╗  ██╗   ██╗███████╗████████╗
██╔════╝██╔══██╗╚══██╔══╝██╔══██╗██║  ╚██╗ ██╔╝██╔════╝╚══██╔══╝
██║     ███████║   ██║   ███████║██║   ╚████╔╝ ███████╗   ██║
██║     ██╔══██║   ██║   ██╔══██║██║    ╚██╔╝  ╚════██║   ██║
╚██████╗██║  ██║   ██║   ██║  ██║███████╗██║   ███████║   ██║
 ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝   ╚══════╝   ╚═╝`

// Banner is the name in big letters, only for a person at a terminal wide enough to show it.
func (u *UI) Banner(tagline string) {
	if u.titled || !u.Color || u.Width() < 70 {
		return
	}
	shades := []int{153, 117, 111, 75, 39, 33} // pale sky to Catalyst blue
	u.Blank()
	for i, l := range strings.Split(bannerArt, "\n") {
		if u.Colors256 {
			u.line("  " + u.wrap("38;5;"+strconv.Itoa(shades[i]), l))
		} else {
			u.line("  " + u.Cyan(l))
		}
	}
	u.line("  " + u.Dim(tagline))
	u.line("  " + u.Rule(62))
}

// Signoffs close a card when everything is fine.
var Signoffs = []string{"All systems nominal.", "Purring like a cat.", "Shipshape.", "Looking crisp.", "Carry on.", "Green across the board."}

// Signoff prints a friendly closing line.
func (u *UI) Signoff() {
	u.Blank()
	u.line("  " + u.Dim(Signoffs[time.Now().Nanosecond()%len(Signoffs)]))
	u.Blank()
}

// Size turns bytes into words people use.
func Size(b int64) string {
	const k = 1000.0
	f := float64(b)
	switch {
	case f >= k*k*k*k:
		return fmt.Sprintf("%.1f TB", f/(k*k*k*k))
	case f >= k*k*k:
		return fmt.Sprintf("%.1f GB", f/(k*k*k))
	case f >= k*k:
		return fmt.Sprintf("%.0f MB", f/(k*k))
	case f >= k:
		return fmt.Sprintf("%.0f KB", f/k)
	}
	return fmt.Sprintf("%d bytes", b)
}

// RAM uses the units memory is sold in, so an 8 GB machine reads as 8 GB and not 8.6.
func RAM(b int64) string {
	gb := float64(b) / (1024 * 1024 * 1024)
	if gb >= 10 || gb == float64(int64(gb)) {
		return fmt.Sprintf("%.0f GB", gb)
	}
	return fmt.Sprintf("%.1f GB", gb)
}

// When is a date and 12-hour time, the way people say it.
func When(t time.Time) string { return t.Format("Jan 2, 3:04 PM") }

// Ago says how long ago a time was, in the largest sensible unit.
func Ago(t, now time.Time) string {
	d := now.Sub(t)
	days := int(d.Hours() / 24)
	switch {
	case days >= 365:
		return plural(days/365, "year")
	case days >= 60:
		return plural(days/30, "month")
	case days >= 14:
		return plural(days/7, "week")
	case days >= 1:
		return plural(days, "day")
	case d >= time.Hour:
		return plural(int(d.Hours()), "hour")
	}
	return "minutes"
}

func plural(n int, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return fmt.Sprintf("%d %ss", n, unit)
}

// Count is "1 thing" or "3 things".
func Count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

// squeeze drops blank lines beyond the first in a row. Colour codes and carriage returns do not count as text.
type squeeze struct {
	mu       sync.Mutex
	w        io.Writer
	newlines int
	inEsc    bool
}

// Squeeze wraps a terminal so a run of blank lines prints as one. Commands open and close with a blank line of their own,
// which reads well alone in a shell and doubles up when one screen holds a title, a command and the keys below it.
func Squeeze(w io.Writer) io.Writer { return &squeeze{w: w, newlines: 2} }

func (s *squeeze) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]byte, 0, len(p))
	for _, c := range p {
		switch {
		case s.inEsc:
			if c >= 0x40 && c != '[' {
				s.inEsc = false
			}
		case c == 27:
			s.inEsc = true
		case c == '\r':
		case c == '\n':
			if s.newlines >= 2 {
				continue
			}
			s.newlines++
		default:
			s.newlines = 0
		}
		out = append(out, c)
	}
	if _, err := s.w.Write(out); err != nil {
		return 0, err
	}
	return len(p), nil
}

// Fd is the terminal underneath, so the window's size can still be read.
func (s *squeeze) Fd() uintptr {
	if f, ok := s.w.(fder); ok {
		return f.Fd()
	}
	return ^uintptr(0)
}
