// Package session is bare `catalyst`: one list you move through with the arrow keys, and Enter opens what is highlighted.
// There is nothing to type here. Anything with arguments belongs in the shell, as `catalyst ports kill 3000`.
//
// It runs on the terminal's separate screen, so it leaves no trail in your scrollback, and Ctrl-C twice leaves. This is
// also the only place Kit appears: at the top of the home screen, once.
package session

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

// Item is one row. A row with Sub opens another list, and any other row runs Args.
type Item struct {
	Name, Help string
	Args       []string
	Gap        bool   // a blank row above it
	Detail     string // a line under it, such as what Undo would reverse
	Disabled   bool   // shown dim, and the cursor passes over it
	Sub        []Item
}

// Header is what sits at the top of the home screen.
type Header struct {
	Mood  string // Kit's reaction to what just happened. Empty means idle, which moves
	Lines []string
}

// Action is a key offered at the bottom of a result, such as f to fix what the doctor just found.
type Action struct {
	Key, Label string
	Title      string // what the next screen is called
	Args       []string
}

// Outcome is what a finished command wants to happen next.
type Outcome struct {
	Actions  []Action
	SkipWait bool     // nothing worth reading: go straight back
	Quit     bool     // the program is gone or replaced: leave
	Farewell []string // with Quit: lines to print once the terminal is back to normal
}

// Config is everything a session needs.
type Config struct {
	UI     *ui.UI
	Items  func() []Item // read again after every command, since what just ran can change a row
	Header func() Header
	Run    func(args []string) Outcome
}

// Picker is a list and its cursor. It holds no terminal, so it can be tested with plain key names.
type Picker struct {
	Items []Item
	Cur   int
}

// What a key press asks for.
const (
	Keep  = iota
	Open  // run what is highlighted
	Back  // Esc or left arrow
	Leave // q
	Quit  // Ctrl-C or Ctrl-D
)

// step moves the cursor by one in either direction, passing over disabled rows. If every row is disabled it stays.
func (p *Picker) step(by int) {
	n := len(p.Items)
	for i := 1; i <= n; i++ {
		next := ((p.Cur+by*i)%n + n) % n
		if !p.Items[next].Disabled {
			p.Cur = next
			return
		}
	}
}

// Settle keeps the cursor off a disabled row, for when the rows change under it.
func (p *Picker) Settle() {
	if p.Cur >= len(p.Items) {
		p.Cur = 0
	}
	if len(p.Items) > 0 && p.Items[p.Cur].Disabled {
		p.step(1)
	}
}

// Key applies one key.
func (p *Picker) Key(k string) int {
	switch k {
	case "up", "k":
		if len(p.Items) > 0 {
			p.step(-1)
		}
	case "down", "j":
		if len(p.Items) > 0 {
			p.step(1)
		}
	case "enter":
		if len(p.Items) == 0 || p.Items[p.Cur].Disabled {
			return Keep
		}
		return Open
	case "esc", "left":
		return Back
	case "q", "Q":
		return Leave
	case "ctrl-c", "ctrl-d":
		return Quit
	}
	return Keep
}

const (
	kitColumns = 20 // the widest mood, so the text beside Kit never moves when the mood changes
	kitRows    = 5
	minForKit  = 60
)

// headerLines puts Kit beside the text, both resting on the same last line. Without room for Kit, only the text is left.
func headerLines(u *ui.UI, h Header, mood string, withKit bool, cols int) []string {
	if !withKit {
		var out []string
		for _, l := range h.Lines {
			if l != "" {
				out = append(out, "  "+ui.Fit(l, cols-3))
			}
		}
		return out
	}
	art := kit.Render(mood, u.Truecolor)
	pad := strings.Repeat(" ", kitColumns-kit.Width(mood))
	out := make([]string, kitRows)
	for i := range out {
		left := strings.Repeat(" ", kitColumns)
		if j := i - (kitRows - len(art)); j >= 0 {
			left = art[j] + pad
		}
		text := ""
		if j := i - (kitRows - len(h.Lines)); j >= 0 && j < len(h.Lines) {
			text = h.Lines[j]
		}
		out[i] = strings.TrimRight("  "+left+"  "+ui.Fit(text, cols-kitColumns-5), " ")
	}
	return out
}

