#!/bin/bash
#
# verify-ova.sh — import a release OVA into a scratch directory and assert the
# shipped shape of the resulting vmx. Accepts an .ova, or a part prefix
# (<name>.ova.part-aa ...) which is joined first.
# Disk mode and pinned MACs are intentionally NOT asserted: the guests do not
# depend on them (the gateway is amnesic in-guest and matches NICs by driver).

set -uo pipefail

usage() { echo "usage: bash build/fusion/verify-ova.sh <file.ova | file.ova.part-aa>"; }

IN="${1:-}"
[ -n "$IN" ] && [ -e "$IN" ] || { usage; exit 2; }
OVFTOOL="${OVFTOOL:-$(command -v ovftool || echo /Applications/VMware\ Fusion.app/Contents/Library/VMware\ OVF\ Tool/ovftool)}"
[ -x "$OVFTOOL" ] || { echo "FATAL: ovftool not found (set OVFTOOL=/path/to/ovftool)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$IN" in
  *.ova.part-*)
    PREFIX="${IN%.part-*}"
    OVA="$TMP/joined.ova"
    cat "$PREFIX".part-* > "$OVA" || { echo "FATAL: could not join parts" >&2; exit 1; }
    NAME="$(basename "$PREFIX")" ;;
  *) OVA="$IN"; NAME="$(basename "$IN")" ;;
esac

OUT="$TMP/import"
mkdir -p "$OUT"
if ! "$OVFTOOL" --lax --allowExtraConfig "$OVA" "$OUT" >"$TMP/ovftool.log" 2>&1; then
  tail -n 20 "$TMP/ovftool.log" >&2
  echo "FATAL: ovftool import failed" >&2
  exit 1
fi
VMX="$(find "$OUT" -name '*.vmx' | head -1)"
[ -f "$VMX" ] || { echo "FATAL: no vmx after import" >&2; exit 1; }

FAILS=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS+1)); fi; }
vmx_get() { awk -F= -v k="$1" '{kk=$1; gsub(/^[ \t]+|[ \t]+$/, "", kk); if (tolower(kk)==tolower(k)) {v=substr($0, index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v); print v; exit}}' "$VMX"; }

PERSONAL='/Us''ers/|/priv''ate/|co''dy|hac''cer'
case "$NAME" in
  *gateway*)
    check "ethernet0.virtualDev is vmxnet3" '[ "$(vmx_get ethernet0.virtualDev)" = "vmxnet3" ]'
    check "ethernet1.virtualDev is e1000e" '[ "$(vmx_get ethernet1.virtualDev)" = "e1000e" ]'
    check "ethernet0 is nat" '[ "$(vmx_get ethernet0.connectionType)" = "nat" ]'
    check "ethernet1 is hostonly" '[ "$(vmx_get ethernet1.connectionType)" = "hostonly" ]' ;;
  *desktop*)
    check "ethernet0 is hostonly" '[ "$(vmx_get ethernet0.connectionType)" = "hostonly" ]' ;;
  *) check "OVA name contains gateway or desktop" 'false' ;;
esac
for key in isolation.tools.copy.disable isolation.tools.paste.disable isolation.tools.dnd.disable isolation.tools.hgfs.disable isolation.tools.setGUIOptions.enable; do
  check "$key present" '[ -n "$(vmx_get "$key")" ]'
done
check "no personal strings in the imported text files" '! grep -rIlE "$PERSONAL" "$OUT" >/dev/null 2>&1'

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
echo "ALL PASS"
