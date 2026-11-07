#!/usr/bin/env bash
# Prints the release notes for a tag: commit subjects since the previous tag, sorted into Security, New and Fixed.
#   scripts/release-notes.sh v0.2.0
set -eu
tag="${1:?usage: scripts/release-notes.sh v0.2.0}"
prev="$(git tag -l 'v[0-9]*' --sort=-v:refname | grep -vx "$tag" | head -n 1 || true)"
range="$tag"; [ -n "$prev" ] && range="$prev..$tag"
section() {
  lines="$(git log --format=%s "$range" | grep "^$1: " | sed "s/^$1: /- /" || true)"
  [ -z "$lines" ] || printf '## %s\n\n%s\n\n' "$2" "$lines"
}
section security Security
section feat New
section fix Fixed
