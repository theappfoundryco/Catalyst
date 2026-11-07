package ui

import (
	"fmt"
	"strconv"
	"strings"

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
	view := rows - 5
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
		row := lead + mark + " " + label + strings.Repeat(" ", pad) + "  " + u.Dim(it.Right)
		out = append(out, Fit(row, cols-1))
	}
	about := m.Items[m.cur].About
	if len(m.Items) > view {
		about += fmt.Sprintf("  (%d of %d, more with ↑ ↓)", m.cur+1, len(m.Items))
	}
	out = append(out, "      "+u.Dim(Fit(about, cols-8)))
	n, total := m.picked()
	if n == 0 {
		out = append(out, "  "+u.Bold("Nothing selected"))
	} else {
		out = append(out, "  "+u.Bold(fmt.Sprintf("Selected: %s, about %s", Count(n, m.Noun, m.Nouns), Size(total))))
	}
	out = append(out, "  "+u.Dim(Fit(fmt.Sprintf("↑ ↓ move   Space select   a all or none   Enter %s   q cancel", m.Action), cols-3)))
	return out
}

// key applies one key press. It returns true when the menu is finished.
func (m *Menu) key(k string) bool {
	switch k {
	case "up", "k":
		if m.cur > 0 {
			m.cur--
		}
	case "down", "j":
		if m.cur < len(m.Items)-1 {
			m.cur++
		}
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
	buf := make([]byte, 16)
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
		if m.key(ReadKey(buf[:n])) {
			break
		}
	}
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
