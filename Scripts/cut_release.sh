#!/usr/bin/env bash
# Cut a Sparkle release of Catalyst: GitHub Release on theappfoundryco/Catalyst, feed on `updates`.
#
# ONE-RUN FLOW (no more seed-then-rerun):
#   1. Bump MARKETING_VERSION in Xcode (e.g. 1.10 -> 1.11). Version-only — no build number to touch.
#      (Keep CURRENT_PROJECT_VERSION = $(MARKETING_VERSION) so CFBundleVersion tracks it.)
#   2. Run:  ./Scripts/cut_release.sh
#      - If Versions/<v>/notes.html is missing, it prompts you for bullet points, builds the HTML,
#        shows a preview, and lets you [p]roceed / [e]dit / [a]bort. If it already exists, it just
#        previews + confirms.
#      - Builds → notarizes → staples → signs (Sparkle) → regenerates appcast →
#        creates the vX.Y GitHub Release.
#      - DEPRECATES every predecessor version: refreshes a single "⚠️ Deprecated — update to v<latest>"
#        banner in its notes.html (REPLACE, not stack — always points at the newest release, and
#        strips any legacy banner), keeping the GitHub .zip asset
#        so Sparkle appcast enclosures stay valid), and PRUNES its local repo .zip so only the
#        latest version's zip stays checked in (meta.env keeps SIG/LENGTH). Confirms before deleting.
#      - Syncs all Release bodies from notes.html, then `git add -A` + pull --rebase + push.
#      - Verifies the live appcast + new assets.
#
# FLAGS:
#   --dry-run          Show exactly what WOULD happen (version, predecessors to deprecate,
#                      git actions) and exit. Builds nothing, deletes nothing, pushes nothing.
#   --deprecate-only   Skip the build/release; only (re)deprecate predecessors + sync + git. Handy to
#                      re-run the cleanup without a 10-minute rebuild.
#   --yes              Skip the "confirm asset deletion" prompt (for unattended runs).
set -euo pipefail

TEAM_ID="6957JGQD3R"
NOTARY_PROFILE="CATALYST_NOTARY"
# Derived from this script's own location, not hardcoded to ~/Desktop — the repo is public now
# and a contributor's clone can live anywhere. Override with CATALYST_REPO if you need to.
APP_REPO_DIR="${CATALYST_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Releases (the .zip assets) are published to the APP repo itself. There is no separate
# releases repo — that split existed only because the source was private and Sparkle needs
# unauthenticated downloads. Both are public now, so the split bought nothing.
RELEASES_REPO="theappfoundryco/Catalyst"

# Per-version metadata (notes.html + the cached Sparkle signature in meta.env) lives in the
# `updates` repo beside the feed it generates. That repo is then self-contained: everything
# needed to regenerate the cumulative appcast is cloneable, which matters because a historical
# version is NEVER re-signed — if meta.env is lost, that version's signature is unrecoverable
# and the entry has to be dropped from the feed.
#
# The .zip itself is deliberately NOT stored here. It is built into `build/` (gitignored) and
# uploaded to the GitHub Release. Committing ~11 MB per version to git bought nothing: the
# Release is the download host, and meta.env already carries the signature and length.
# The Sparkle feed is published from the studio-wide `updates` repo:
# updates.theappfoundry.co/catalyst/appcast.xml
UPDATES_DIR="$APP_REPO_DIR/updates"
REL_DIR="$UPDATES_DIR/catalyst"
APPCAST_OUT="$REL_DIR/appcast.xml"
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
# The release depends on two sibling repos being cloned next to the app repo. Check BOTH before
# doing anything expensive: discovering a missing one after notarization means a published
# GitHub Release with no appcast beside it, which is the exact half-published state that is
# invisible to users (Sparkle reads an unreachable feed as "no update available").
# Ask git, don't probe the filesystem. `[ -d "$dir/.git" ]` looks obvious and is wrong: `.git` is
# a FILE (a gitdir pointer) for worktrees and submodules, and some mounts don't expose it at all —
# so the directory test rejects a perfectly good clone. Comparing `--show-toplevel` to the path
# also rules out the opposite mistake: a bare `rev-parse` inside a non-repo walks UP and happily
# finds the app repo's own .git, reporting success for a directory that isn't a clone at all.
if [ "$(git -C "$UPDATES_DIR" rev-parse --show-toplevel 2>/dev/null)" != "$UPDATES_DIR" ]; then
  echo "✗ missing sibling repo: $UPDATES_DIR"
  echo "  git clone git@github.com:theappfoundryco/updates.git  (beside the app repo)"
  exit 1
fi

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

