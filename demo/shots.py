#!/usr/bin/env python3
"""Records the README images from an invented machine, on a real pseudo-terminal, so what you see is what the program draws.
  python3 -m venv .cache/venv && .cache/venv/bin/pip install pyte pillow
  .cache/venv/bin/python demo/shots.py
Mac only, for its fonts. Nothing here reads your own setup: the doctor shot uses demo/main.go, the rest use a throwaway home folder."""
import fcntl, json, os, pty, select, shutil, struct, subprocess, sys, tempfile, termios, time
import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".github", "assets")
FONT = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 24)
BOLD = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 24, index=1)
CW, CH = int(FONT.getlength("M")), 31
BG, FG = "#0f1520", "#d6dee9"
NAMED = {"red": "#ff6b70", "green": "#5fd38d", "brown": "#f2c14e", "blue": "#5aa9ff", "magenta": "#e58bf2", "cyan": "#5cc8e8", "white": FG, "black": "#000000"}


def colour(c, fallback):
    if c == "default":
        return fallback
    return NAMED.get(c, "#" + c if len(c) == 6 else fallback)


class Term:
    def __init__(self, argv, env, cols=88, rows=34):
        self.cols, self.rows = cols, rows
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(argv[0], argv, env)
        self.fd = fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                self.stream.feed(data)

    def send(self, data, seconds=0.4):
        os.write(self.fd, data)
        self.pump(seconds)

    def used_rows(self):
        last = 0
        for y, line in enumerate(self.screen.display):
            if line.strip():
                last = y
        return last + 1

    def settle(self):
        # The health dot redraws the screen ten times a second. A frame arrives in pieces within a moment of each other,
        # so a short silence means the last one is complete and the picture is whole.
        end = time.time() + 2
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.03)
            if not r:
                return
            try:
                self.stream.feed(os.read(self.fd, 65536))
            except OSError:
                return

    def save(self, name, title):
        self.settle()
        rows = self.used_rows()
        pad, bar = 28, 52
        img = Image.new("RGB", (self.cols * CW + pad * 2, rows * CH + pad * 2 + bar), BG)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, img.width, bar], fill="#171f2d")
        for i, c in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
            d.ellipse([20 + i * 26, 18, 36 + i * 26, 34], fill=c)
        d.text((104, 12), title, font=FONT, fill="#76859a")
        for y in range(rows):
            for x in range(self.cols):
                c = self.screen.buffer[y][x]
                if c.data == " " and c.bg == "default":
                    continue
                f, b = colour(c.fg, FG), colour(c.bg, None)
                X, Y = pad + x * CW, pad + bar + y * CH
                if b:
                    d.rectangle([X, Y, X + CW, Y + CH], fill=b)
                if c.data == "▀":
                    d.rectangle([X, Y, X + CW, Y + CH // 2], fill=f)
                elif c.data == "▄":
                    d.rectangle([X, Y + CH // 2, X + CW, Y + CH], fill=f)
                elif c.data == "█":
                    d.rectangle([X, Y, X + CW, Y + CH], fill=f)
                elif c.data == "░":
                    d.rectangle([X, Y, X + CW, Y + CH], fill="#2a3442")
                else:
                    d.text((X, Y + 2), c.data, font=BOLD if c.bold else FONT, fill=f)
        path = os.path.join(OUT, name)
        img.save(path, optimize=True, colors=None)
        print(path, os.path.getsize(path) // 1024, "KB")


def fixture():
    home = tempfile.mkdtemp(prefix="catalyst-shots-")
    def w(p, text=""):
        p = os.path.join(home, p)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    projects = {
        "old-storefront": ("package.json", "node_modules/", "node_modules/x/blob", 240),
        "rust-parser": ("Cargo.toml", "target/", "target/debug/blob", 910),
        "ml-demo": ("pyproject.toml", ".venv/", ".venv/lib/blob", 320),
        "shop-api": ("package.json", "node_modules/", "node_modules/y/blob", 180),
    }
    for name, (marker, ignore, blob, mb) in projects.items():
        r = f"Developer/{name}"
        w(f"{r}/{marker}", "{}\n")
        w(f"{r}/.gitignore", ignore + "\n")
        if name == "ml-demo":
            w(f"{r}/.venv/pyvenv.cfg", "home=/usr\n")
        w(f"{r}/{blob}")
        with open(os.path.join(home, r, blob), "wb") as f:
            f.write(b"\1" * (mb * 1000000))
        full = os.path.join(home, r)
        subprocess.run(f'cd "{full}" && git init -q && git -c user.name=A -c user.email=a@example.com add . && git -c user.name=A -c user.email=a@example.com commit -qm x && find . -exec touch -h -t 202507010000 {{}} +', shell=True, check=True)
    w(".zshrc", "")
    return home


def main():
    tmp = tempfile.mkdtemp(prefix="catalyst-bin-")
    binary, demo = os.path.join(tmp, "catalyst"), os.path.join(tmp, "demo")
    subprocess.run(["go", "build", "-o", binary, "./cmd/catalyst"], cwd=ROOT, check=True)
    subprocess.run(["go", "build", "-o", demo, "./demo"], cwd=ROOT, check=True)
    home = fixture()
    env = {"HOME": home, "PATH": os.environ["PATH"], "TERM": "xterm-256color", "COLORTERM": "truecolor", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8", "XDG_STATE_HOME": home + "/.state", "XDG_CONFIG_HOME": home + "/.config"}
    t = Term([demo, "doctor"], env, cols=88, rows=62)
    t.pump(4)
    t.save("hero.png", "catalyst doctor")
    t = Term([binary, "sweep", home + "/Developer", "--min-size", "1MB"], env, cols=88, rows=22)
    t.pump(2.5)
    t.send(b"\x1b[B", 0.2)
    t.send(b" ", 0.2)
    t.send(b"\x1b[B", 0.2)
    t.send(b" ", 0.3)
    t.save("sweep.png", "catalyst sweep")
    t = Term([demo], env, cols=88, rows=30)  # the invented machine has a health history, so the header has something to say
    t.pump(1.0)
    t.save("session.png", "catalyst")
    t.send(b"\r", 5)  # Doctor, then Enter on its first finding opens the guide
    t.send(b"\r", 2)
    t.save("guide.png", "catalyst")
    os.write(t.fd, b"\x03\x03")
    t = Term([demo], env, cols=88, rows=26)
    t.pump(1.0)
    for _ in range(9):
        t.send(b"\x1b[B", 0.05)
    t.send(b"\r", 2)
    t.send(b"\x1b[B", 0.2)
    t.save("ports.png", "catalyst")
    os.write(t.fd, b"\x03\x03")
    t = Term([demo, "status"], env, cols=88, rows=34)
    t.pump(2)
    t.save("status.png", "catalyst status")
    t = Term([demo, "battery"], env, cols=88, rows=24)
    t.pump(2)
    t.save("battery.png", "catalyst battery")
    t = Term([demo, "system"], env, cols=88, rows=46)
    t.pump(3)
    t.send(b"\x1b[B", 0.2)
    t.send(b" ", 0.3)
    t.save("system.png", "catalyst system")
    os.write(t.fd, b"\x1b")
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    art()


def art():
    sys.path.insert(0, os.path.dirname(__file__))
    sprites = json.loads(subprocess.run(["go", "run", "./demo/sprites"], cwd=ROOT, capture_output=True, text=True, check=True).stdout)
    pal, moods = sprites["palette"], sprites["moods"]
    def svg(rows, name, title):
        w, h = len(rows[0]), len(rows)
        rects = "".join(f'<rect x="{x}" y="{y}" width="1.02" height="1.02" fill="{pal[c]}"/>' for y, r in enumerate(rows) for x, c in enumerate(r) if c != ".")
        open(os.path.join(OUT, name), "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w*8}" height="{h*8}" role="img" aria-label="{title}" shape-rendering="crispEdges"><title>{title}</title>{rects}</svg>\n')
    svg(moods["idle"], "kit.svg", "Kit, the Catalyst cat")
    svg(moods["doctor"], "kit-doctor.svg", "Kit in a doctor's hat")
    # the GitHub social preview: upload it by hand under Settings, General
    img = Image.new("RGB", (1280, 640), BG)
    d = ImageDraw.Draw(img)
    rows = moods["doctor"]
    px = 26
    x0, y0 = 120, (640 - len(rows) * px) // 2
    for y, r in enumerate(rows):
        for x, c in enumerate(r):
            if c != ".":
                d.rectangle([x0 + x * px, y0 + y * px, x0 + (x + 1) * px - 1, y0 + (y + 1) * px - 1], fill=pal[c])
    d.text((590, 225), "Catalyst", font=ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 88, index=1), fill="#f4f7fb")
    small = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 32)
    d.text((594, 340), "The doctor for your dev", font=small, fill="#94a3b6")
    d.text((594, 384), "environment. macOS and Linux.", font=small, fill="#94a3b6")
    img.save(os.path.join(OUT, "social-preview.png"), optimize=True)


if __name__ == "__main__":
    main()
