// Package session is bare `catalyst`: an inline prompt on your normal scrollback, never a full-screen takeover.
// It only ever draws below the cursor, so whatever a command prints stays in your terminal's history.
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

// Command is one entry in the list.
type Command struct{ Name, Help string }

// Welcome is what shows beside Kit.
type Welcome struct{ Lines []string }

// Config is everything a session needs.
type Config struct {
	UI       *ui.UI
	Commands []Command
	Welcome  Welcome
	Run      func(args []string) int
}

// Editor is the prompt's text and selection. It holds no terminal, so it can be tested with plain key names.
type Editor struct {
	Commands []Command
	Text     string
	Sel      int
}

// Matches lists commands fitting what has been typed. Once an argument is being typed the list closes.
func (e *Editor) Matches() []Command {
	if strings.Contains(strings.TrimLeft(e.Text, "/ "), " ") {
		return nil
	}
	want := strings.ToLower(strings.TrimLeft(e.Text, "/ "))
	var out []Command
	for _, c := range e.Commands {
		if strings.HasPrefix(c.Name, want) {
			out = append(out, c)
		}
	}
	return out
}

// Result of a key press.
const (
	Keep = iota
	Submit
	Quit
)

// Key applies one key.
func (e *Editor) Key(k string) int {
	m := e.Matches()
	switch k {
	case "enter":
		return Submit
	case "ctrl-c", "ctrl-d":
		return Quit
	case "esc", "ctrl-u":
		e.Text, e.Sel = "", 0
	case "up":
		if e.Sel > 0 {
			e.Sel--
		}
	case "down":
		if e.Sel < len(m)-1 {
			e.Sel++
		}
	case "tab":
		if len(m) > 0 && e.Sel < len(m) {
			e.Text = m[e.Sel].Name + " "
			e.Sel = 0
		}
	case "backspace":
		if r := []rune(e.Text); len(r) > 0 {
			e.Text = string(r[:len(r)-1])
			e.Sel = 0
		}
	case "", "left", "right":
	default:
		if []rune(k)[0] >= 32 {
			e.Text += k
			e.Sel = 0
		}
	}
	return Keep
}

// Line is what should run for the current text. Enter on a partial word runs the highlighted command.
func (e *Editor) Line() string {
	t := strings.TrimSpace(strings.TrimLeft(e.Text, "/ "))
	if t == "" || strings.Contains(t, " ") {
		return t
	}
	if m := e.Matches(); len(m) > 0 && e.Sel < len(m) {
		return m[e.Sel].Name
	}
	return t
}

