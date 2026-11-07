#!/usr/bin/env python3
"""Flags real-looking email addresses and public IP addresses, for everyone (no private list needed).
  scripts/check-personal.py           scan staged additions (pre-commit)
  scripts/check-personal.py --all     scan every tracked and untracked, non-ignored file
Use example.com addresses and 192.168.x.x / 10.x.x.x / 192.0.2.x addresses in code, tests and docs."""
import ipaddress
import re
import subprocess
import sys

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}")
IP = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
OK_DOMAIN = re.compile(r"(^|\.)(example\.(com|org|net)|example|test|invalid|local|localhost|users\.noreply\.github\.com)$", re.I)
OK_EMAIL = {"git@github.com", "git@gitlab.com", "noreply@github.com"}
OK_IP = {"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"}  # public DNS, used for reachability checks
SVG = re.compile(r'<path|\bd="')
SKIP = re.compile(r"^(demo/|\.private/)|\.(png|jpe?g|gif|webp|ico|svg|woff2?|lock)$|^go\.sum$")


def bad(line):
    for m in EMAIL.finditer(line):
        e = m.group(0)
        if e.lower() not in OK_EMAIL and not OK_DOMAIN.search(e.split("@", 1)[1]):
            yield "email"
    for m in ([] if SVG.search(line) else IP.finditer(line)):  # SVG path numbers look like IPs
        try:
            ip = ipaddress.IPv4Address(m.group(0))
        except ValueError:
            continue
        if ip.is_global and m.group(0) not in OK_IP:
            yield "public IP"


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def main():
    root = git("rev-parse", "--show-toplevel").strip()
    hits = []
    if sys.argv[1:] == ["--all"]:
        for f in filter(None, git("-C", root, "ls-files", "-co", "--exclude-standard").splitlines()):
            if SKIP.search(f):
                continue
            try:
                with open(f"{root}/{f}", encoding="utf-8") as fh:
                    for n, line in enumerate(fh, 1):
                        hits += [(f, n, k) for k in bad(line)]
            except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
                continue
    else:
        f, n = None, 0
        for line in git("-C", root, "diff", "--cached", "-U0", "--diff-filter=ACMR").splitlines():
            if line.startswith("+++ "):
                f = line[6:] if line.startswith("+++ b/") else None
            elif line.startswith("@@"):
                n = int(re.search(r"\+(\d+)", line).group(1)) - 1
            elif line.startswith("+") and f and not SKIP.search(f):
                n += 1
                hits += [(f, n, k) for k in bad(line[1:])]
    for f, n, k in hits:  # never print the value itself
        print(f"personal-check: {k} at {f}:{n}. Use example.com or a private/documentation address.")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