// rows draws the list, and says which line holds the cursor.
func (p *Picker) rows(u *ui.UI, cols int) ([]string, int) {
	var out []string
	at := 0
	for i, it := range p.Items {
		if it.Gap {
			out = append(out, "")
		}
		name := fmt.Sprintf("%-10s", it.Name)
		help := ""
		if cols >= 40 {
			help = ui.Fit(it.Help, cols-17)
		}
		switch {
		case i == p.Cur:
			at = len(out)
			out = append(out, ui.Fit("  "+u.Band(u.Accent(u.Bold(name))+"  "+help, u.Wide()), cols-1))
		case it.Disabled:
			out = append(out, strings.TrimRight("    "+u.Faint(name+"  "+help), " "))
		default:
			out = append(out, strings.TrimRight("    "+name+"  "+u.Dim(help), " "))
		}
		if it.Detail != "" && cols >= 30 {
			out = append(out, "      "+u.Faint("└ ")+u.Soft(ui.Fit(it.Detail, cols-9)))
		}
	}
	return out, at
}

// fitRows keeps the cursor's line in view when the window is too short for the whole list.
func fitRows(lines []string, at, room int) []string {
	if room < 1 {
		room = 1
	}
	if len(lines) <= room {
		return lines
	}
	top := at - room/2
	if top < 0 {
		top = 0
	}
	if top+room > len(lines) {
		top = len(lines) - room
	}
	return lines[top : top+room]
}

// frame builds a whole screen: top, list, keys. It never uses the window's last row, because writing there scrolls it.
func frame(u *ui.UI, p *Picker, top func(withKit bool) []string, foot []string, cols, rows int) []string {
	if rows <= 0 {
		rows = 24
	}
	list, at := p.rows(u, cols)
	foot = append([]string{""}, foot...)
	head := top(true)
	if len(head)+1+len(list)+len(foot) > rows-1 {
		head = top(false)
	}
	room := rows - 1 - len(head) - 1 - len(foot)
	if room < 3 { // a tiny window: the list and the keys matter most
		head, room = nil, rows-1-len(foot)
	}
	out := append([]string{}, head...)
	if len(head) > 0 {
		out = append(out, "")
	}
	out = append(out, fitRows(list, at, room)...)
	return append(out, foot...)
}

