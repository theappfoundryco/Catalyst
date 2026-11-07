package ui

import (
	"fmt"
	"strconv"
	"strings"
)

// The palette. Each colour has a plain fallback for terminals with only 16 colours, and none at all without colour.
// Blue is Kit's, used for whatever is chosen or worth reading twice. Orange is "look at this", never "broken".

// Faint is for structure: rules, column headings, the tree line under a row.
func (u *UI) Faint(s string) string { return u.grey(s) }

// Accent is Kit's blue.
func (u *UI) Accent(s string) string {
	if u.Color && u.Colors256 {
		return u.wrap("38;5;75", s)
	}
	return u.Cyan(s)
}

// Orange marks something worth a look.
func (u *UI) Orange(s string) string {
	if u.Color && u.Colors256 {
		return u.wrap("38;5;214", s)
	}
	return u.Yellow(s)
}

// Soft is a quiet green for explanations and good news that does not need shouting.
func (u *UI) Soft(s string) string {
	if u.Color && u.Colors256 {
		return u.wrap("38;5;108", s)
	}
	return u.Dim(s)
}

// Chip draws a key as a small key cap: " ⏎ " on a raised grey. Without colour it is [⏎].
func (u *UI) Chip(k string) string {
	switch {
	case u.Color && u.Colors256:
		return "\033[48;5;238;38;5;255;1m " + k + " \033[0m"
	case u.Color:
		return "\033[7m " + k + " \033[0m"
	}
	return "[" + k + "]"
}

// KeyHints lays out key caps with what each does: KeyHints("↑↓", "move", "⏎", "open").
func (u *UI) KeyHints(pairs ...string) string {
	var b []string
	for i := 0; i+1 < len(pairs); i += 2 {
		b = append(b, u.Chip(pairs[i])+" "+u.Dim(pairs[i+1]))
	}
	return strings.Join(b, "    ")
}

// Wide is how wide rules and highlighted rows are: the window, up to a width that still reads as one block.
func (u *UI) Wide() int {
	w := u.Width() - 4
	if w > 66 {
		w = 66
	}
	if w < 10 {
		w = 10
	}
	return w
}

// KeyBar is the bottom of every screen: a thin rule, then the keys. A key bar that would not fit drops its last keys,
// so the first ones, the ones that matter, always show.
func (u *UI) KeyBar(pairs ...string) []string {
	for len(pairs) > 2 && Visible(u.KeyHints(pairs...)) > u.Width()-3 {
		pairs = pairs[:len(pairs)-2]
	}
	return []string{"  " + u.Faint(strings.Repeat("─", u.Wide())), "  " + u.KeyHints(pairs...)}
}

// Notice replaces the keys for a moment, as in "Press Ctrl-C again to exit".
func (u *UI) Notice(s string) []string {
	return []string{"  " + u.Faint(strings.Repeat("─", u.Wide())), "  " + u.Orange(s)}
}

// Band is the chosen row: a soft dark band with a blue edge, so it reads at a glance. Colour codes inside the row would
// end the band early, so the band is put back after each one. Without 256 colours it is a plain arrow.
func (u *UI) Band(row string, width int) string {
	if !(u.Color && u.Colors256) {
		return u.Cyan("›") + " " + row
	}
	const bg = "\033[48;5;236m"
	pad := width - 2 - Visible(row)
	if pad < 0 {
		pad = 0
	}
	inner := strings.ReplaceAll(row, "\033[0m", "\033[0m"+bg)
	return bg + "\033[38;5;75m▌\033[0m" + bg + " " + inner + strings.Repeat(" ", pad) + "\033[0m"
}

// Dot is a filled or hollow circle, for ticked and unticked, or open and closed.
func (u *UI) Dot(on bool) string {
	if on {
		return u.Green("●")
	}
	return u.Faint("○")
}

// Mark tags the line it is printed on as row id, so the session can put a cursor on it and offer that row's keys. It is
// an escape code that no terminal draws, and it is only written while a session is reading, so a pipe never sees it.
func (u *UI) Mark(id int) string {
	if !u.Marks {
		return ""
	}
	return "\033[" + strconv.Itoa(id) + ";7770z"
}

// The five health levels, from a clean bill to trouble, each with its colour at full and at its dimmest.
var levels = []struct {
	min                int
	bright, dim        [3]int
	c256, c256dim, c16 string
	period             float64 // seconds per breath: calm when healthy, quicker when not
}{
	{90, [3]int{80, 220, 100}, [3]int{20, 70, 30}, "38;5;41", "38;5;22", "32", 2.2},
	{75, [3]int{170, 220, 60}, [3]int{55, 72, 20}, "38;5;148", "38;5;64", "32", 2.0},
	{60, [3]int{240, 210, 60}, [3]int{80, 70, 20}, "38;5;220", "38;5;136", "33", 1.6},
	{40, [3]int{255, 140, 40}, [3]int{90, 45, 10}, "38;5;208", "38;5;130", "33", 1.2},
	{0, [3]int{240, 70, 60}, [3]int{85, 20, 18}, "38;5;196", "38;5;88", "31", 0.8},
}

func level(score int) int {
	for i, l := range levels {
		if score >= l.min {
			return i
		}
	}
	return len(levels) - 1
}

// Breath is how long one pulse of the health dot takes for a score.
func Breath(score int) float64 { return levels[level(score)].period }

// HealthDot is the dot beside the health score. glow runs from 0, dimmest, to 1, brightest, so a caller can make it
// breathe. A score below zero means no checkup yet: a still, hollow grey dot.
func (u *UI) HealthDot(score int, glow float64) string {
	if score < 0 {
		return u.Faint("○")
	}
	if !u.Color {
		return "●"
	}
	l := levels[level(score)]
	switch {
	case u.Truecolor:
		c := [3]int{}
		for i := range c {
			c[i] = l.dim[i] + int(float64(l.bright[i]-l.dim[i])*glow)
		}
		return fmt.Sprintf("\033[38;2;%d;%d;%dm●\033[0m", c[0], c[1], c[2])
	case u.Colors256:
		if glow < 0.5 {
			return "\033[" + l.c256dim + "m●\033[0m"
		}
		return "\033[" + l.c256 + "m●\033[0m"
	}
	return "\033[" + l.c16 + "m●\033[0m"
}

// Warning draws a full-width warning box, for the screens where a wrong step can hurt the machine.
func (u *UI) Warning(title string, lines ...string) {
	w := u.Wide()
	edge := func(s string) string {
		if u.Color && u.Colors256 {
			return "\033[38;5;214m" + s + "\033[0m"
		}
		return u.Yellow(s)
	}
	u.line("  " + edge("┌"+strings.Repeat("─", w-2)+"┐"))
	row := func(s string) {
		for _, l := range u.Wrap(s, w-4) {
			pad := w - 4 - Visible(l)
			if pad < 0 {
				pad = 0
			}
			u.line("  " + edge("│") + " " + l + strings.Repeat(" ", pad) + " " + edge("│"))
		}
	}
	row(u.Bold(edge("⚠  " + title)))
	for _, l := range lines {
		row(l)
	}
	u.line("  " + edge("└"+strings.Repeat("─", w-2)+"┘"))
}
