package ui

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// own is what Catalyst itself puts inside a line: colour, and the session's marks (see Mark).
var own = regexp.MustCompile(`^\x1b\[(?:[0-9;]*m|[0-9]+;7770z)`)

// Printable shows control characters as text, such as \n and \x1b, and keeps only Catalyst's own colour and marks.
// Folder names, process names and a stored name are printed as they are, and any of them can hold an escape: a folder
// in a cloned repository named to retitle the terminal, write to its clipboard or clear the screen. A newline in a
// name would also break the layout.
func Printable(s string) string {
	if !needsEscape(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] == 0x1b {
			if m := own.FindString(s[i:]); m != "" {
				b.WriteString(m)
				i += len(m)
				continue
			}
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			fmt.Fprintf(&b, `\x%02x`, s[i])
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0):
			fmt.Fprintf(&b, `\x%02x`, r)
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	return b.String()
}

// needsEscape is the quick test, so the usual line costs one pass. 0xc2 starts the C1 controls in UTF-8.
func needsEscape(s string) bool {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 || c == 0x7f || c == 0xc2 && i+1 < len(s) && s[i+1] < 0xa0 {
			return true
		}
	}
	return !utf8.ValidString(s)
}

// RuneWidth is how many columns a terminal gives r: two for Chinese, Japanese and Korean characters and most emoji,
// none for accents that sit on the letter before them.
func RuneWidth(r rune) int {
	switch {
	case r == 0x200d || unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) || (r >= 0xfe00 && r <= 0xfe0f):
		return 0
	case r >= 0x1100 && r <= 0x115f, r >= 0x2e80 && r <= 0x303e, r >= 0x3041 && r <= 0x33ff,
		r >= 0x3400 && r <= 0x4dbf, r >= 0x4e00 && r <= 0x9fff, r >= 0xa000 && r <= 0xa4cf,
		r >= 0xac00 && r <= 0xd7a3, r >= 0xf900 && r <= 0xfaff, r >= 0xfe30 && r <= 0xfe4f,
		r >= 0xff00 && r <= 0xff60, r >= 0xffe0 && r <= 0xffe6, r >= 0x1f300 && r <= 0x1f6ff,
		r >= 0x1f900 && r <= 0x1faff, r >= 0x20000 && r <= 0x3fffd:
		return 2
	}
	return 1
}

// columns is how wide plain text (no colour codes) is on screen.
func columns(s string) int {
	n := 0
	for _, r := range s {
		n += RuneWidth(r)
	}
	return n
}

// head is the start of plain text that fits in width columns.
func head(s string, width int) string {
	n := 0
	for i, r := range s {
		if n+RuneWidth(r) > width {
			return s[:i]
		}
		n += RuneWidth(r)
	}
	return s
}

// tail is the end of plain text that fits in width columns.
func tail(s string, width int) string {
	n := 0
	for i := len(s); i > 0; {
		r, size := utf8.DecodeLastRuneInString(s[:i])
		if n+RuneWidth(r) > width {
			return s[i:]
		}
		n += RuneWidth(r)
		i -= size
	}
	return s
}
