#!/bin/sh
# Runs every read-only command of a Linux build inside one container image, as root and as a normal user, and fails on
# a crash, a stack trace, an unexpected exit code or the wrong platform. CI and a local run use the same script:
#
#   CGO_ENABLED=0 go build -o catalyst ./cmd/catalyst
#   scripts/distro-matrix.sh debian:12 debian
#
# The second argument is the family Catalyst must report ("-" to skip that test). Nothing here changes the container
# beyond its own /tmp, and the container is thrown away afterwards.
set -u
image=$1
family=${2:--}
bin=${CATALYST_BIN:-$PWD/catalyst}
out=${MATRIX_OUT:-.cache/matrix/out}
mkdir -p "$out"
tag=$(printf '%s' "$image" | tr '/:' '__')

inner='
cd /tmp
fail=0
for c in "doctor -v" "doctor --json" "status" "status --json" "space" "clean --dry-run" "ports" "path" "ssh" "disk" "startup" "battery" "sweep --dry-run" "log" "version"; do
  /c/catalyst $c > /tmp/out.txt 2>&1
  code=$?
  echo "=== $c (exit $code)"
  cat /tmp/out.txt
  if grep -q -e "^goroutine " -e "panic:" /tmp/out.txt; then echo "MATRIX-FAIL stack trace in: $c"; fail=1; fi
  case "$c:$code" in
    doctor*:0|doctor*:1|doctor*:3|path:1|ssh:1|*:0) ;;
    *) echo "MATRIX-FAIL exit $code from: $c"; fail=1 ;;
  esac
done
exit $fail
'

status=0
for who in root user; do
  user_flag=""
  [ "$who" = user ] && user_flag="--user 1000:1000 -e HOME=/tmp/home"
  # shellcheck disable=SC2086
  docker run --rm $user_flag -e NO_COLOR=1 -e CATALYST_NO_OPEN=1 -v "$bin:/c/catalyst:ro" --entrypoint /bin/sh "$image" \
    -c "mkdir -p /tmp/home; $inner" > "$out/$tag.$who.txt" 2>&1
  code=$?
  fam=$(sed -n '/^=== status --json/,/^===/p' "$out/$tag.$who.txt" | grep -o '"family": *"[a-z]*"' | head -1 | sed 's/.*"\([a-z]*\)"$/\1/')
  if [ "$family" != "-" ] && [ "$fam" != "$family" ]; then
    echo "MATRIX-FAIL family is '$fam', expected '$family'" >> "$out/$tag.$who.txt"
    code=1
  fi
  if [ $code -ne 0 ]; then
    echo "FAIL $image as $who"
    grep MATRIX-FAIL "$out/$tag.$who.txt"
    status=1
  else
    echo "ok   $image as $who (family $fam)"
  fi
done
exit $status
