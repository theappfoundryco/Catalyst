#!/usr/bin/env bash
# Blocks env files, personal data, backups, big files and stray images from being committed.
#   scripts/check-data-guard.sh           staged files (pre-commit)
#   scripts/check-data-guard.sh --all     every tracked and untracked, non-ignored file
set -u
cd "$(git rev-parse --show-toplevel)"
if [ "${1:-}" = "--all" ]; then files="$(git ls-files -co --exclude-standard)"
else files="$(git diff --cached --name-only --diff-filter=ACMR)"; fi
BAD_NAME='(^|/)(\.env[^/]*|[^/]*\.env|[^/]*\.(pem|key|pass|log|sqlite|db)|[^/]*\.bak[^/]*|[^/]*\.secret[^/]*|state[^/]*\.json)$'
BAD_DIR='(^|/)(data|\.?private|secrets?)/'
IMG_OK='^(docs|demo|\.github/assets)/'
BIG=$((1024*1024))
fail=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *.env.example) ;; *)
    if echo "$f" | grep -qE "$BAD_NAME" || echo "$f" | grep -qE "$BAD_DIR"; then
      echo "data-guard: forbidden file: $f"; fail=1; continue
    fi;;
  esac
  [ -f "$f" ] || continue
  if echo "$f" | grep -qiE '\.(png|jpe?g|gif|webp|ico|svg|mp4|mov|pdf)$' && ! echo "$f" | grep -qE "$IMG_OK"; then
    echo "data-guard: media outside docs/web/demo: $f"; fail=1
  fi
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt "$BIG" ] && ! grep -qxF "$f" scripts/large-file-allowlist.txt 2>/dev/null; then
    echo "data-guard: $f is over 1 MB (add to scripts/large-file-allowlist.txt if intended)"; fail=1
  fi
done <<< "$files"
[ "$fail" -eq 0 ] && echo "data-guard: clean"
exit "$fail"
