#!/usr/bin/env python3
"""
Regenerate the cumulative Sparkle appcast for Catalyst.

Scans  <releases-repo>/Versions/<version>/  folders. Each must contain:
  Catalyst-<version>.zip   the notarized, EdDSA-signed build
  meta.env                 VERSION, PUBDATE, MIN_OS, SIG, LENGTH
  notes.html               (optional) release notes -> embedded as <description>

Version-only: we don't track a separate build number. `sparkle:version` is set to the marketing
version (e.g. 1.1); Sparkle's version comparator orders dotted versions correctly (1.1 > 1.0), so
bumping MARKETING_VERSION in Xcode is all that's needed. (Keep CFBundleVersion = $(MARKETING_VERSION)
in the target so the installed app reports the same string it compares against.)

Writes  <releases-repo>/appcast.xml  (cumulative; every version, newest build first).

SIG/LENGTH are read from meta.env so historical versions are never re-signed — only the
version being cut is signed (by scripts/cut_release.sh, on the release machine, via sign_update).
If a version's meta.env has no SIG, we try `sign_update` on the zip (needs the private key in the
Keychain); if that also fails, the run aborts rather than emit an unsigned/blank enclosure.

Download URLs point at that version's GitHub Release asset on imsg8/Catalyst_Releases.

Usage:  python3 make_appcast.py [/path/to/Catalyst_Releases]
        (defaults to ~/Desktop/Catalyst/Catalyst_Releases)
"""
import os, re, sys, subprocess, html
from pathlib import Path

REPO      = "imsg8/Catalyst_Releases"
DL_TMPL   = "https://github.com/%s/releases/download/v{v}/Catalyst-{v}.zip" % REPO
FEED_TITLE = "Catalyst"

def load_meta(path: Path) -> dict:
    meta = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()
    return meta

def sign(zip_path: Path):
    """Fallback: run Sparkle's sign_update. Returns (sig, length) or None."""
    exe = None
    for cand in ("sign_update", str(Path(__file__).parent / "sign_update")):
        try:
            out = subprocess.run([cand, str(zip_path)], capture_output=True, text=True)
            if out.returncode == 0 and "edSignature" in out.stdout:
                sig = re.search(r'edSignature="([^"]+)"', out.stdout).group(1)
                length = re.search(r'length="([^"]+)"', out.stdout).group(1)
                return sig, length
        except FileNotFoundError:
            continue
    return None

def vkey(v: str):
    """Sort key: dotted version -> tuple of ints (e.g. '1.10' > '1.9')."""
    return tuple(int(p) if p.isdigit() else 0 for p in v.split("."))

def item_xml(m: dict, notes: str) -> str:
    v = m["VERSION"]
    url = DL_TMPL.format(v=v)
    desc = ""
    if notes.strip():
        desc = f"\n            <description><![CDATA[\n{notes.rstrip()}\n            ]]></description>"
    # Version-only: sparkle:version == the marketing version. Sparkle's comparator orders these.
    return f"""        <item>
            <title>{html.escape(v)}</title>{desc}
            <pubDate>{m.get('PUBDATE','')}</pubDate>
            <sparkle:version>{html.escape(v)}</sparkle:version>
            <sparkle:shortVersionString>{html.escape(v)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{m.get('MIN_OS','14.6')}</sparkle:minimumSystemVersion>
            <enclosure url="{url}" length="{m['LENGTH']}" type="application/octet-stream" sparkle:edSignature="{m['SIG']}"/>
        </item>"""

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Desktop/Catalyst/Catalyst_Releases"
    versions_dir = root / "Versions"
    if not versions_dir.is_dir():
        sys.exit(f"no Versions/ under {root}")

    items = []
    for vdir in sorted(versions_dir.iterdir()):
        if not vdir.is_dir():
            continue
        meta_path = vdir / "meta.env"
        if not meta_path.exists():
            print(f"  skip {vdir.name}: no meta.env", file=sys.stderr)
            continue
        m = load_meta(meta_path)
        zip_path = vdir / f"Catalyst-{m['VERSION']}.zip"
        if not m.get("SIG") or not m.get("LENGTH"):
            res = sign(zip_path)
            if not res:
                sys.exit(f"  {vdir.name}: no SIG in meta.env and sign_update unavailable/failed")
            m["SIG"], m["LENGTH"] = res
        notes_path = vdir / "notes.html"
        notes = notes_path.read_text() if notes_path.exists() else ""
        items.append((vkey(m["VERSION"]), m["VERSION"], item_xml(m, notes)))

    if not items:
        sys.exit("no versions found")
    items.sort(key=lambda t: t[0], reverse=True)   # newest version first

    body = "\n".join(x for _, _, x in items)
    xml = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>{FEED_TITLE}</title>
{body}
    </channel>
</rss>
"""
    (root / "appcast.xml").write_text(xml)
    vers = ", ".join(v for _, v, _ in items)
    print(f"✅ wrote {root/'appcast.xml'} ({len(items)} version(s): {vers})")

if __name__ == "__main__":
    main()