// waitKey waits for a key press, up to the timeout, and returns what was read. It reads nothing unless a key is ready.
// A reader left blocked in the background would steal the keys meant for a command's own menu or question.
func waitKey(fd int, in *os.File, timeout time.Duration) ([]byte, error) {
	var set unix.FdSet
	set.Zero()
	set.Set(fd)
	tv := unix.NsecToTimeval(timeout.Nanoseconds())
	n, err := unix.Select(fd+1, &set, nil, nil, &tv)
	if err != nil {
		if errors.Is(err, unix.EINTR) {
			return nil, nil
		}
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	buf := make([]byte, 256)
	got, err := in.Read(buf)
	if err != nil {
		return nil, err
	}
	return buf[:got], nil
}

type runner struct {
	c        Config
	u        *ui.UI
	term     io.Writer // the real terminal, under the copy every command's output also goes to
	tee      *tee
	fd       int
	header   Header
	armed    time.Time // when Ctrl-C was pressed once; a second press soon after leaves
	farewell []string  // last words that must outlive the separate screen, such as "Catalyst is gone."
}

const twice = 2 * time.Second

func (s *runner) clear()      { fmt.Fprint(s.u.Out, "\033[H\033[2J") }
func (s *runner) hideCursor() { fmt.Fprint(s.u.Out, "\033[?25l") }
func (s *runner) showCursor() { fmt.Fprint(s.u.Out, "\033[?25h") }

// ctrlC applies one Ctrl-C and says whether it was the second. The first only warns, so a stray press never closes it.
func (s *runner) ctrlC() bool {
	if !s.armed.IsZero() && time.Since(s.armed) < twice {
		return true
	}
	s.armed = time.Now()
	return false
}

// footer is the key bar, or the Ctrl-C warning while it applies.
func (s *runner) footer(pairs ...string) []string {
	if !s.armed.IsZero() && time.Since(s.armed) < twice {
		return s.u.Notice("Press Ctrl-C again to exit")
	}
	return s.u.KeyBar(pairs...)
}

// keys waits for input in raw mode, running tick while it waits. A closed keyboard reads as two Ctrl-Ds, so nothing spins.
func (s *runner) keys(tick func()) []string {
	old, err := term.MakeRaw(s.fd)
	if err != nil {
		return []string{"eof"}
	}
	defer term.Restore(s.fd, old)
	for {
		got, err := waitKey(s.fd, s.u.In, 100*time.Millisecond)
		if err != nil {
			return []string{"eof"}
		}
		if k := ui.Keys(got); len(k) > 0 {
			return k
		}
		if tick != nil {
			tick()
		}
	}
}

// drain drops keys pressed while a command ran, so a stray Enter cannot skip past its result unread.
func (s *runner) drain() {
	old, err := term.MakeRaw(s.fd)
	if err != nil {
		return
	}
	defer term.Restore(s.fd, old)
	for {
		if got, err := waitKey(s.fd, s.u.In, 0); err != nil || len(got) == 0 {
			return
		}
	}
}

func (s *runner) paint(lines []string) {
	var b strings.Builder // one write, so an animation frame never shows half drawn
	b.WriteString("\033[H")
	for _, l := range lines {
		b.WriteString("\033[2K" + l + "\r\n")
	}
	b.WriteString("\033[J")
	fmt.Fprint(s.term, b.String())
}

// list shows one list until the person leaves it. It returns false when the whole session should end.
func (s *runner) list(items []Item, title string) bool {
	u := s.u
	p := &Picker{Items: items}
	p.Settle()
	home := title == ""
	frameNo := 0
	lastMove := time.Now()
	wasArmed := false
	cols, rows := u.Width(), u.Height()
	draw := func() {
		mood := s.header.Mood
		if home && u.Mascot && (mood == "" || mood == kit.Idle) {
			switch {
			case frameNo%14 == 9: // a blink every so often
				mood = kit.Blink
			case frameNo%2 == 1:
				mood = kit.Wag
			default:
				mood = kit.Idle
			}
		}
		top := func(withKit bool) []string {
			if !home {
				return u.TitleLines(title)[:3]
			}
			return headerLines(u, s.header, mood, withKit && u.Mascot && cols >= minForKit, cols)
		}
		foot := s.footer("↑↓", "move", "⏎", "open", "esc", "back")
		if home {
			foot = s.footer("↑↓", "move", "⏎", "open", "ctrl-c", "exit")
		}
		s.paint(frame(u, p, top, foot, cols, rows))
	}
	s.clear()
	s.hideCursor()
	draw()
	for {
		tick := func() {
			armed := !s.armed.IsZero() && time.Since(s.armed) < twice
			switch {
			case u.Width() != cols || u.Height() != rows:
				cols, rows = u.Width(), u.Height()
				s.clear()
				draw()
			case wasArmed && !armed: // the warning has had its moment
				draw()
			case home && u.Mascot && (s.header.Mood == "" || s.header.Mood == kit.Idle) && time.Since(lastMove) >= 420*time.Millisecond:
				frameNo++
				lastMove = time.Now()
				draw()
			}
			wasArmed = armed
		}
		for _, k := range s.keys(tick) {
			if k == "eof" {
				return false
			}
			switch p.Key(k) {
			case Quit:
				if s.ctrlC() {
					return false
				}
			case Leave, Back:
				if !home {
					return true
				}
			case Open:
				s.armed = time.Time{}
				it := p.Items[p.Cur]
				stay := false
				if it.Sub != nil {
					stay = s.list(it.Sub, it.Name)
				} else {
					stay = s.run(it.Name, it.Args)
				}
				if !stay {
					return false
				}
				s.header = s.c.Header() // what just ran may have changed the health, or given Kit something to react to
				if home {
					p.Items = s.c.Items()
					p.Settle()
				}
				cols, rows = u.Width(), u.Height()
				s.clear()
				s.hideCursor()
			}
		}
		wasArmed = !s.armed.IsZero() && time.Since(s.armed) < twice
		draw()
	}
}

// run clears the window, runs one command, and shows its result. It returns false when the session should end.
func (s *runner) run(name string, args []string) bool {
	u := s.u
	for {
		s.clear()
		s.showCursor() // a command may ask a question, and a person should see where they are typing
		u.Title(name)
		copy := newScreen()
		s.tee.copy = copy
		u.Echo = func(typed string) { copy.Write([]byte(typed)) }
		out := s.c.Run(args)
		s.tee.copy, u.Echo = io.Discard, nil
		if out.Quit {
			s.farewell = out.Farewell
			return false
		}
		if out.SkipWait {
			return true
		}
		s.hideCursor()
		s.drain()
		next, quit := s.result(name, copy.Lines(), out.Actions)
		if quit {
			return false
		}
		if next == nil {
			return true
		}
		name, args = next.Title, next.Args
	}
}

// result shows what a command printed, under its title. Taller than the window, it scrolls, starting at the end the way
// the command left it, since the verdict is usually last.
func (s *runner) result(name string, body []string, actions []Action) (*Action, bool) {
	u := s.u
	top := -1
	wasArmed := false
	view := func() int {
		v := u.Height() - 1 - 4 - 1 - 2 // the title, the line above the keys, the keys
		if u.Height() <= 0 {
			v = 16
		}
		if v < 3 {
			v = 3
		}
		return v
	}
	clamp := func() {
		if most := len(body) - view(); top > most {
			top = most
		}
		if top < 0 {
			top = 0
		}
	}
	draw := func() {
		v := view()
		if top == -1 {
			top = len(body) - v
		}
		clamp()
		cols := u.Width()
		out := u.TitleLines(name)
		end := top + v
		if end > len(body) {
			end = len(body)
		}
		for _, l := range body[top:end] {
			out = append(out, ui.Fit(l, cols-1))
		}
		scrolls := len(body) > v
		pairs := []string{}
		for _, a := range actions {
			pairs = append(pairs, a.Key, a.Label)
		}
		if scrolls {
			pairs = append(pairs, "↑↓", "scroll")
			var where []string
			if top > 0 {
				where = append(where, ui.Count(top, "line", "lines")+" above")
			}
			if below := len(body) - end; below > 0 {
				where = append(where, ui.Count(below, "line", "lines")+" below")
			}
			out = append(out, "  "+u.Faint(strings.Join(where, "  ·  ")))
		} else {
			out = append(out, "")
		}
		pairs = append(pairs, "⏎", "back", "ctrl-c", "exit")
		s.paint(append(out, s.footer(pairs...)...))
	}
	s.clear()
	draw()
	cols, rows := u.Width(), u.Height()
	for {
		tick := func() {
			armed := !s.armed.IsZero() && time.Since(s.armed) < twice
			if u.Width() != cols || u.Height() != rows || (wasArmed && !armed) {
				cols, rows = u.Width(), u.Height()
				s.clear()
				draw()
			}
			wasArmed = armed
		}
		for _, k := range s.keys(tick) {
			switch k {
			case "eof":
				return nil, true
			case "enter", "esc", "left", "q":
				return nil, false
			case "ctrl-c", "ctrl-d":
				if s.ctrlC() {
					return nil, true
				}
			case "up", "k":
				top--
			case "down", "j":
				top++
			case "pgup":
				top -= view()
			case "pgdn", " ":
				top += view()
			case "home", "g":
				top = 0
			case "end", "G":
				top = len(body)
			}
			for i := range actions {
				if k == actions[i].Key {
					s.armed = time.Time{}
					return &actions[i], false
				}
			}
		}
		wasArmed = !s.armed.IsZero() && time.Since(s.armed) < twice
		draw()
	}
}

// Run is the session. It draws on the terminal's separate screen, the one full-screen programs like less and vim use,
// so nothing piles up in your scrollback and the terminal comes back as it was when you leave. It returns the exit code.
func Run(c Config) int {
	u := c.UI
	real := u.Out
	s := &runner{c: c, u: u, term: real, tee: &tee{term: real, copy: io.Discard}, fd: int(u.In.Fd())}
	u.Out = ui.Squeeze(s.tee) // commands each open and close with a blank line; on one screen, one is enough
	leave := func() { fmt.Fprint(real, "\033[?25h\033[?1049l") }
	fmt.Fprint(real, "\033[?1049h")
	// A command waiting on a question reads a normal line, where Ctrl-C is a signal rather than a key. Put the terminal
	// back before going, or the shell would be left on the separate screen with no cursor.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigs)
	go func() {
		if _, ok := <-sigs; ok {
			leave()
			os.Exit(130)
		}
	}()
	s.header = c.Header()
	s.list(c.Items(), "")
	leave()
	u.Out = real
	for _, l := range s.farewell {
		fmt.Fprintln(real, l)
	}
	return 0
}
