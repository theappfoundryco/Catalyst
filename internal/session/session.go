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
	"math"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/run"
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
	// Health is the last checkup's score, or -1 for none. A line holding Dot gets the health dot there, which breathes
	// while the score is Fresh, faster the worse it is. An old score keeps its colour and stays still.
	Health int
	Fresh  bool
}

// Dot marks where the health dot goes in a header line.
const Dot = "\x00"

// Action is a key offered at the bottom of a result, such as f to fix what the doctor just found. One with Args opens
// the next screen. One with Do acts in place, such as copying a path, and the line it returns shows for a moment.
type Action struct {
	Key, Label string
	Title      string // what the next screen is called
	Args       []string
	Do         func() string
	refresh    bool
}

// Row is a line in a result that the cursor can rest on, with the keys that act on it. ID matches ui.Mark.
type Row struct {
	ID   int
	Keys []Action
}

// Outcome is what a finished command wants to happen next.
type Outcome struct {
	Actions  []Action
	Rows     []Row
	Focus    int           // which row the cursor starts on
	Refresh  bool          // r measures again
	Live     time.Duration // l keeps measuring, this often
	Changed  bool          // something changed: the screen this was opened from measures again on the way back
	SkipWait bool          // nothing worth reading: go straight back
	Quit     bool          // the program is gone or replaced: leave
	Farewell []string      // with Quit: lines to print once the terminal is back to normal
	Restart  string        // a new copy of the program is here: once this result is read, become it
}

// Config is everything a session needs.
type Config struct {
	UI     *ui.UI
	Items  func() []Item // read again after every command, since what just ran can change a row
	Header func() Header
	Run    func(args []string) Outcome
	First  []string // a command to run once before the home screen, such as the first-run welcome
	Motion bool     // Kit may wag and the health dot may breathe
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
	restart  string    // the program to become when the session ends, after an update
	born     time.Time
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
	var b strings.Builder              // one write, so an animation frame never shows half drawn
	b.WriteString("\033[?2026h\033[H") // terminals that know it hold the frame until it is complete
	dot := s.u.HealthDot(s.header.Health, s.glow())
	for _, l := range lines {
		b.WriteString("\033[2K" + strings.Replace(l, Dot, dot, 1) + "\r\n")
	}
	b.WriteString("\033[J\033[?2026l")
	fmt.Fprint(s.term, b.String())
}

// breathes says whether the health dot is moving: a fresh score, with motion allowed and colour to show it.
func (s *runner) breathes() bool {
	return s.c.Motion && s.u.Color && s.header.Fresh && s.header.Health >= 0
}

