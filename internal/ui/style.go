package ui

import (
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
