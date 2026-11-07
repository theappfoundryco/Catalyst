package session

import (
	"io"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"
)

// screen keeps a copy of what a command printed, as the lines a person saw. The session draws on the terminal's
// separate screen, which keeps no history, so a result taller than the window can only be scrolled from this copy.
//
// It understands only what Catalyst itself writes: text, colour, carriage returns that redraw a spinner, and the
// cursor-up and clear codes a menu uses to redraw itself. Anything else is dropped.
type screen struct {
	mu      sync.Mutex
	lines   []string
	row     int
	cr      bool // a carriage return happened, so the next text replaces the line
	esc     []byte
	inEsc   bool
	partial []byte      // the start of a character split across two writes
	marks   map[int]int // row id to the line it was printed on, from ui.Mark
}

func newScreen() *screen { return &screen{lines: []string{""}, marks: map[int]int{}} }

func (s *screen) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := append(s.partial, p...)
	s.partial = nil
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case s.inEsc:
			s.esc = append(s.esc, c)
			i++
			if len(s.esc) == 1 && c != '[' { // not a sequence this understands
				s.inEsc, s.esc = false, nil
				continue
			}
			if len(s.esc) > 1 && c >= 0x40 && c <= 0x7e {
				s.sequence(string(s.esc[1:len(s.esc)-1]), c)
				s.inEsc, s.esc = false, nil
			}
			continue
		case c == 27:
			s.inEsc, s.esc = true, nil
		case c == '\r':
			s.cr = true
		case c == '\n':
			s.row++
			s.cr = false
			for len(s.lines) <= s.row {
				s.lines = append(s.lines, "")
			}
		default:
			if !utf8.FullRune(b[i:]) {
				s.partial = append([]byte{}, b[i:]...)
				return len(p), nil
			}
			_, n := utf8.DecodeRune(b[i:])
			s.text(string(b[i : i+n]))
			i += n
			continue
		}
		i++
	}
	return len(p), nil
}

func (s *screen) text(t string) {
	if s.cr {
		s.lines[s.row] = ""
		s.cr = false
	}
	s.lines[s.row] += t
}

func (s *screen) sequence(params string, final byte) {
	n, err := strconv.Atoi(params)
	if err != nil || n < 1 {
		n = 1
	}
	switch final {
	case 'm': // colour stays with the text
		s.text("\033[" + params + "m")
	case 'K':
		if s.cr || params == "2" {
			s.lines[s.row] = ""
		}
	case 'A':
		s.row -= n
		if s.row < 0 {
			s.row = 0
		}
	case 'J':
		s.lines = s.lines[:s.row+1]
		if s.cr {
			s.lines[s.row] = ""
		}
	case 'z': // ui.Mark: remember the line, draw nothing
		if id, ok := strings.CutSuffix(params, ";7770"); ok {
			if n, err := strconv.Atoi(id); err == nil {
				s.marks[n] = s.row
			}
		}
	}
}

// Lines is the result as shown, without blank lines at either end.
func (s *screen) Lines() []string {
	l, _ := s.Page()
	return l
}

// Page is the result as shown, and the line each marked row ended up on.
func (s *screen) Page() ([]string, map[int]int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := append([]string{}, s.lines...)
	for len(out) > 0 && strings.TrimSpace(stripped(out[len(out)-1])) == "" {
		out = out[:len(out)-1]
	}
	skip := 0
	for len(out) > 0 && strings.TrimSpace(stripped(out[0])) == "" {
		out = out[1:]
		skip++
	}
	marks := map[int]int{}
	for id, line := range s.marks {
		if line-skip >= 0 && line-skip < len(out) {
			marks[id] = line - skip
		}
	}
	return out, marks
}

func stripped(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == 27 {
			for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e && s[i] != '[') {
				i++
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// tee writes to the terminal and to the copy, and still reports the terminal underneath, so its size can be read.
type tee struct {
	term io.Writer
	copy io.Writer
	mute bool // measuring again behind the screen that shows: only the copy hears it
}

var markCode = regexp.MustCompile(`\x1b\[\d+;7770z`)

func (t *tee) Write(p []byte) (int, error) {
	t.copy.Write(p)
	if t.mute {
		return len(p), nil
	}
	if _, err := t.term.Write(markCode.ReplaceAll(p, nil)); err != nil { // marks are for the copy only
		return 0, err
	}
	return len(p), nil
}

func (t *tee) Fd() uintptr {
	if f, ok := t.term.(interface{ Fd() uintptr }); ok {
		return f.Fd()
	}
	return ^uintptr(0)
}