// glow is where the dot is in its breath, from 0 to 1. A still dot sits at full colour.
func (s *runner) glow() float64 {
	if !s.breathes() {
		return 1
	}
	period := ui.Breath(s.header.Health)
	t := math.Mod(time.Since(s.born).Seconds(), period) / period
	return 0.5 - 0.5*math.Cos(2*math.Pi*t)
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
		if home && u.Mascot && s.c.Motion && (mood == "" || mood == kit.Idle) {
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
			case home && u.Mascot && s.c.Motion && (s.header.Mood == "" || s.header.Mood == kit.Idle) && time.Since(lastMove) >= 420*time.Millisecond:
				frameNo++
				lastMove = time.Now()
				draw()
			case home && s.breathes():
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

// page is one screen of results: what a command printed, which of its lines are rows, and where the person is in it.
type page struct {
	name  string
	args  []string
	body  []string
	marks map[int]int
	out   Outcome
	cur   int // which row the cursor is on
	top   int // the first line in view; -1 until it is first drawn
	live  bool
}

type rowAt struct {
	row  Row
	line int
}

// rows are the page's rows that made it onto the screen, top to bottom.
func (p *page) rows() []rowAt {
	var out []rowAt
	for _, r := range p.out.Rows {
		if line, ok := p.marks[r.ID]; ok {
			out = append(out, rowAt{r, line})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].line < out[j].line })
	return out
}

// exec runs one command and keeps what it printed. Quiet runs it behind the screen that is showing, to measure again.
func (s *runner) exec(name string, args []string, quiet bool) *page {
	u := s.u
	if !quiet {
		s.clear()
		s.showCursor() // a command may ask a question, and a person should see where they are typing
	}
	s.tee.mute = quiet
	u.Title(name)
	copy := newScreen()
	s.tee.copy = copy
	u.Echo = func(typed string) { copy.Write([]byte(typed)) }
	u.Marks = true
	out := s.c.Run(args)
	u.Marks = false
	s.tee.copy, u.Echo, s.tee.mute = io.Discard, nil, false
	body, marks := copy.Page()
	p := &page{name: name, args: args, body: body, marks: marks, out: out, top: -1}
	if n := len(p.rows()); out.Focus > 0 && out.Focus < n {
		p.cur = out.Focus
	}
	return p
}

// again measures a page again and keeps the person's place in it.
func (s *runner) again(p *page) *page {
	s.paint(append(s.u.TitleLines(p.name), "  "+s.u.Faint("Measuring again…")))
	n := s.exec(p.name, p.args, true)
	n.cur, n.top, n.live = p.cur, p.top, p.live
	if rs := n.rows(); n.cur >= len(rs) {
		n.cur = max(0, len(rs)-1)
	}
	return n
}

// run clears the window, runs one command, and shows its result. A key on the result can open another screen, and Esc
// comes back to this one, measured again if what happened there changed anything. It returns false when the session
// should end.
func (s *runner) run(name string, args []string) bool {
	var stack []*page
	p := s.exec(name, args, false)
	for {
		if p.out.Quit {
			s.farewell = p.out.Farewell
			return false
		}
		var act *Action
		if !p.out.SkipWait {
			s.hideCursor()
			s.drain()
			var quit bool
			if act, quit = s.result(p); quit {
				s.farewell = p.out.Farewell // leaving with Ctrl-C skips the restart, but not the note
				return false
			}
		}
		if p.out.Restart != "" {
			s.restart, s.farewell = p.out.Restart, p.out.Farewell
			return false
		}
		switch {
		case act != nil && act.refresh:
			p = s.again(p)
		case act != nil:
			stack = append(stack, p)
			p = s.exec(act.Title, act.Args, false)
		case len(stack) == 0:
			return true
		default:
			changed := p.out.Changed
			p, stack = stack[len(stack)-1], stack[:len(stack)-1]
			if changed {
				p = s.again(p)
				p.out.Changed = true // and the screen before this one hears about it too
			}
		}
	}
}

// result shows a page under its title. Taller than the window, it scrolls, starting at the end the way the command left
// it, since the verdict is usually last. When the page has rows, the arrows move between them and the keys act on the
// one under the cursor.
func (s *runner) result(p *page) (*Action, bool) {
	u := s.u
	wasArmed := false
	flash, flashed := "", time.Time{}
	measured := time.Now()
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
		if most := len(p.body) - view(); p.top > most {
			p.top = most
		}
		if p.top < 0 {
			p.top = 0
		}
	}
	// show keeps the cursor's row in view, with the line above it too when that is a heading or a blank.
	show := func() {
		rs := p.rows()
		if len(rs) == 0 {
			return
		}
		if p.cur >= len(rs) {
			p.cur = len(rs) - 1
		}
		line, v := rs[p.cur].line, view()
		if p.cur == 0 && line < v { // the first row: show what is above it too, such as column headings
			p.top = 0
		}
		if line < p.top {
			p.top = line
		}
		if line >= p.top+v {
			p.top = line - v + 1
		}
		clamp()
	}
	// follow puts the cursor on a row that is in view, after the view was scrolled.
	follow := func() {
		rs := p.rows()
		v := view()
		if len(rs) == 0 || (rs[p.cur].line >= p.top && rs[p.cur].line < p.top+v) {
			return
		}
		for i, r := range rs {
			if r.line >= p.top && r.line < p.top+v {
				p.cur = i
				if r.line >= p.top { // the first one in view when scrolling up, the last when scrolling down
					break
				}
			}
		}
	}
	current := func() *Row {
		if rs := p.rows(); len(rs) > 0 {
			return &rs[p.cur].row
		}
		return nil
	}
	draw := func() {
		v := view()
		if p.top == -1 {
			p.top = len(p.body) - v
			clamp()
			show()
		}
		clamp()
		cols := u.Width()
		out := u.TitleLines(p.name)
		end := p.top + v
		if end > len(p.body) {
			end = len(p.body)
		}
		at := -1
		row := current()
		if rs := p.rows(); len(rs) > 0 {
			at = rs[p.cur].line
		}
		for i, l := range p.body[p.top:end] {
			if p.top+i == at {
				l = u.Band(strings.TrimPrefix(l, "  "), u.Wide()+2)
			}
			out = append(out, ui.Fit(l, cols))
		}
		scrolls := len(p.body) > v
		var pairs []string
		if row != nil {
			for _, a := range row.Keys {
				pairs = append(pairs, a.Key, a.Label)
			}
		}
		for _, a := range p.out.Actions {
			pairs = append(pairs, a.Key, a.Label)
		}
		if p.out.Refresh {
			pairs = append(pairs, "r", "refresh")
		}
		if p.out.Live > 0 {
			if p.live {
				pairs = append(pairs, "l", "stop live")
			} else {
				pairs = append(pairs, "l", "live")
			}
		}
		switch {
		case row != nil:
			pairs = append(pairs, "↑↓", "move")
		case scrolls:
			pairs = append(pairs, "↑↓", "scroll")
		}
		var where []string
		if p.live {
			where = append(where, u.Green("●")+" "+u.Dim(fmt.Sprintf("live, every %d seconds", int(p.out.Live.Seconds()))))
		}
		if scrolls {
			if p.top > 0 {
				where = append(where, ui.Count(p.top, "line", "lines")+" above")
			}
			if below := len(p.body) - end; below > 0 {
				where = append(where, ui.Count(below, "line", "lines")+" below")
			}
		}
		status := "  " + u.Faint(strings.Join(where, "  ·  "))
		if flash != "" && time.Since(flashed) < 4*time.Second {
			status = "  " + u.Accent(flash)
		}
		out = append(out, strings.TrimRight(status, " "))
		if row != nil || len(p.out.Actions) > 0 {
			pairs = append(pairs, "esc", "back", "ctrl-c", "exit")
		} else {
			pairs = append(pairs, "⏎", "back", "ctrl-c", "exit")
		}
		s.paint(append(out, s.footer(pairs...)...))
	}
	s.clear()
	draw()
	cols, rows := u.Width(), u.Height()
	for {
		tick := func() {
			armed := !s.armed.IsZero() && time.Since(s.armed) < twice
			switch {
			case u.Width() != cols || u.Height() != rows || (wasArmed && !armed):
				cols, rows = u.Width(), u.Height()
				s.clear()
				draw()
			case p.live && time.Since(measured) >= p.out.Live:
				n := s.exec(p.name, p.args, true)
				p.body, p.marks, p.out = n.body, n.marks, n.out
				measured = time.Now()
				draw()
			case flash != "" && time.Since(flashed) >= 4*time.Second:
				flash = ""
				draw()
			}
			wasArmed = armed
		}
		for _, k := range s.keys(tick) {
			row := current()
			switch k {
			case "eof":
				return nil, true
			case "esc", "left", "q":
				return nil, false
			case "ctrl-c", "ctrl-d":
				if s.ctrlC() {
					return nil, true
				}
				continue
			case "up", "k":
				if row != nil && p.cur > 0 {
					p.cur--
					show()
				} else {
					p.top--
				}
				continue
			case "down", "j":
				if row != nil && p.cur < len(p.rows())-1 {
					p.cur++
					show()
				} else {
					p.top++
				}
				continue
			case "pgup":
				p.top -= view()
				clamp()
				follow()
				continue
			case "pgdn", " ":
				p.top += view()
				clamp()
				follow()
				continue
			case "home", "g":
				p.top, p.cur = 0, 0
				continue
			case "end", "G":
				p.top = len(p.body)
				clamp()
				if n := len(p.rows()); n > 0 {
					p.cur = n - 1
				}
				continue
			case "r":
				if p.out.Refresh {
					s.armed = time.Time{}
					return &Action{refresh: true}, false
				}
			case "l":
				if p.out.Live > 0 {
					p.live = !p.live
					measured = time.Time{}
					continue
				}
			}
			var keys []Action
			if row != nil {
				keys = append(keys, row.Keys...)
			}
			keys = append(keys, p.out.Actions...)
			acted := false
			for i := range keys {
				a := keys[i]
				if k != a.Key && !(k == "enter" && a.Key == "⏎") {
					continue
				}
				acted = true
				if a.Do != nil {
					flash, flashed = a.Do(), time.Now()
					break
				}
				s.armed = time.Time{}
				return &a, false
			}
			if !acted && k == "enter" && row == nil && len(p.out.Actions) == 0 {
				return nil, false
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
	s := &runner{c: c, u: u, term: real, tee: &tee{term: real, copy: io.Discard}, fd: int(u.In.Fd()), born: time.Now()}
	u.Out = ui.Squeeze(s.tee) // commands each open and close with a blank line; on one screen, one is enough
	u.Margin = 1
	leave := func() { fmt.Fprint(real, "\033[?25h\033[?1049l") }
	fmt.Fprint(real, "\033[?1049h")
	// A command waiting on a question reads a normal line, where Ctrl-C is a signal rather than a key. Put the terminal
	// back before going, or the shell would be left on the separate screen with no cursor.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigs)
	go func() {
		for range sigs {
			if run.Foreground.Load() { // a program such as sudo has the terminal, and the Ctrl-C was for it
				continue
			}
			leave()
			os.Exit(130)
		}
	}()
	if c.First == nil || s.run("Welcome", c.First) {
		s.header = c.Header()
		s.list(c.Items(), "")
	}
	leave()
	u.Out, u.Margin = real, 0
	if s.restart != "" {
		// The same terminal and the same name it was started by, so the new copy opens where this one was.
		err := syscall.Exec(s.restart, []string{os.Args[0]}, os.Environ())
		fmt.Fprintln(real, "  Could not start the new version ("+err.Error()+").")
	}
	for _, l := range s.farewell {
		fmt.Fprintln(real, l)
	}
	return 0
}
