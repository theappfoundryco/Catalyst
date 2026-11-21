#!/usr/bin/env python3
"""Open every row of the list in a real pseudo-terminal and print each screen as a person would see it.

Usage: screens.py CATALYST [COLS ROWS]

It only opens screens and goes back, so it changes nothing. It fails when a screen shows a stack trace, when a screen
other than home loses its way back, or when the list does not come back after Esc. CI runs it on macOS, where nobody
on the project can look at the screens by hand. It needs pyte, which draws the terminal in memory.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

import pyte

binary = sys.argv[1]
cols, rows = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (100, 45)
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
KEYS = {"down": b"\x1b[B", "up": b"\x1b[A", "enter": b"\r", "esc": b"\x1b"}


class Term:
    def __init__(self):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({"TERM": "xterm-256color", "COLUMNS": str(cols), "LINES": str(rows)})
            os.execv(binary, [binary])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def press(self, *keys, wait=2.5):
        for k in keys:
            os.write(self.fd, KEYS.get(k, k.encode()))
            self.pump(0.3)
        self.pump(wait)

    def lines(self):
        return [l.rstrip() for l in self.screen.display]

    def settle(self, limit=90):
        """Wait while a spinner shows, as a long step (measuring, a checkup) draws one until it is done."""
        end = time.time() + limit
        while time.time() < end and any(c in "\n".join(self.lines()) for c in SPINNER):
            self.pump(0.5)
        self.pump(0.5)

    def close(self):
        try:
            for _ in range(2):
                os.write(self.fd, b"\x03")
                self.pump(0.4)
        except OSError:
            pass  # it has already exited


def show(title, lines):
    print("=====", title)
    for l in lines:
        if l.strip():
            print(l)


def row_names(lines):
    """The labels of the home list: the lines between the header and the key bar that start with a label column."""
    names = []
    for l in lines:
        body = l[4:]
        if l[:4].strip() in ("", "▌") and body[:1].isalpha() and "  " in body:
            names.append(body.split("  ")[0].strip())
    return names


problems = []
t = Term()
t.pump(4)
home = t.lines()
show("home", home)
names = row_names(home)
if "Doctor" not in names:
    problems.append("the home list did not show (rows found: %s)" % names)
def current(lines):
    """The row the cursor is on."""
    for l in lines:
        if l[:4].strip() == "▌" and l[4:5].isalpha():
            return l[4:].split("  ")[0].strip()
    return ""


opened = set()
for _ in names:
    name = current(t.lines())
    if not name or name in opened:
        break  # back at the top: every row that can open has been opened
    opened.add(name)
    t.press("enter", wait=2)
    t.settle()
    screen = t.lines()
    show(name, screen)
    text = "\n".join(screen)
    if "goroutine " in text or "panic:" in text:
        problems.append(name + ": a stack trace")
    bar = [l for l in screen if l.strip()][-1]
    if "back" not in bar and "cancel" not in bar:
        problems.append(name + ": the key bar has no way back: " + bar.strip())
    t.press("esc")
    t.settle()
    if current(t.lines()) != name:
        problems.append(name + ": Esc did not return to the list")
        show("after Esc from " + name, t.lines())
        break
    t.press("down", wait=0.5)
missing = [n for n in names if n not in opened and n != "Undo"]
if missing:
    problems.append("never reached: " + ", ".join(missing))
t.close()
for p in problems:
    print("PROBLEM", p)
sys.exit(1 if problems else 0)
