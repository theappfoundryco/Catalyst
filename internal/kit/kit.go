// Package kit draws Kit, the Catalyst cat, with half-block characters: two pixels per character cell, so pixels come out square.
package kit

import (
	"fmt"
	"strconv"
	"strings"
)

// Moods are the moods a command may ask for. Wag and blink are animation frames of idle.
const (
	Idle   = "idle"
	Doctor = "doctor"
	Scan   = "scan"
	Sweep  = "sweep"
	Happy  = "happy"
	Party  = "party"
	Alarm  = "alarm"
	Sleep  = "sleep"
	Wag    = "wag"
	Blink  = "blink"
)

func rgb(hex string) (int, int, int) {
	r, _ := strconv.ParseInt(hex[1:3], 16, 32)
	g, _ := strconv.ParseInt(hex[3:5], 16, 32)
	b, _ := strconv.ParseInt(hex[5:7], 16, 32)
	return int(r), int(g), int(b)
}

func to256(r, g, b int) int {
	step := func(v int) int { return (v*5 + 127) / 255 }
	return 16 + 36*step(r) + 6*step(g) + step(b)
}

func code(c byte, truecolor, background bool) string {
	r, g, b := rgb(Palette[c])
	layer := 38
	if background {
		layer = 48
	}
	if truecolor {
		return fmt.Sprintf("\033[%d;2;%d;%d;%dm", layer, r, g, b)
	}
	return fmt.Sprintf("\033[%d;5;%dm", layer, to256(r, g, b))
}

// Render returns the mood as terminal lines. An unknown mood draws idle.
func Render(mood string, truecolor bool) []string {
	rows, ok := Sprites[mood]
	if !ok {
		rows = Sprites[Idle]
	}
	width := len(rows[0])
	if len(rows)%2 == 1 { // the empty row goes on top, so feet stay on the baseline of the text beside Kit
		rows = append([]string{strings.Repeat(".", width)}, rows...)
	}
	lines := make([]string, 0, len(rows)/2)
	for y := 0; y+1 < len(rows); y += 2 {
		var b strings.Builder
		for x := 0; x < width; x++ {
			t, u := rows[y][x], rows[y+1][x]
			switch {
			case t == '.' && u == '.':
				b.WriteByte(' ')
			case u == '.':
				b.WriteString(code(t, truecolor, false) + "▀\033[0m")
			case t == '.':
				b.WriteString(code(u, truecolor, false) + "▄\033[0m")
			default:
				b.WriteString(code(t, truecolor, false) + code(u, truecolor, true) + "▀\033[0m")
			}
		}
		lines = append(lines, b.String())
	}
	return lines
}

// Width is how many terminal columns the mood takes.
func Width(mood string) int {
	rows, ok := Sprites[mood]
	if !ok {
		rows = Sprites[Idle]
	}
	return len(rows[0])
}
