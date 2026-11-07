#!/bin/sh
# One-line install: downloads the newest release for this machine, checks it, and puts it in ~/.local/bin.
#   curl -fsSL https://raw.githubusercontent.com/theappfoundryco/catalyst/main/get.sh | sh
# Nothing else is needed: no Python, no git, no Xcode. Nothing outside ~/.local/bin changes without asking.
# Environment: CATALYST_DIR (folder, default ~/.local/bin), CATALYST_VERSION (for example v0.1.0, default the newest),
#              CATALYST_BASE (another download address, for testing)
set -eu
REPO="theappfoundryco/catalyst"
DIR="${CATALYST_DIR:-$HOME/.local/bin}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$(printf '\033[32m') RD=$(printf '\033[31m') D=$(printf '\033[2m') B=$(printf '\033[1m') R=$(printf '\033[0m') OKM="${G}✓${R}    " STOPM="${RD}✗${R}    "
else G='' RD='' D='' B='' R='' OKM='ok   ' STOPM='stop '; fi
ok() { printf '  %s%s\n' "$OKM" "$*"; }
stop() { printf '  %s%s\n' "$STOPM" "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux; if uname -r | grep -qi microsoft; then stop "Windows (WSL2) is not supported yet. macOS and Linux work today."; fi ;;
  *) stop "This system ($(uname -s)) is not supported. macOS and Linux work today." ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) stop "This processor ($(uname -m)) is not supported yet." ;;
esac

if command -v curl >/dev/null 2>&1; then fetch() { curl -fsSL --proto '=https,http' "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then fetch() { wget -q "$1" -O "$2"; }
else stop "This needs curl or wget to download."; fi

name="catalyst_${os}_${arch}.tar.gz"
if [ -n "${CATALYST_BASE:-}" ]; then base="$CATALYST_BASE"
elif [ -n "${CATALYST_VERSION:-}" ]; then base="https://github.com/$REPO/releases/download/$CATALYST_VERSION"
else base="https://github.com/$REPO/releases/latest/download"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
printf '  %sDownloading Catalyst for %s %s%s\n' "$D" "$os" "$arch" "$R"
fetch "$base/$name" "$work/$name" || stop "Could not download $base/$name"
fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || stop "Could not download the checksums, so nothing was installed."

want="$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1}' "$work/SHA256SUMS")"
[ -n "$want" ] || stop "The release has no checksum for $name, so nothing was installed."
if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$work/$name" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$work/$name" | awk '{print $1}')"
else stop "This needs sha256sum or shasum to check the download."; fi
[ "$got" = "$want" ] || stop "The download does not match its checksum, so nothing was installed."
ok "Downloaded and checked"

tar -xzf "$work/$name" -C "$work" catalyst || stop "Could not unpack the download."
mkdir -p "$DIR"
mv "$work/catalyst" "$DIR/catalyst.new"
chmod 755 "$DIR/catalyst.new"
mv "$DIR/catalyst.new" "$DIR/catalyst"  # a rename, so a running copy is never left half written
ok "Installed $("$DIR/catalyst" --version) in $DIR"

case ":$PATH:" in
  *":$DIR:"*) cmd=catalyst ;;
  *)
    cmd="$DIR/catalyst"
    if [ "$DIR" = "$HOME/.local/bin" ]; then
      printf '  %sLets you type catalyst from any folder. Adds one marked line to your shell startup file.%s\n' "$D" "$R"
      reply=y
      if [ -r /dev/tty ] && (exec </dev/tty) 2>/dev/null; then  # piped from curl: stdin is this script, so ask the keyboard
        printf '  Add the catalyst command to your terminal? [Y/n] '
        read -r reply </dev/tty || reply=n
      else reply=n; fi
      case "$reply" in
        n|N|no|No|NO) printf '  Skipped. Add it any time with: %s path add\n' "$cmd" ;;
        *) "$DIR/catalyst" path add && cmd=catalyst ;;
      esac
    else
      printf '  Add %s to your PATH to type catalyst from any folder.\n' "$DIR"
    fi ;;
esac
printf '\n  %s%sReady.%s Try: %s%s doctor%s\n' "$B" "$G" "$R" "$B" "$cmd" "$R"
if [ "$cmd" = catalyst ] && ! command -v catalyst >/dev/null 2>&1; then printf '  %sOpen a new terminal first, so it can find the command.%s\n' "$D" "$R"; fi
