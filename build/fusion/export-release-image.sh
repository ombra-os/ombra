#!/bin/bash
#
# export-release-image.sh — turn a powered-off, freshly installed VM into a
# distributable OVA. Run AFTER the post-install runbook, BEFORE first boot.
# The install itself scrubs the disk; this script strips builder residue from
# a COPY of the VM bundle, asserts the shipped shape, exports the copy with
# ovftool, verifies the OVA, and writes the sums. OMBRA_SPLIT=1 additionally
# splits it under GitHub's per-asset cap.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VMROOT="${HOME}/Virtual Machines.localized"
VERSION="${OMBRA_VERSION:-1.0.0}"
OUT_DIR="${OMBRA_RELEASE_DIR:-$REPO/build/releases}"
LIMIT=$((2 * 1024 * 1024 * 1024))
PART_SIZE="1900m"
OVFTOOL="${OVFTOOL:-$(command -v ovftool || echo /Applications/VMware\ Fusion.app/Contents/Library/VMware\ OVF\ Tool/ovftool)}"

usage() {
  cat <<EOF2
usage: bash build/fusion/export-release-image.sh <desktop|gateway> [vmx-path]

  VM must be powered OFF and post-install (gateway: post-install first);
  the desktop must never have been booted. Exports a scrubbed copy with
  ovftool (--exportFlags=extraconfig, so the isolation.tools.* keys ride
  along) to <outdir>/ombra-<target>-arm64-v$VERSION.ova, a single file
  (with OMBRA_SPLIT=1: .ova.part-aa, .part-ab, ... under the 2 GiB
  GitHub release-asset cap; join: cat <name>.ova.part-* > <name>.ova), and rewrites
  <outdir>/SHA256SUMS.txt with one line per artifact present.

  env: OMBRA_VERSION (default 1.0.0), OMBRA_RELEASE_DIR (default
  build/releases), OMBRA_SPLIT (1 = split for GitHub), OVFTOOL (path to ovftool)
EOF2
}

fatal() { echo "FATAL: $*" >&2; exit 1; }

TARGET="${1:-}"
if [ "$TARGET" != "desktop" ] && [ "$TARGET" != "gateway" ]; then usage; exit 2; fi
SRC_VMX="${2:-$VMROOT/ombra-$TARGET.vmwarevm/ombra-$TARGET.vmx}"
[ -f "$SRC_VMX" ] || fatal "vmx not found: $SRC_VMX"
[ -x "$OVFTOOL" ] || fatal "ovftool not found (set OVFTOOL=/path/to/ovftool)"
mkdir -p "$OUT_DIR"

VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
[ -x "$VMRUN" ] || fatal "vmrun not found at: $VMRUN"
RUNNING="$("$VMRUN" -T fusion list 2>&1)" || fatal "vmrun list failed — cannot tell whether the VM is running: $RUNNING"
if printf '%s\n' "$RUNNING" | grep -qF "$SRC_VMX"; then
  fatal "VM is running — power it off first (export is pre-first-boot by design)"
fi

if grep -qE '\-test\.iso' "$SRC_VMX" || grep -qE '^displayName = .*TEST' "$SRC_VMX"; then
  fatal "the vmx references a test-build ISO or is named TEST — test builds are never exported"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/ombra-$TARGET.vmwarevm"
cp -cR "$(dirname "$SRC_VMX")" "$BUNDLE" 2>/dev/null || cp -R "$(dirname "$SRC_VMX")" "$BUNDLE"
VMX="$BUNDLE/$(basename "$SRC_VMX")"

