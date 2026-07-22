#!/usr/bin/env bash
# Cut a Sparkle release of Catalyst to the PUBLIC releases repo (imsg8/Catalyst_Releases).
#
# ONE-RUN FLOW (no more seed-then-rerun):
#   1. Bump MARKETING_VERSION in Xcode (e.g. 1.10 -> 1.11). Version-only — no build number to touch.
#      (Keep CURRENT_PROJECT_VERSION = $(MARKETING_VERSION) so CFBundleVersion tracks it.)
#   2. Run:  ./Scripts/cut_release.sh
#      - If Versions/<v>/notes.html is missing, it prompts you for bullet points, builds the HTML,
#        shows a preview, and lets you [p]roceed / [e]dit / [a]bort. If it already exists, it just
#        previews + confirms.
#      - Builds → notarizes → staples → signs (Sparkle) → branded DMG → regenerates appcast →
#        creates the vX.Y GitHub Release.
#      - DEPRECATES every predecessor version: refreshes a single "⚠️ Deprecated — update to v<latest>"
#        banner in its notes.html (REPLACE, not stack — always points at the newest release, and
#        strips any legacy banner), deletes its DMG assets from GitHub (keeps the GitHub .zip
#        so Sparkle appcast enclosures stay valid), and PRUNES its local repo .zip so only the
#        latest version's zip stays checked in (meta.env keeps SIG/LENGTH). Confirms before deleting.
#      - Syncs all Release bodies from notes.html, then `git add -A` + pull --rebase + push.
#      - Verifies the live appcast + new assets.
#
# FLAGS:
#   --dry-run          Show exactly what WOULD happen (version, predecessors + DMG assets to delete,
#                      git actions) and exit. Builds nothing, deletes nothing, pushes nothing.
#   --deprecate-only   Skip the build/release; only (re)deprecate predecessors + sync + git. Handy to
#                      re-run the cleanup without a 10-minute rebuild.
#   --yes              Skip the "confirm asset deletion" prompt (for unattended runs).
set -euo pipefail

TEAM_ID="6957JGQD3R"
NOTARY_PROFILE="CATALYST_NOTARY"
APP_REPO_DIR="$HOME/Desktop/Catalyst"
REL_DIR="$APP_REPO_DIR/Catalyst_Releases"
RELEASES_REPO="imsg8/Catalyst_Releases"
DEP_MARKER="<!-- catalyst:deprecated -->"   # idempotency sentinel in a deprecated notes.html

DRY_RUN=false
DEPRECATE_ONLY=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --deprecate-only) DEPRECATE_ONLY=true ;;
    --yes|-y)         ASSUME_YES=true ;;
    -h|--help)        sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "✗ unknown flag: $arg (see --help)"; exit 1 ;;
  esac
done

# ── FAIL-FAST DEBUG GUARD (runs before anything else — notes prompt, build, git) ────────────────
# A shipped Release must NOT compile with DEBUG: it would bake in `#if DEBUG` code and the 🐛
# detection logging. The full preflight_release later re-checks this (among many things), but this
# runs FIRST so you never write release notes / kick a 10-min build only to abort at the end.
echo "▸ Debug guard: verifying the Release config has no DEBUG…"
DBG_SETTINGS=$(xcodebuild -scheme Catalyst -configuration Release -showBuildSettings 2>/dev/null) \
  || { echo "✗ couldn't read build settings (is the 'Catalyst' scheme shared?)"; exit 1; }
[ -n "$DBG_SETTINGS" ] || { echo "✗ empty build settings (is the 'Catalyst' scheme shared?)"; exit 1; }
DBG_COND=$(sed -n 's/^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS = //p' <<<"$DBG_SETTINGS" | head -1)
case " $DBG_COND " in
  *DEBUG*) echo "✗ DEBUG is active in the Release config (SWIFT_ACTIVE_COMPILATION_CONDITIONS='$DBG_COND')."
           echo "  Debug-only code and 🐛 logging would ship. Fix the Release build settings in Xcode. Aborting."
           exit 1 ;;
esac
DBG_CONFIG=$(sed -n 's/^[[:space:]]*CONFIGURATION = //p' <<<"$DBG_SETTINGS" | head -1)
[ "$DBG_CONFIG" = "Release" ] || { echo "✗ CONFIGURATION resolves to '$DBG_CONFIG', not Release — aborting."; exit 1; }
echo "✓ Debug guard OK: Release config, no DEBUG."

command -v gh >/dev/null || { echo "✗ gh CLI not found (brew install gh; gh auth login)"; exit 1; }

cd "$APP_REPO_DIR"