# Guard against the Sparkle infinite-update loop (cache/hiccup.md, v1.3). Sparkle compares the
# appcast's sparkle:version (== MARKETING_VERSION) against the installed app's CFBundleVersion
# (= $(CURRENT_PROJECT_VERSION)). If the build number drifts below the marketing version, every
# updated install still reports the old CFBundleVersion, so the feed always looks "newer" and the
# app re-downloads forever. Enforce the version-only invariant documented at the top of this file.
BUILD_NUM=$(settings | sed -n 's/.*CURRENT_PROJECT_VERSION = //p' | head -1)
[ "$BUILD_NUM" = "$VERSION" ] || {
  echo "✗ CURRENT_PROJECT_VERSION ($BUILD_NUM) != MARKETING_VERSION ($VERSION)."
  echo "  CFBundleVersion would ship as $BUILD_NUM while the feed advertises $VERSION → Sparkle"
  echo "  infinite-update loop. Set CURRENT_PROJECT_VERSION = \$(MARKETING_VERSION) in the project."
  exit 1
}

VDIR="$REL_DIR/Versions/$VERSION"
DMG="$APP_REPO_DIR/build/Catalyst-${VERSION}.dmg"
mkdir -p "$VDIR" "$APP_REPO_DIR/build"

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
# Every published version except the one being cut.
#
# The `[ -d "$d" ]` guard is load-bearing. Without `nullglob`, an unmatched glob stays LITERAL,
# so a missing or empty `Versions/` yields the literal string `*` — which the caller's unquoted
# `for v in $preds` then expands against the CURRENT DIRECTORY. The result is not "no
# predecessors"; it is every folder in the repo treated as a version to deprecate. Seen for real
# when the sibling metadata repo wasn't cloned beside the app repo.
predecessors() {
  local d v
  for d in "$REL_DIR"/Versions/*/; do
    [ -d "$d" ] || continue
    v=$(basename "$d")
    [ "$v" = "$VERSION" ] && continue
    echo "$v"
  done
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

# Deprecate every predecessor: add a banner to its notes.html.
#
# Previously this ALSO deleted each predecessor's .dmg assets from GitHub, because a stale
# branded DMG on an old release was a download people could still find. With no DMGs there is
# nothing to delete — the .zip is deliberately kept forever, since Sparkle appcast enclosures
# for older versions point at it and breaking those breaks upgrades from old installs.
deprecate_predecessors() {
  local preds; preds=$(predecessors)
  if [ -z "$preds" ]; then echo "▸ No predecessor versions to deprecate."; return 0; fi

  echo "▸ Predecessors to deprecate (banner in notes; .zip assets are kept):"
  local v
  for v in $preds; do echo "   • v$v"; done

  if ! $ASSUME_YES && ! $DRY_RUN; then
    read -rp "Add deprecation banners to the versions above? [y/N]: " ans || ans=""
    case "$ans" in y|Y) ;; *) echo "Skipped deprecation."; return 0 ;; esac
  fi

  for v in $preds; do
    if $DRY_RUN; then
      echo "   [dry-run] would add deprecation banner to Versions/$v/notes.html"
    else
      add_deprecation_note "$REL_DIR/Versions/$v/notes.html"
    fi
  done
}

# PUBLISH FIRST, polish second. Ordering here is deliberate and was learned the hard way.
#
# Pushing the appcast is the step that makes an update REACHABLE; syncing GitHub Release bodies
# is cosmetic. This function used to run the cosmetic step first, so when
# `sync_release_notes.sh` failed (it lacked the executable bit — and git recorded it that way,
# so every clone would have hit it), `set -e` killed the run BEFORE the push. That left a
# published Release with no matching appcast: invisible to every install, and silent, because
# Sparkle reads a feed that doesn't list a newer version as "no update available". It happened
# on two consecutive releases before anyone noticed.
#
# Now the push happens first and the notes sync cannot abort the run — a failure there is
# reported and survivable, because `./Scripts/sync_release_notes.sh` can be re-run any time.
sync_and_git() {
  if $DRY_RUN; then
    echo "   [dry-run] git add -A && git commit && git pull --rebase && git push  (in $UPDATES_DIR)"
    echo "   [dry-run] bash ./Scripts/sync_release_notes.sh"
    return 0
  fi

  git -C "$UPDATES_DIR" add -A
  if git -C "$UPDATES_DIR" diff --cached --quiet; then
    echo "▸ Nothing new to commit in updates."
  else
    git -C "$UPDATES_DIR" commit -m "catalyst: v${VERSION} appcast, notes and changelog"
  fi
  git -C "$UPDATES_DIR" pull --rebase origin main
  git -C "$UPDATES_DIR" push origin main
  echo "▸ Feed published."

  # Invoked via `bash`, not executed directly: an explicit interpreter doesn't care whether the
  # executable bit survived the clone, the zip, or the copy. Never rely on a permission bit for
  # a script you control the call site of.
  if ! bash "$APP_REPO_DIR/Scripts/sync_release_notes.sh"; then
    echo "⚠️  sync_release_notes.sh failed — the feed IS published and users will get the update."
    echo "   Only the GitHub Release bodies are stale. Re-run when convenient:"
    echo "   bash ./Scripts/sync_release_notes.sh"
  fi
}

# Prepend a dated entry to updates/catalyst/CHANGELOG.md, built from this version's notes.html
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
  echo "✅ Done. Feed live at updates.theappfoundry.co/catalyst/appcast.xml shortly."
  echo "   Verify: curl -s https://updates.theappfoundry.co/catalyst/appcast.xml | head"
  echo "   Assets: gh release view v${VERSION} --repo ${RELEASES_REPO}"
}

# ── Dry-run: print the plan and exit (no build, no mutations) ────────────────
if $DRY_RUN; then
  echo "▸ DRY RUN for v${VERSION} (min macOS ${MIN_OS})"
  $DEPRECATE_ONLY && echo "   mode: deprecate-only (would skip build/release)" \
                  || echo "   would build → notarize → sign → appcast → gh release create v${VERSION}"
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
# The .zip is a build artifact now, so its absence proves nothing. meta.env is the durable
# record that a version was signed and published — that is what must not already exist.
[ -f "$VDIR/meta.env" ] && { echo "✗ $VDIR/meta.env exists — v$VERSION is already released. Bump MARKETING_VERSION."; exit 1; }

echo "▸ Releasing v${VERSION} (min macOS ${MIN_OS})"

# Abort unless the Release config is sane (no Debug leakage, hardened runtime, real signing).
source "$APP_REPO_DIR/Scripts/preflight_release.sh"; preflight_release

# ── Archive → export (Developer ID) → build DMG → notarize → staple ─
rm -rf build/Catalyst.xcarchive build/export
xcodebuild -scheme Catalyst -configuration Release \
  -archivePath build/Catalyst.xcarchive archive \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/Catalyst.xcarchive \
  -exportPath build/export -exportOptionsPlist Scripts/exportOptions.plist
APP=build/export/Catalyst.app

# Catalyst ships a single notarized .dmg: a Finder window with the app beside an /Applications
# alias, so installing is a DRAG INTO APPLICATIONS rather than "run it from Downloads". Running an
# unmoved quarantined app triggers Gatekeeper app-translocation (a random, read-only path), which
# breaks Sparkle's in-place self-update — the drag is what avoids that. Still ONE artifact: the
# .dmg is both what humans download and what Sparkle's enclosure points at.
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  # Branded layout (create-dmg): custom volume icon + backdrop and the exact icon/window
  # geometry carried over from the pre-OSS builder. Assets live in Scripts/ (tracked now that
  # the stray Scripts/ ignore is gone). Backdrop is the @2x PNG (1400x920) shown at 700x460.
  create-dmg \
    --volname "Catalyst ${VERSION}" \
    --volicon "$APP_REPO_DIR/Scripts/VolumeIcon.icns" \
    --background "$APP_REPO_DIR/Scripts/dmg-background.png" \
    --window-pos 200 120 --window-size 700 460 \
    --icon-size 112 \
    --icon "Catalyst.app" 185 290 \
    --app-drop-link 515 290 \
    --hide-extension "Catalyst.app" \
    "$DMG" "$APP"
else
  # Dependency-free fallback: a compressed dmg holding the app + an /Applications symlink, so the
  # drag target still exists (no positioned background, but a correct install medium).
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Catalyst ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

# Notarize the DMG (Apple notarizes the app inside) and staple the ticket ONTO the dmg so
# Gatekeeper clears the download offline. Single round-trip: the app was already Developer-ID
# signed + hardened at export, so there's no second notarization the zip-plus-dmg era needed.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# ── Sparkle EdDSA signature → meta.env (historical versions are never re-signed) ─
SIGN=$(find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle*/bin/sign_update' | head -1)
[ -x "$SIGN" ] || { echo "✗ sign_update not found in DerivedData — build once so SPM fetches Sparkle"; exit 1; }
SIGOUT=$("$SIGN" "$DMG")                                   # -> sparkle:edSignature="..." length="..."
SIG=$(sed    -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIGOUT")
LENGTH=$(sed -n 's/.*length="\([^"]*\)".*/\1/p'      <<<"$SIGOUT")
[ -n "$SIG" ] || { echo "✗ sign_update produced no signature"; exit 1; }

# ASSET records THIS version's download filename so the appcast enclosure names the real asset.
# It is what lets the feed carry .dmg entries for new releases while every HISTORICAL entry keeps
# its original .zip: make_appcast.py defaults to Catalyst-<v>.zip when ASSET is absent, so versions
# whose meta.env predates this field are never rewritten to a .dmg that doesn't exist. Do NOT
# retro-fill old meta.env with .dmg — their GitHub asset is the .zip and their SIG signs the .zip.
cat > "$VDIR/meta.env" <<EOF
VERSION=$VERSION
PUBDATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
MIN_OS=$MIN_OS
SIG=$SIG
LENGTH=$LENGTH
ASSET=Catalyst-${VERSION}.dmg
EOF

# Regenerate the cumulative appcast from all Versions/*/ into the updates repo.
python3 Scripts/make_appcast.py "$REL_DIR" "$APPCAST_OUT"

# Publish: the GitHub Release hosts the single .dmg.
gh release create "v${VERSION}" "$DMG" \
  --repo "$RELEASES_REPO" --title "Catalyst ${VERSION}" --notes-file "$VDIR/notes.html"

# Log to CHANGELOG.md, deprecate predecessors (notes banner only), then
# sync Release bodies + git (add -A picks up the changelog + deprecations + templates).
append_changelog
deprecate_predecessors
sync_and_git
verify