rm -rf "$BUNDLE"/*.lck "$BUNDLE"/*.log "$BUNDLE"/*.bak "$BUNDLE"/*.scoreboard "$BUNDLE"/*.plist "$BUNDLE"/caches "$BUNDLE"/.DS_Store
sed -E -i '' \
  -e '/^#/d' \
  -e '/^(RemoteDisplay\.|serial[0-9]+\.|uuid\.bios|uuid\.location|checkpoint\.vmState|vmxstats\.filename)/d' \
  -e 's|^(sata0:0\.fileName = ).*|\1"auto detect"|' \
  "$VMX"
grep -qE '^(RemoteDisplay\.|serial[0-9]+\.)' "$VMX" && fatal "debug keys survived the strip — refusing to export"
PERSONAL='/Us''ers/|/priv''ate/|co''dy|hac''cer'
if grep -rIl -E "$PERSONAL" "$BUNDLE" >/dev/null 2>&1; then
  fatal "personal path or name found in the bundle text files: $(grep -rIl -E "$PERSONAL" "$BUNDLE" | head -3 | tr '\n' ' ')"
fi

vmx_get() { awk -F= -v k="$1" '{kk=$1; gsub(/^[ \t]+|[ \t]+$/, "", kk); if (tolower(kk)==tolower(k)) {v=substr($0, index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v); print v; exit}}' "$VMX"; }
if [ "$TARGET" = "desktop" ]; then
  [ "$(vmx_get ethernet0.connectionType)" = "hostonly" ] \
    || fatal "desktop NIC is not on the private link — run the post-install runbook first"
  [ -z "$(vmx_get nvme0:0.mode)" ] || fatal "desktop disk must stay persistent"
else
  [ "$(vmx_get ethernet0.connectionType)" = "nat" ] \
    || fatal "gateway upstream NIC must be NAT"
  [ "$(vmx_get ethernet0.virtualDev)" = "vmxnet3" ] || fatal "gateway ethernet0 is not vmxnet3"
  [ "$(vmx_get ethernet1.connectionType)" = "hostonly" ] \
    || fatal "gateway private-link NIC must be hostonly"
  [ "$(vmx_get ethernet1.virtualDev)" = "e1000e" ] || fatal "gateway ethernet1 is not e1000e"
  [ "$(vmx_get ethernet1.startConnected | tr '[:upper:]' '[:lower:]')" = "true" ] \
    || fatal "gateway private-link NIC not connected"
fi
[ "$(vmx_get sata0:0.startConnected | tr '[:upper:]' '[:lower:]')" = "false" ] \
  || fatal "installer CD still connected"
[ "$(vmx_get bios.bootOrder)" = "hdd,cdrom" ] || fatal "boot order is not hdd-first"
if [ "$TARGET" = "gateway" ]; then [ "$(vmx_get memsize)" = "512" ] || fatal "gateway RAM is not the shipped 512 MB — run post-install first"; fi
for key in isolation.tools.copy.disable isolation.tools.paste.disable isolation.tools.dnd.disable isolation.tools.hgfs.disable; do
  [ "$(vmx_get "$key" | tr '[:lower:]' '[:upper:]')" = "TRUE" ] || fatal "$key is not TRUE in the vmx"
done
[ "$(vmx_get isolation.tools.setGUIOptions.enable | tr '[:lower:]' '[:upper:]')" = "FALSE" ] \
  || fatal "isolation.tools.setGUIOptions.enable is not FALSE in the vmx"

OVA="$OUT_DIR/ombra-$TARGET-arm64-v$VERSION.ova"
rm -f "$OVA" "$OVA".part-*
LOG="$STAGE/ovftool.log"
echo "exporting $OVA (the disk is compressed; encrypted data does not shrink)"
if ! "$OVFTOOL" --acceptAllEulas --exportFlags=extraconfig --compress=9 --shaAlgorithm=SHA256 "$VMX" "$OVA" >"$LOG" 2>&1; then
  tail -n 20 "$LOG" >&2
  fatal "ovftool export failed"
fi
[ -s "$OVA" ] || fatal "ovftool produced no output"

LISTING="$(tar -tf "$OVA")" || fatal "OVA is not a readable tar"
for ext in ovf mf 'vmdk(\.gz)?'; do
  printf '%s\n' "$LISTING" | grep -qE "\.$ext\$" || fatal "OVA has no .$ext member"
done
OVFNAME="$(printf '%s\n' "$LISTING" | grep -E '\.ovf$' | head -1)"
MFNAME="$(printf '%s\n' "$LISTING" | grep -E '\.mf$' | head -1)"
if tar -xOf "$OVA" "$OVFNAME" | grep -qE "$PERSONAL"; then
  fatal "personal string found in the OVA descriptor"
fi
MF="$(tar -xOf "$OVA" "$MFNAME")"
[ -n "$MF" ] || fatal "OVA manifest is empty"
if printf '%s\n' "$MF" | grep -vqE '^SHA256\('; then
  fatal "OVA manifest has non-SHA256 entries"
fi

if [ "${OMBRA_SPLIT:-0}" = 1 ] && [ "$(stat -f %z "$OVA")" -gt "$LIMIT" ]; then
  split -b "$PART_SIZE" "$OVA" "$OVA.part-"
  rm -f "$OVA"
fi

cd "$OUT_DIR"
: > SHA256SUMS.txt.new
for f in ombra-*.ova ombra-*.ova.part-*; do
  [ -f "$f" ] || continue
  bytes="$(stat -f %z "$f")"
  printf '%12s bytes  %s\n' "$bytes" "$f"
  if [ "${OMBRA_SPLIT:-0}" = 1 ]; then
    [ "$bytes" -le "$LIMIT" ] || fatal "$f is $bytes bytes — over GitHub's 2 GiB per-asset release cap"
  fi
  shasum -a 256 "$f" >> SHA256SUMS.txt.new
done
mv SHA256SUMS.txt.new SHA256SUMS.txt
echo "done: $TARGET (sums: $OUT_DIR/SHA256SUMS.txt)"