func frameLines(u *ui.UI, c Config, e *Editor, mood string, showWelcome bool) []string {
	cols := u.Width()
	var out []string
	if showWelcome {
		art := []string{}
		w := 0
		if u.Mascot && cols >= 60 {
			art, w = kit.Render(mood, u.Truecolor), kit.Width(mood)
		}
		rows := len(art)
		if len(c.Welcome.Lines) > rows {
			rows = len(c.Welcome.Lines)
		}
		top := rows - len(c.Welcome.Lines) // the text sits beside Kit's feet, the same as when the session scrolls on
		if top > 1 {
			top = 1
		}
		for i := 0; i < rows; i++ {
			left := strings.Repeat(" ", w)
			if i < len(art) {
				left = art[i]
			}
			right := ""
			if j := i - top; j >= 0 && j < len(c.Welcome.Lines) {
				right = c.Welcome.Lines[j]
			}
			gap := "   "
			if w == 0 {
				gap = ""
			}
			out = append(out, "  "+left+gap+ui.Fit(right, cols-w-6))
		}
		out = append(out, "")
	}
	ruleW := cols - 4
	if ruleW > 60 {
		ruleW = 60
	}
	rule := "  " + u.Rule(ruleW)
	out = append(out, rule)
	prompt := "  " + u.Cyan("›") + " " + u.Bold(e.Text)
	if e.Text == "" {
		prompt += u.Dim("type a command")
	} else {
		if m := e.Matches(); len(m) > 0 && e.Sel < len(m) {
			want := strings.TrimLeft(e.Text, "/ ")
			prompt += u.Dim(strings.TrimPrefix(m[e.Sel].Name, want))
		}
	}
	out = append(out, ui.Fit(prompt, cols-1))
	out = append(out, rule)
	const maxRows = 8
	m := e.Matches()
	start := 0
	if e.Sel >= maxRows {
		start = e.Sel - maxRows + 1
	}
	for i := start; i < len(m) && i < start+maxRows; i++ {
		line := fmt.Sprintf("%-10s %s", m[i].Name, m[i].Help)
		if i == e.Sel {
			out = append(out, "  "+u.Cyan(ui.Fit(fmt.Sprintf("%-10s", m[i].Name), 10))+" "+ui.Fit(m[i].Help, cols-16))
		} else {
			out = append(out, "  "+u.Dim(ui.Fit(line, cols-4)))
		}
	}
	out = append(out, "  "+u.Dim(ui.Fit("↑ ↓ move   Tab complete   Enter run   Ctrl-C leave", cols-4)))
	return out
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

// Run is the session loop. It returns the exit code to leave with.
func Run(c Config) int {
	u := c.UI
	fd := int(u.In.Fd())
	e := &Editor{Commands: c.Commands}
	welcome := true
	u.Blank()
	for {
		old, err := term.MakeRaw(fd)
		if err != nil {
			return 1
		}
		fmt.Fprint(u.Out, "\033[?25l")
		drawn, frame := 0, 0
		mood := func() string {
			switch {
			case !welcome:
				return kit.Idle
			case frame%14 == 9: // a blink every so often
				return kit.Blink
			case frame%2 == 1:
				return kit.Wag
			}
			return kit.Idle
		}
		draw := func() {
			if drawn > 0 {
				fmt.Fprintf(u.Out, "\033[%dA", drawn)
			}
			lines := frameLines(u, c, e, mood(), welcome)
			for _, l := range lines {
				fmt.Fprint(u.Out, "\r\033[2K"+l+"\r\n")
			}
			fmt.Fprint(u.Out, "\033[J")
			drawn = len(lines)
		}
		draw()
		result := Keep
		last := time.Now()
		for result == Keep {
			got, err := waitKey(fd, u.In, 100*time.Millisecond)
			if err != nil {
				result = Quit
				break
			}
			for _, k := range split(got) {
				if result = e.Key(k); result != Keep {
					break
				}
			}
			if len(got) > 0 {
				draw()
			}
			if welcome && u.Mascot && time.Since(last) >= 420*time.Millisecond {
				frame++
				last = time.Now()
				draw()
			}
		}
		// Clear the live block, so scrollback keeps only what actually happened.
		fmt.Fprintf(u.Out, "\033[%dA\r\033[J", drawn)
		fmt.Fprint(u.Out, "\033[?25h")
		term.Restore(fd, old)
		if result == Quit {
			return 0
		}
		line := e.Line()
		e.Text, e.Sel = "", 0
		if line == "" {
			continue
		}
		if line == "exit" || line == "quit" || line == "q" {
			return 0
		}
		if welcome {
			staticWelcome(u, c)
			welcome = false
		}
		fmt.Fprintln(u.Out, "  "+u.Cyan("›")+" "+u.Bold(line))
		c.Run(strings.Fields(line))
		fmt.Fprintln(u.Out)
	}
}

func staticWelcome(u *ui.UI, c Config) {
	u.Beside(kit.Idle, c.Welcome.Lines)
	u.Blank()
}

// split turns one read into keys. A paste arrives as one long read, and an arrow arrives as three bytes that belong together.
func split(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	if b[0] == 27 {
		return []string{ui.ReadKey(b)}
	}
	var out []string
	for _, r := range string(b) {
		s := string(r)
		if r < 32 || r == 127 {
			s = ui.ReadKey([]byte{byte(r)})
		}
		out = append(out, s)
	}
	return out
}