# Marketing version + min OS straight from the project. Version-only: no separate build number.
settings() { xcodebuild -scheme Catalyst -configuration Release -showBuildSettings 2>/dev/null; }
VERSION=$(settings | sed -n 's/.*MARKETING_VERSION = //p' | head -1)
MIN_OS=$(settings  | sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = //p' | head -1)
: "${MIN_OS:=14.6}"
[ -n "$VERSION" ] || { echo "✗ couldn't read MARKETING_VERSION from Xcode"; exit 1; }

VDIR="$REL_DIR/Versions/$VERSION"
ZIP="$VDIR/Catalyst-${VERSION}.zip"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Author notes.html by typing bullet points in the terminal (one per line, blank line ends).
# Returns 1 if nothing was entered (caller keeps any existing notes). HTML-escapes each line.
author_notes() {
  echo "▸ Release notes for v${VERSION} — type one bullet per line, empty line to finish:"
  local bullets=() line
  while IFS= read -r line; do [ -z "$line" ] && break; bullets+=("$line"); done
  if [ "${#bullets[@]}" -eq 0 ]; then echo "  (nothing entered)"; return 1; fi
  {
    echo "<h2>Catalyst ${VERSION}</h2>"
    echo "<ul>"
    local b
    for b in ${bullets[@]+"${bullets[@]}"}; do
      b=${b//&/&amp;}; b=${b//</&lt;}; b=${b//>/&gt;}   # escape HTML specials
      echo "  <li>${b}</li>"
    done
    echo "</ul>"
  } > "$VDIR/notes.html"
}

# List every released version EXCEPT the current latest ($VERSION).
predecessors() {
  local d v
  for d in "$REL_DIR"/Versions/*/; do
    v=$(basename "$d")
    [ "$v" = "$VERSION" ] && continue
    echo "$v"
  done
}

# Names of a release's .dmg assets (empty if none / no release).
dmg_assets() {
  gh release view "v$1" --repo "$RELEASES_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
    | grep -i '\.dmg$' || true
}

# Refresh a version's deprecation banner so it points at the CURRENT release. REPLACE, don't skip:
# strip any prior banner (our canonical marker+line AND the legacy "no longer maintained" line from
# before this script existed), then prepend one fresh banner. This guarantees three things:
#   • the pointer always names the latest version (1.0–1.10 update from "1.11" to "1.12" when 1.12 ships),
#   • banners never stack (idempotent — re-running produces the identical single banner),
#   • the legacy pre-marker banner is auto-removed on the next release (so a stale dup can't survive).
# The distinctive ASCII substrings below uniquely identify the three banner-line variants to drop.
add_deprecation_note() {
  local nf="$1"
  [ -f "$nf" ] || return 0
  local tmp; tmp=$(mktemp)
  grep -v -e 'catalyst:deprecated' \
          -e 'this version is superseded' \
          -e 'no longer maintained' "$nf" > "$tmp" || true   # grep -v exits 1 if it filters everything
  {
    echo "$DEP_MARKER"
    echo "<p><strong>⚠️ Deprecated —</strong> this version is superseded. Please update to Catalyst ${VERSION}.</p>"
    cat "$tmp"
  } > "$nf"
  rm -f "$tmp"
}

# Deprecate every predecessor: banner in notes.html + delete its DMG assets (keep the .zip).
deprecate_predecessors() {
  local preds; preds=$(predecessors)
  if [ -z "$preds" ]; then echo "▸ No predecessor versions to deprecate."; return 0; fi

  echo "▸ Predecessors to deprecate (banner in notes + delete DMG assets, keep .zip):"
  local v
  for v in $preds; do
    local dmgs; dmgs=$(dmg_assets "$v")
    echo "   • v$v  DMGs: $(echo "$dmgs" | tr '\n' ' ' | sed 's/ *$//' | grep . || echo '(none)')"
  done

  if ! $ASSUME_YES && ! $DRY_RUN; then
    read -rp "Delete the DMG assets listed above and add deprecation banners? [y/N]: " ans || ans=""
    case "$ans" in y|Y) ;; *) echo "Skipped deprecation."; return 0 ;; esac
  fi

  for v in $preds; do
    if $DRY_RUN; then
      echo "   [dry-run] would add deprecation banner to Versions/$v/notes.html"
    else
      add_deprecation_note "$REL_DIR/Versions/$v/notes.html"
    fi
    local a
    for a in $(dmg_assets "$v"); do
      [ -z "$a" ] && continue
      if $DRY_RUN; then
        echo "   [dry-run] gh release delete-asset v$v $a"
      else
        gh release delete-asset "v$v" "$a" --repo "$RELEASES_REPO" --yes \
          && echo "   ✓ deleted $a from v$v"
      fi
    done
    # Prune the predecessor's LOCAL repo .zip — it's redundant: GitHub still hosts it (the appcast
    # enclosure points there) and its meta.env already carries SIG/LENGTH for make_appcast. This
    # keeps only the latest version's .zip checked into Catalyst_Releases (was ~10MB per version).
    local pzip="$REL_DIR/Versions/$v/Catalyst-$v.zip"
    if [ -f "$pzip" ]; then
      if $DRY_RUN; then
        echo "   [dry-run] rm $pzip (prune predecessor local zip)"
      else
        rm -f "$pzip" && echo "   ✓ pruned local zip Versions/$v/Catalyst-$v.zip"
      fi
    fi
  done
}

# Push all Release bodies from notes.html, then commit + rebase-pull + push the repo.
sync_and_git() {
  if $DRY_RUN; then
    echo "   [dry-run] ./Scripts/sync_release_notes.sh"
    echo "   [dry-run] git add -A && git commit && git pull --rebase && git push  (in $REL_DIR)"
    return 0
  fi
  "$APP_REPO_DIR/Scripts/sync_release_notes.sh"
  git -C "$REL_DIR" add -A
  # Nothing staged is fine (e.g. --deprecate-only with no changes) — don't fail the run.
  if git -C "$REL_DIR" diff --cached --quiet; then
    echo "▸ Nothing new to commit in Catalyst_Releases."
  else
    git -C "$REL_DIR" commit -m "Release v${VERSION}; deprecate predecessors"
  fi
  git -C "$REL_DIR" pull --rebase origin main
  git -C "$REL_DIR" push origin main
}

# Prepend a dated entry to Catalyst_Releases/CHANGELOG.md, built from this version's notes.html
# <li> bullets (so it works whether you typed them or pre-wrote the file). Idempotent per version.
append_changelog() {
  local cl="$REL_DIR/CHANGELOG.md" nf="$VDIR/notes.html" title="# Catalyst — Changelog"
  [ -f "$nf" ] || return 0
  [ -f "$cl" ] && grep -qF "## v${VERSION} " "$cl" && return 0   # already logged this version

  # <li> content has no literal '<' (notes are HTML-escaped), so [^<]* is a clean extractor.
  local bullets; bullets=$(grep -oE '<li>[^<]*</li>' "$nf" \
    | sed -E 's|</?li>||g' \
    | sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g')

  local entry; entry="## v${VERSION} — $(date '+%Y-%m-%d')"$'\n'
  local b
  while IFS= read -r b; do [ -n "$b" ] && entry+="- ${b}"$'\n'; done <<< "$bullets"
  entry+=$'\n'

  if $DRY_RUN; then echo "   [dry-run] would prepend to CHANGELOG.md:"; printf '%s' "$entry" | sed 's/^/     /'; return 0; fi

  local body=""
  if [ -f "$cl" ]; then
    if [ "$(head -1 "$cl")" = "$title" ]; then
      body=$(tail -n +2 "$cl" | sed '1{/^$/d;}')   # drop title + one leading blank
    else
      body=$(cat "$cl")
    fi
    printf '%s\n\n%s%s\n' "$title" "$entry" "$body" > "$cl"
  else
    printf '%s\n\n%s' "$title" "$entry" > "$cl"
  fi
  echo "▸ Updated CHANGELOG.md (v${VERSION})."
}

verify() {
  echo "✅ Done. Feed live at /appcast.xml within ~5 min (Worker cache)."
  echo "   Verify: curl -s https://catalyst-api.shivanggulati817.workers.dev/appcast.xml | head"
  echo "   Assets: gh release view v${VERSION} --repo ${RELEASES_REPO}"
}

# ── Dry-run: print the plan and exit (no build, no mutations) ────────────────
if $DRY_RUN; then
  echo "▸ DRY RUN for v${VERSION} (min macOS ${MIN_OS})"
  $DEPRECATE_ONLY && echo "   mode: deprecate-only (would skip build/release)" \
                  || echo "   would build → notarize → sign → DMG → appcast → gh release create v${VERSION}"
  $DEPRECATE_ONLY || append_changelog
  deprecate_predecessors
  sync_and_git
  exit 0
fi

# ── Deprecate-only: skip the build entirely ─────────────────────────────────
if $DEPRECATE_ONLY; then
  echo "▸ Deprecate-only for latest v${VERSION}"
  deprecate_predecessors
  sync_and_git
  verify
  exit 0
fi

# ── Release notes (typed in the terminal) ───────────────────────────────────
mkdir -p "$VDIR"
# Author from the terminal when there are no notes yet (or only the seed placeholder).
if [ ! -f "$VDIR/notes.html" ] || grep -qF "Describe what changed in this release." "$VDIR/notes.html"; then
  author_notes || { echo "✗ No notes entered — aborting."; exit 1; }
fi

# Preview + confirm. Editing is terminal-first: [r]etype re-enters the bullets here; [e] opens
# $EDITOR (defaults to nano, still in the terminal) for a quick one-line tweak.
while true; do
  echo "───────── $VDIR/notes.html ─────────"
  cat "$VDIR/notes.html"
  echo "────────────────────────────────────"
  read -rp "Proceed? [p]roceed / [r]etype in terminal / [e]dit in \$EDITOR / [a]bort: " ans || ans="a"
  case "$ans" in
    p|P) break ;;
    r|R) author_notes || true ;;                 # keep existing notes if nothing re-entered
    e|E) "${EDITOR:-nano}" "$VDIR/notes.html" ;;
    a|A) echo "Aborted."; exit 1 ;;
  esac
done

# Guard: refuse the un-edited seed template + a re-release of an existing version.
if grep -qF "Describe what changed in this release." "$VDIR/notes.html"; then
  echo "✗ notes.html still contains the seed placeholder — write real notes."; exit 1
fi
[ -f "$ZIP" ] && { echo "✗ $ZIP already exists — v$VERSION looks already released. Bump MARKETING_VERSION."; exit 1; }

echo "▸ Releasing v${VERSION} (min macOS ${MIN_OS})"

# Abort unless the Release config is sane (no Debug leakage, hardened runtime, real signing).
source "$APP_REPO_DIR/Scripts/preflight_release.sh"; preflight_release

# ── Archive → export (Developer ID) → notarize → staple → re-zip stapled app ─
rm -rf build/Catalyst.xcarchive build/export
xcodebuild -scheme Catalyst -configuration Release \
  -archivePath build/Catalyst.xcarchive archive \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Catalyst.xcarchive \
  -exportPath build/export -exportOptionsPlist Scripts/exportOptions.plist
APP=build/export/Catalyst.app

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

# ── Branded DMG for the website (humans). Sparkle still updates via the .zip. ─
DMG="build/Catalyst-${VERSION}.dmg"
DMG_LATEST="build/Catalyst.dmg"
rm -f "$DMG" "$DMG_LATEST"
create-dmg \
  --volname "Catalyst" \
  --volicon Scripts/VolumeIcon.icns \
  --background Scripts/dmg-background@2x.png \
  --window-pos 200 120 --window-size 700 460 \
  --icon-size 112 \
  --icon "Catalyst.app" 185 290 \
  --app-drop-link 515 290 \
  --hide-extension "Catalyst.app" \
  "$DMG" "$APP"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
cp "$DMG" "$DMG_LATEST"   # stable name → permanent /releases/latest/download/Catalyst.dmg

# ── Sparkle EdDSA signature → meta.env (historical versions are never re-signed) ─
SIGN=$(find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle*/bin/sign_update' | head -1)
[ -x "$SIGN" ] || { echo "✗ sign_update not found in DerivedData — build once so SPM fetches Sparkle"; exit 1; }
SIGOUT=$("$SIGN" "$ZIP")                                   # -> sparkle:edSignature="..." length="..."
SIG=$(sed    -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIGOUT")
LENGTH=$(sed -n 's/.*length="\([^"]*\)".*/\1/p'      <<<"$SIGOUT")
[ -n "$SIG" ] || { echo "✗ sign_update produced no signature"; exit 1; }

cat > "$VDIR/meta.env" <<EOF
VERSION=$VERSION
PUBDATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
MIN_OS=$MIN_OS
SIG=$SIG
LENGTH=$LENGTH
EOF

# Regenerate the cumulative appcast from all Versions/*/.
python3 Scripts/make_appcast.py "$REL_DIR"

# Publish: GitHub Release hosts the zip + dmgs.
gh release create "v${VERSION}" "$ZIP" "$DMG" "$DMG_LATEST" \
  --repo "$RELEASES_REPO" --title "Catalyst ${VERSION}" --notes-file "$VDIR/notes.html"

# Log to CHANGELOG.md, deprecate predecessors (banner + delete DMG assets, keep zip), then
# sync Release bodies + git (add -A picks up the changelog + deprecations + templates).
append_changelog
deprecate_predecessors
sync_and_git
verify
