#!/usr/bin/env bash
# Fails if any personal value from the denylist appears in content or file names.
#   scripts/check-denylist.sh           scan staged additions (pre-commit)
#   scripts/check-denylist.sh --all     scan every tracked and untracked, non-ignored file
# Denylist: $DENYLIST_FILE, else .private/denylist.txt. Only the maintainer has one.
# Missing list fails closed for the maintainer (git config catalyst.maintainer, set by make hooks)
# and is skipped for contributors, who are covered by check-personal.py and gitleaks.
set -u
cd "$(git rev-parse --show-toplevel)"
LIST="${DENYLIST_FILE:-.private/denylist.txt}"
if [ ! -s "$LIST" ] && [ "$(git config --get catalyst.maintainer)" != true ]; then exit 0; fi
if [ ! -s "$LIST" ]; then
  echo "denylist: $LIST not found. Create it (see CLAUDE.md) or set DENYLIST_FILE." >&2
  exit 2
fi
PAT="$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | paste -sd'|' -)"
ALLOW='^\.github/CODEOWNERS$'  # a code owner has to be named there, and the maintainer's GitHub name is on the list
hits=0
if [ "${1:-}" = "--all" ]; then
  files="$(git ls-files -co --exclude-standard | grep -vE "$ALLOW")"
  out="$(echo "$files" | grep -iE "$PAT" | sed 's/^/filename: /')"
  [ -n "$out" ] && { echo "$out"; hits=1; }
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    out="$(grep -IniE "$PAT" -- "$f" 2>/dev/null | head -5)"
    [ -n "$out" ] && { echo "$out" | sed "s|^|$f:|"; hits=1; }
  done <<< "$files"
else
  out="$(git diff --cached --name-only --diff-filter=ACMR | grep -vE "$ALLOW" | grep -iE "$PAT" | sed 's/^/filename: /')"
  [ -n "$out" ] && { echo "$out"; hits=1; }
  out="$(git diff --cached -U0 --diff-filter=ACMR -- . ':!.github/CODEOWNERS' | grep -E '^\+[^+]' | grep -iE "$PAT" | head -20)"
  [ -n "$out" ] && { echo "$out"; hits=1; }
fi
if [ "$hits" -ne 0 ]; then
  echo "denylist: personal value found. Move it into config or remove it." >&2
  exit 1
fi
echo "denylist: clean"
