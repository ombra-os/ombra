#!/bin/sh
# tests/build/test-crypttab-wiring.sh — offline test for the keyscript wiring in
# desktop/late-command.sh: the awk rewriter must land the pinned tuple on the LUKS root
# line whatever it is numbered, leave cryptswap untouched, be idempotent, and FATAL loudly.
# No ISO, no root: safe to run anywhere.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LATE="$REPO/desktop/late-command.sh"
TMP="$(mktemp -d /tmp/ombra-crypttab-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

KS="keyscript=/usr/local/libexec/ombra/ombra-askpass"
WANT_SUFFIX=",x-initrd.attach,$KS,tries=0"

# exercise the REAL awk program from late-command.sh, not a copy
AWK_PROG="$(sed -n "s/^ *awk '\(.*\)' \/target\/etc\/crypttab.*/\1/p" "$LATE")"
[ -n "$AWK_PROG" ] || { echo "FAIL: could not extract the awk wiring from $LATE"; exit 1; }
case "$AWK_PROG" in *wired*) ;; *) echo "FAIL: extracted program looks wrong: $AWK_PROG"; exit 1 ;; esac

wire() { # run the late-command rewriter over a crypttab file
    awk "$AWK_PROG" "$1"
}

# 1. the pinned real-install shape (p4) — result must be the spec'd line
printf 'nvme0n1p4_crypt UUID=8f32ab90-dead-beef-cafe-1234567890ab none luks,discard\ncryptswap /dev/vg0/swap_1 /dev/urandom cipher=aes-xts-plain64,size=512,swap\n' \
    > "$TMP/p4.tab"
wire "$TMP/p4.tab" > "$TMP/p4.out"
head -1 "$TMP/p4.out" | grep -qF "nvme0n1p4_crypt UUID=8f32ab90-dead-beef-cafe-1234567890ab none luks,discard$WANT_SUFFIX" \
    && ok "pinned p4 entry wired to the spec'd line" \
    || bad "p4 entry wired wrong: $(head -1 "$TMP/p4.out")"

# 2. the cryptswap line must not be touched (it is not a passphrase LUKS)
sed -n 2p "$TMP/p4.out" | grep -qF 'cryptswap /dev/vg0/swap_1 /dev/urandom cipher=aes-xts-plain64,size=512,swap' \
    && ok "cryptswap line untouched" \
    || bad "cryptswap line was modified: $(sed -n 2p "$TMP/p4.out")"

# 3. layout drift: a differently-numbered LUKS root must wire too
printf 'nvme0n1p3_crypt UUID=8f32ab90-dead-beef-cafe-1234567890ab none luks,discard\n' > "$TMP/p3.tab"
wire "$TMP/p3.tab" > "$TMP/p3.out"
grep -qF "$KS,tries=0" "$TMP/p3.out" && grep -qF 'x-initrd.attach' "$TMP/p3.out" \
    && ok "drifted p3 entry also wired (generic match)" \
    || bad "drifted p3 entry NOT wired (pinned-name no-op class)"

# 4. idempotent: a second pass changes nothing
wire "$TMP/p4.out" > "$TMP/p4.again"
cmp -s "$TMP/p4.out" "$TMP/p4.again" \
    && ok "rewriter is idempotent (re-run changes nothing)" \
    || bad "re-run stacked options: $(head -1 "$TMP/p4.again")"

# 5. comments and unrelated lines pass through untouched
printf '# comment line\nnvme0n1p4_crypt UUID=x none luks,discard\n' > "$TMP/c.tab"
wire "$TMP/c.tab" > "$TMP/c.out"
sed -n 1p "$TMP/c.out" | grep -qF '# comment line' \
    && ok "comment line preserved" \
    || bad "comment line corrupted: $(sed -n 1p "$TMP/c.out")"

# 6. the loud failure path exists
grep -q 'keyscript not wired into /target/etc/crypttab' "$LATE" \
    && ok "FATAL guard for unwired crypttab present" \
    || bad "no FATAL guard for unwired crypttab"
grep -q 'tries=0 missing' "$LATE" \
    && ok "FATAL guard for missing tries=0 present" \
    || bad "no FATAL guard for missing tries=0"
grep -q 'lsinitramfs /boot/initrd.img' "$LATE" \
    && ok "FATAL guard that the initrd carries the binary present" \
    || bad "no initrd-content FATAL guard"

# 7. the pinned entry shape in one piece
grep -q 'x-initrd.attach,keyscript=/usr/local/libexec/ombra/ombra-askpass,tries=0' "$LATE" \
    && ok "appended options are the exact pinned tuple" \
    || bad "appended option tuple drifted from the spec"

echo
if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS test(s)"; exit 1; fi
echo "ALL PASS"
