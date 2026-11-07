package ui

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/term"
)

// Item is one row in a menu.
type Item struct {
	Label  string
	Right  string // short dim text after the label
	About  string // shown under the list for the row the cursor is on
	Size   int64
	Picked bool
}

// Menu is an arrow-key checklist with a running total.
type Menu struct {
	Items     []Item
	Noun      string // "folder"
	Nouns     string // "folders"
	Action    string // "sweep"
	Note      string // one line under the total
	Cancel    string // what the Esc key is called at the bottom; "cancel" unless set
	Single    bool   // pick one row with Enter, instead of ticking several
	Chosen    int    // with Single: the row picked
	cur, top  int
	cancelled bool
}

func (m *Menu) picked() (n int, total int64) {
	for _, it := range m.Items {
		if it.Picked {
			n++
			total += it.Size
		}
	}
	return
}

// frame builds every row of the menu. Keeping it free of terminal calls makes it testable at any size.
func (m *Menu) frame(u *UI, cols, rows int) []string {
	// A roomy window gets spaces between the parts. A title may sit above the menu, so that is counted too.
	roomy := rows >= 18
	view := rows - 9
	if roomy {
		view = rows - 14
	}
	if view > len(m.Items) {
		view = len(m.Items)
	}
	if view < 1 {
		view = 1
	}
	if m.cur < m.top {
		m.top = m.cur
	}
	if m.cur >= m.top+view {
		m.top = m.cur - view + 1
	}
	longest, sized := 0, false
	for _, it := range m.Items {
		if n := Visible(it.Label); n > longest {
			longest = n
		}
		sized = sized || it.Size > 0
	}
	sizeW := 0
	if sized {
		sizeW = 8
	}
	var out []string
	for j := 0; j < view && m.top+j < len(m.Items); j++ {
		i := m.top + j
		it := m.Items[i]
		mark := ""
		if !m.Single {
			mark = u.Dot(it.Picked) + " "
		}
		avail := cols - 10 - sizeW - Visible(it.Right) - 3
		if avail > longest { // sizes sit beside the names, not far off at the window's edge
			avail = longest
		}
		if avail < 12 {
			avail = 12
		}
		label := Fit(it.Label, avail)
		label += strings.Repeat(" ", max(0, avail-Visible(label)))
		size := ""
		if sized {
			size = fmt.Sprintf("%8s", Size(it.Size))
		}
		right := ""
		if it.Right != "" {
			right = "   " + u.Faint(it.Right)
		}
		if i == m.cur {
			out = append(out, Fit("  "+u.Band(mark+u.Bold(label)+size+right, u.Wide()), cols-1))
		} else {
			out = append(out, Fit("    "+mark+label+u.Dim(size)+right, cols-1))
		}
	}
	about := m.Items[m.cur].About
	if len(m.Items) > view {
		about += fmt.Sprintf("  (%d of %d)", m.cur+1, len(m.Items))
	}
	gap := func() {
		if roomy {
			out = append(out, "")
		}
	}
	gap()
	out = append(out, "     "+u.Soft(Fit(about, cols-7)))
	gap()
	if !m.Single {
		n, total := m.picked()
		sum := u.Bold("Nothing selected")
		if n > 0 {
			sum = u.Bold(fmt.Sprintf("%d selected", n)) + u.Faint("  ·  ") + u.Accent(u.Bold("about "+Size(total)))
		}
		if m.Note != "" && Visible(sum)+5+Visible(m.Note) <= cols-3 {
			out = append(out, "  "+sum+u.Faint("  ·  ")+u.Dim(m.Note))
		} else {
			out = append(out, "  "+sum)
			if m.Note != "" && roomy {
				out = append(out, "  "+u.Dim(Fit(m.Note, cols-3)))
			}
		}
	}
	gap()
	cancel := m.Cancel
	if cancel == "" {
		cancel = "cancel"
	}
	keys := u.KeyBar("↑↓", "move", "space", "select", "a", "all", "⏎", m.Action, "esc", cancel)
	if m.Single {
		keys = u.KeyBar("↑↓", "move", "⏎", m.Action, "esc", cancel)
	}
	return oneBlank(append(out, keys...))
}

// oneBlank drops a blank line that follows another. The session prints through Squeeze, which would drop it anyway, and
// a redraw that counts lines the terminal never got draws each frame one line lower than the last.
func oneBlank(lines []string) []string {
	out := lines[:0]
	for i, l := range lines {
		if l == "" && i > 0 && lines[i-1] == "" {
			continue
		}
		out = append(out, l)
	}
	return out
}

// key applies one key press. It returns true when the menu is finished.
func (m *Menu) key(k string) bool {
	switch k {
	case "up", "k":
		m.cur = (m.cur + len(m.Items) - 1) % len(m.Items)
	case "down", "j":
		m.cur = (m.cur + 1) % len(m.Items)
	case " ", "x":
		if !m.Single {
			m.Items[m.cur].Picked = !m.Items[m.cur].Picked
		}
	case "a", "A":
		if m.Single {
			break
		}
		all := true
		for _, it := range m.Items {
			if it.Picked {
				all = false
			}
		}
		for i := range m.Items {
			m.Items[i].Picked = all
		}
	case "enter":
		m.Chosen = m.cur
		return true
	case "q", "esc", "ctrl-c", "ctrl-d":
		m.cancelled = true
		return true
	}
	return false
}

