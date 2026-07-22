#!/usr/bin/env bash
# Sourced by cut_release.sh. Aborts unless the Release build config is
# sane for a shippable, notarizable build (no Debug leakage, hardened runtime, real signing).
# Usage:  source "$APP_REPO_DIR/Scripts/preflight_release.sh"; preflight_release
preflight_release() {
  echo "▸ Preflight: checking Release build settings…"
  local S; S=$(xcodebuild -scheme Catalyst -configuration Release -showBuildSettings 2>/dev/null)
  [ -n "$S" ] || { echo "✗ couldn't read build settings (is the scheme 'Catalyst' shared?)"; exit 1; }
  local fail=0
  get() { sed -n "s/^[[:space:]]*$1 = //p" <<<"$S" | head -1; }

  [ "$(get CONFIGURATION)" = "Release" ]              || { echo "✗ CONFIGURATION is not Release"; fail=1; }
  [ "$(get ENABLE_HARDENED_RUNTIME)" = "YES" ]        || { echo "✗ Hardened Runtime is OFF (notarization requires it)"; fail=1; }
  [ "$(get SWIFT_OPTIMIZATION_LEVEL)" != "-Onone" ]   || { echo "✗ SWIFT_OPTIMIZATION_LEVEL is -Onone (Debug-like)"; fail=1; }
  [ "$(get GCC_OPTIMIZATION_LEVEL)" != "0" ]          || { echo "✗ GCC_OPTIMIZATION_LEVEL is 0 (Debug-like)"; fail=1; }
  case " $(get SWIFT_ACTIVE_COMPILATION_CONDITIONS) " in
    *" DEBUG "*|*DEBUG*) echo "✗ DEBUG is in SWIFT_ACTIVE_COMPILATION_CONDITIONS for Release"; fail=1;;
  esac
  [ "$(get CODE_SIGN_IDENTITY)" != "-" ]              || { echo "✗ Code signing is ad-hoc ('-') — needs a Developer ID / team"; fail=1; }
  [ "$(get MARKETING_VERSION)" != "" ]               || { echo "✗ MARKETING_VERSION is empty"; fail=1; }

  # The shared scheme's Archive action must build Release (guards against a hand-edited scheme).
  local scheme="Catalyst.xcodeproj/xcshareddata/xcschemes/Catalyst.xcscheme"
  if [ -f "$scheme" ]; then
    grep -A2 "<ArchiveAction" "$scheme" | grep -q 'buildConfiguration = "Release"' \
      || { echo "✗ Scheme ArchiveAction is not Release"; fail=1; }
  fi

  [ "$fail" -eq 0 ] || { echo "✗ Preflight failed — fix the above in Xcode and retry."; exit 1; }
  echo "✓ Preflight OK: Release · Hardened Runtime · optimized · no DEBUG · real signing (v$(get MARKETING_VERSION))."
}
