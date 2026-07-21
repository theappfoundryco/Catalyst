#!/usr/bin/env bash
# Re-sync GitHub Release bodies from each version's notes.html.
#
# Why this exists: cut_release.sh sets a Release's body ONCE via `gh release create
# --notes-file`. Editing updates/catalyst/Versions/<v>/notes.html afterward regenerates appcast.xml (via
# make_appcast.py) but does NOT touch the already-published GitHub Release body — so notes
# fixed after the fact stay stale on GitHub. Run this to push the current notes.html to
# each Release. Idempotent; safe to re-run. Runs on your Mac (needs `gh` auth).
#
#   ./Scripts/sync_release_notes.sh          # sync every version under Versions/
#   ./Scripts/sync_release_notes.sh 1.2 1.3  # sync only these versions
set -euo pipefail

APP_REPO_DIR="${CATALYST_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REL_DIR="$APP_REPO_DIR/updates/catalyst"
RELEASES_REPO="theappfoundryco/Catalyst"
PLACEHOLDER="Describe what changed in this release."

command -v gh >/dev/null || { echo "✗ gh CLI not found"; exit 1; }

if [ "$#" -gt 0 ]; then
  VERSIONS=("$@")
else
  VERSIONS=()
  for d in "$REL_DIR"/Versions/*/; do VERSIONS+=("$(basename "$d")"); done
fi

for V in "${VERSIONS[@]}"; do
  NOTES="$REL_DIR/Versions/$V/notes.html"
  [ -f "$NOTES" ] || { echo "✗ $V: no notes.html — skipping"; continue; }
  if grep -qF "$PLACEHOLDER" "$NOTES"; then
    echo "✗ $V: notes.html still has the seed placeholder — fix it first, skipping"; continue
  fi
  if ! gh release view "v$V" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    echo "✗ $V: no Release v$V on $RELEASES_REPO — skipping"; continue
  fi
  gh release edit "v$V" --repo "$RELEASES_REPO" --notes-file "$NOTES"
  echo "✓ synced v$V release body from $NOTES"
done

echo "✅ Done. Verify: gh release view v1.3 --repo $RELEASES_REPO"