// ReadKey turns one read from a raw terminal into a key name.
func ReadKey(buf []byte) string {
	switch {
	case len(buf) == 0:
		return ""
	case len(buf) >= 3 && buf[0] == 27 && (buf[1] == '[' || buf[1] == 'O'):
		switch buf[2] {
		case 'A':
			return "up"
		case 'B':
			return "down"
		case 'C':
			return "right"
		case 'D':
			return "left"
		case 'H':
			return "home"
		case 'F':
			return "end"
		case '5', '6':
			if len(buf) >= 4 && buf[3] == '~' {
				return map[byte]string{'5': "pgup", '6': "pgdn"}[buf[2]]
			}
		}
		return ""
	case buf[0] == 27:
		return "esc"
	case buf[0] == 13 || buf[0] == 10:
		return "enter"
	case buf[0] == 3:
		return "ctrl-c"
	case buf[0] == 4:
		return "ctrl-d"
	case buf[0] == 9:
		return "tab"
	case buf[0] == 21:
		return "ctrl-u"
	case buf[0] == 127 || buf[0] == 8:
		return "backspace"
	}
	return string(buf)
}

// Keys splits one read into key names. Holding an arrow delivers several at once, and each one has to count.
func Keys(b []byte) []string {
	var out []string
	for i := 0; i < len(b); {
		if b[i] == 27 && i+1 < len(b) && (b[i+1] == '[' || b[i+1] == 'O') {
			j := i + 2
			for j < len(b) && (b[j] < 0x40 || b[j] > 0x7e) {
				j++
			}
			if j == len(b) {
				break
			}
			if k := ReadKey(b[i : j+1]); k != "" {
				out = append(out, k)
			}
			i = j + 1
			continue
		}
		r, n := utf8.DecodeRune(b[i:])
		if k := ReadKey(b[i : i+n]); k != "" && r != utf8.RuneError {
			out = append(out, k)
		}
		i += n
	}
	return out
}

// Run shows the menu and returns false when it was cancelled. Too small a window or no keyboard means
// picking by number instead, so it still works over a pipe.
func (m *Menu) Run(u *UI) bool {
	cols, rows := u.Width(), u.Height()
	if !u.TTY || !u.InTTY || !u.Color || rows < 12 || cols < 60 {
		return m.byNumber(u)
	}
	fd := int(u.In.Fd())
	old, err := term.MakeRaw(fd)
	if err != nil {
		return m.byNumber(u)
	}
	defer term.Restore(fd, old)
	fmt.Fprint(u.Out, "\033[?25l")
	defer fmt.Fprint(u.Out, "\033[?25h")
	drawn := 0
	buf := make([]byte, 64)
	for {
		cols, rows = u.Width(), u.Height()
		if drawn > 0 {
			fmt.Fprintf(u.Out, "\033[%dA", drawn)
		}
		lines := m.frame(u, cols, rows)
		for _, l := range lines {
			fmt.Fprint(u.Out, "\r\033[2K"+l+"\r\n")
		}
		drawn = len(lines)
		n, err := u.In.Read(buf)
		if err != nil {
			m.cancelled = true
			break
		}
		done := false
		for _, k := range Keys(buf[:n]) {
			if done = m.key(k); done {
				break
			}
		}
		if done {
			break
		}
	}
	fmt.Fprintf(u.Out, "\033[%dA\r\033[J", drawn) // the choice is made, so only its result stays on screen
	return !m.cancelled
}

func (m *Menu) byNumber(u *UI) bool {
	for i, it := range m.Items {
		mark := " "
		if it.Picked {
			mark = "*"
		}
		u.Say(fmt.Sprintf("  %s%3d  %s  %s", mark, i+1, it.Label, u.Dim(it.Right)))
	}
	if m.Single { // picking one thing to act on is never assumed, not even with --yes
		if !u.InTTY {
			return false
		}
		n, err := strconv.Atoi(u.prompt("Number to " + m.Action + " (Enter for none): "))
		if err != nil || n < 1 || n > len(m.Items) {
			return false
		}
		m.Chosen = n - 1
		return true
	}
	if u.Yes {
		return true
	}
	if !u.InTTY {
		for i := range m.Items {
			m.Items[i].Picked = false
		}
		return false
	}
	reply := u.prompt("Numbers to " + m.Action + ", with spaces between (Enter for the ones marked *, 0 for none): ")
	if reply == "" {
		return true
	}
	for i := range m.Items {
		m.Items[i].Picked = false
	}
	for _, f := range strings.FieldsFunc(reply, func(r rune) bool { return r == ' ' || r == ',' }) {
		if n, err := strconv.Atoi(f); err == nil && n >= 1 && n <= len(m.Items) {
			m.Items[n-1].Picked = true
		}
	}
	return true
}
