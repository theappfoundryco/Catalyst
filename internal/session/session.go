// Package session is bare `catalyst`: one list you move through with the arrow keys, and Enter opens what is highlighted.
// There is nothing to type here. Anything with arguments belongs in the shell, as `catalyst ports kill 3000`.
//
// Every screen clears the window the way the homelab installer does, so earlier output is one scroll away. This is also
// the only place Kit appears: at the top of the home screen, once.
package session

import (
	"errors"
	"fmt"
	"os"
	"strings"
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
	Gap        bool // a blank row above it
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
	SkipWait bool // nothing worth reading: go straight back
	Quit     bool // the program is gone or replaced: leave, with the last words still on screen
}

// Config is everything a session needs.
type Config struct {
	UI     *ui.UI
	Items  []Item
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

// Key applies one key.
func (p *Picker) Key(k string) int {
	n := len(p.Items)
	switch k {
	case "up", "k":
		if n > 0 {
			p.Cur = (p.Cur + n - 1) % n
		}
	case "down", "j":
		if n > 0 {
			p.Cur = (p.Cur + 1) % n
		}
	case "enter":
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
		if i == p.Cur {
			at = len(out)
			out = append(out, strings.TrimRight("  "+u.Cyan("›")+" "+u.Head(name)+"  "+help, " "))
		} else {
			out = append(out, strings.TrimRight("    "+name+"  "+u.Dim(help), " "))
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
func frame(u *ui.UI, p *Picker, top func(withKit bool) []string, keys string, cols, rows int) []string {
	if rows <= 0 {
		rows = 24
	}
	list, at := p.rows(u, cols)
	foot := []string{"", "  " + u.Dim(ui.Fit(keys, cols-3))}
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
	c      Config
	u      *ui.UI
	fd     int
	final  bool // a command said the program is finished, so its last words stay on screen
	header Header
}

func (s *runner) clear()      { fmt.Fprint(s.u.Out, "\033[H\033[2J") }
func (s *runner) hideCursor() { fmt.Fprint(s.u.Out, "\033[?25l") }
func (s *runner) showCursor() { fmt.Fprint(s.u.Out, "\033[?25h") }

// keys waits for input in raw mode, running tick while it waits. A closed keyboard reads as Ctrl-D, so nothing spins forever.
func (s *runner) keys(tick func()) []string {
	old, err := term.MakeRaw(s.fd)
	if err != nil {
		return []string{"ctrl-d"}
	}
	defer term.Restore(s.fd, old)
	for {
		got, err := waitKey(s.fd, s.u.In, 100*time.Millisecond)
		if err != nil {
			return []string{"ctrl-d"}
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
	fmt.Fprint(s.u.Out, b.String())
}

// list shows one list until the person leaves it. It returns false when the whole session should end.
func (s *runner) list(items []Item, title string) bool {
	u := s.u
	p := &Picker{Items: items}
	home := title == ""
	keys := "↑ ↓ move   Enter open   Esc back"
	if home {
		keys = "↑ ↓ move   Enter open   q quit"
	}
	frameNo := 0
	lastMove := time.Now()
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
		s.paint(frame(u, p, top, keys, cols, rows))
	}
	s.clear()
	s.hideCursor()
	draw()
	for {
		tick := func() {
			if c, r := u.Width(), u.Height(); c != cols || r != rows {
				cols, rows = c, r
				s.clear()
				draw()
				return
			}
			if home && u.Mascot && (s.header.Mood == "" || s.header.Mood == kit.Idle) && time.Since(lastMove) >= 420*time.Millisecond {
				frameNo++
				lastMove = time.Now()
				draw()
			}
		}
		for _, k := range s.keys(tick) {
			switch p.Key(k) {
			case Quit:
				return false
			case Leave:
				return !home
			case Back:
				if !home {
					return true
				}
			case Open:
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
				cols, rows = u.Width(), u.Height()
				s.clear()
				s.hideCursor()
			}
		}
		draw()
	}
}

// run clears the window, runs one command, and waits on its result. It returns false when the session should end.
func (s *runner) run(name string, args []string) bool {
	u := s.u
	for {
		s.clear()
		s.showCursor() // a command may ask a question, and a person should see where they are typing
		u.Title(name)
		out := s.c.Run(args)
		if out.Quit {
			s.final = true
			return false
		}
		if out.SkipWait {
			return true
		}
		bits := []string{}
		for _, a := range out.Actions {
			bits = append(bits, a.Key+" "+a.Label)
		}
		bits = append(bits, "Enter back", "q quit")
		u.Blank()
		u.Say("  " + u.Dim(strings.Join(bits, "   ")))
		s.hideCursor()
		s.drain()
		next, quit := s.wait(out.Actions)
		if quit {
			return false
		}
		if next == nil {
			return true
		}
		name, args = next.Title, next.Args
	}
}

// wait blocks on the keys under a result. It returns the action chosen (nil to go back), or true to end the session.
func (s *runner) wait(actions []Action) (*Action, bool) {
	for {
		for _, k := range s.keys(nil) {
			switch k {
			case "enter", "esc", "left":
				return nil, false
			case "q", "Q", "ctrl-c", "ctrl-d":
				return nil, true
			}
			for i := range actions {
				if k == actions[i].Key {
					return &actions[i], false
				}
			}
		}
	}
}

// Run is the session. It returns the exit code to leave with.
func Run(c Config) int {
	u := c.UI
	u.Out = ui.Squeeze(u.Out) // commands each open and close with a blank line; on one screen, one is enough
	s := &runner{c: c, u: u, fd: int(u.In.Fd()), header: c.Header()}
	defer s.showCursor()
	s.list(c.Items, "")
	if s.final {
		return 0
	}
	s.clear()
	u.Say("  " + u.Dim("Catalyst closed. Everything also runs directly, like: catalyst doctor"))
	u.Blank()
	return 0
}
