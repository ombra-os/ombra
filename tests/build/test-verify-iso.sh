#!/bin/bash
#
# tests/build/test-verify-iso.sh — offline tests for build/verify-iso.sh.
# Uses tiny fixture files instead of a real ISO: correctness of the
# checking logic only (a real-ISO verification happens at build time).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d /tmp/ombra-verifyiso.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

# Tiny fixture "ISO" + a pin that describes it correctly.
printf 'fake-iso-content' > "$TMP/good.iso"
GOOD_SHA="$(shasum -a 256 "$TMP/good.iso" | awk '{ print $1 }')"
GOOD_SIZE="$(stat -f %z "$TMP/good.iso")"
cat > "$TMP/good.pin" <<EOF
filename=good.iso
suite=test
arch=arm64
size_bytes=$GOOD_SIZE
sha256=$GOOD_SHA
EOF

# Pin with a wrong hash (simulates tampering with the ISO).
sed "s/^sha256=.*/sha256=0000000000000000000000000000000000000000000000000000000000000000/" \
  "$TMP/good.pin" > "$TMP/bad.pin"
# Pin whose file is simply absent.
sed 's/^filename=.*/filename=absent.iso/' "$TMP/good.pin" > "$TMP/absent.pin"
# Pin missing required keys.
printf 'filename=good.iso\n' > "$TMP/incomplete.pin"

run() { ISO_DIR="$TMP" "$REPO/build/verify-iso.sh" "$1" >/dev/null 2>&1; echo $?; }

echo "== verify-iso.sh =="
[ "$(run "$TMP/good.pin")" = "0" ] && ok "correct pin verifies" \
                                    || bad "correct pin should verify"
[ "$(run "$TMP/bad.pin")" = "1" ] && ok "wrong sha256 rejected" \
                                    || bad "wrong sha256 must fail"
[ "$(run "$TMP/absent.pin")" = "1" ] && ok "missing ISO rejected" \
                                       || bad "missing ISO must fail"
[ "$(run "$TMP/incomplete.pin")" = "2" ] && ok "incomplete pin rejected" \
                                          || bad "incomplete pin must be a usage error"

echo
if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS test(s)"; exit 1; fi
echo "ALL PASS"
