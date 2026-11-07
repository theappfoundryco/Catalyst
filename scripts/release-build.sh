#!/usr/bin/env bash
# Builds every release archive and SHA256SUMS into dist/. Used by the release workflow, and by hand if that is ever down.
#   scripts/release-build.sh v0.1.0
set -eu
tag="${1:?usage: scripts/release-build.sh v0.1.0}"
case "$tag" in v[0-9]*) ;; *) echo "The tag must look like v0.1.0" >&2; exit 2 ;; esac
cd "$(git rev-parse --show-toplevel)"
rm -rf dist; mkdir dist
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64; do
  os="${target%/*}"; arch="${target#*/}"
  work="$(mktemp -d)"
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "-s -w -X github.com/theappfoundryco/catalyst/internal/version.Version=${tag#v}" -o "$work/catalyst" ./cmd/catalyst
  cp LICENSE README.md "$work/"
  tar -C "$work" -czf "dist/catalyst_${os}_${arch}.tar.gz" catalyst LICENSE README.md
  rm -rf "$work"
done
cd dist
if command -v sha256sum >/dev/null 2>&1; then sha256sum ./*.tar.gz | sed 's# \./# #' > SHA256SUMS
else shasum -a 256 ./*.tar.gz | sed 's# \./# #' > SHA256SUMS; fi
cat SHA256SUMS
