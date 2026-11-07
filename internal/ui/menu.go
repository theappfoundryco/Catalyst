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
	view := rows - 8
	if roomy {
		view = rows - 13
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
	longest := 0
	for _, it := range m.Items {
		if n := Visible(it.Label); n > longest {
			longest = n
		}
	}
	var out []string
	for j := 0; j < view && m.top+j < len(m.Items); j++ {
		i := m.top + j
		it := m.Items[i]
		mark := u.Dim("[ ]")
		if it.Picked {
			mark = "[" + u.Green("x") + "]"
		}
		lead := "    "
		label := it.Label
		if i == m.cur {
			lead = "  " + u.Cyan("›") + " "
			label = u.Bold(label)
		}
		avail := cols - 9 - Visible(it.Right) - 3
		if avail > longest { // sizes sit beside the names, not far off at the window's edge
			avail = longest
		}
		if avail < 12 {
			avail = 12
		}
		label = Fit(label, avail)
		if i == m.cur && Visible(label) < Visible(it.Label) {
			label = u.Bold(label)
		}
		pad := avail - Visible(label)
		if pad < 0 {
			pad = 0
		}
		row := lead + mark + " " + label + strings.Repeat(" ", pad) + "   " + u.Dim(it.Right)
		out = append(out, Fit(row, cols-1))
	}
	about := m.Items[m.cur].About
	if len(m.Items) > view {
		about += fmt.Sprintf("  (%d of %d, more with ↑ ↓)", m.cur+1, len(m.Items))
	}
	gap := func() {
		if roomy {
			out = append(out, "")
		}
	}
	gap()
	out = append(out, "      "+u.Dim(Fit(about, cols-8)))
	gap()
	n, total := m.picked()
	if n == 0 {
		out = append(out, "  "+u.Bold("Nothing selected"))
	} else {
		out = append(out, "  "+u.Bold(fmt.Sprintf("Selected: %s, about %s", Count(n, m.Noun, m.Nouns), Size(total))))
	}
	if m.Note != "" && roomy {
		out = append(out, "  "+u.Dim(Fit(m.Note, cols-3)))
	}
	gap()
	cancel := m.Cancel
	if cancel == "" {
		cancel = "cancel"
	}
	out = append(out, "  "+u.Dim(Fit(fmt.Sprintf("↑ ↓ move   Space select   a all or none   Enter %s   Esc %s", m.Action, cancel), cols-3)))
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
		m.Items[m.cur].Picked = !m.Items[m.cur].Picked
	case "a", "A":
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
		return true
	case "q", "esc", "ctrl-c":
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
