#!/bin/bash
#
# verify-bundle.sh — unpack a release .vmwarevm.zip into a scratch directory and assert
# the shape of the VM inside. The checks that matter most are the ones an OVA could not
# carry: an ARM guest id, Fusion's own tools accepting the files, and a disk whose
# sparse index is intact. Usage: verify-bundle.sh <ombra-*.vmwarevm.zip>

set -euo pipefail

IN="${1:-}"
[ -f "$IN" ] || { echo "usage: verify-bundle.sh <ombra-*.vmwarevm.zip>" >&2; exit 2; }
NAME="$(basename "$IN")"
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
VDISK="/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
ditto -x -k "$IN" "$TMP" || { echo "FATAL: not a readable zip" >&2; exit 1; }

FAILS=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS+1)); fi; }

BUNDLES="$(find "$TMP" -maxdepth 1 -name '*.vmwarevm' -type d)"
check "exactly one .vmwarevm at the top of the archive" '[ "$(printf "%s\n" "$BUNDLES" | grep -c .)" = 1 ]'
BUNDLE="$(printf '%s\n' "$BUNDLES" | head -1)"
VMX="$(find "$BUNDLE" -maxdepth 1 -name '*.vmx' | head -1)"
[ -f "$VMX" ] || { echo "FATAL: no vmx in the bundle" >&2; exit 1; }

vmx_get() { awk -F= -v k="$1" '{kk=$1; gsub(/^[ \t]+|[ \t]+$/, "", kk); if (tolower(kk)==tolower(k)) {v=substr($0, index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v); print v; exit}}' "$VMX"; }

check "guestOS is an ARM id" 'case "$(vmx_get guestOS)" in arm-*) true ;; *) false ;; esac'
check "firmware is efi" '[ "$(vmx_get firmware)" = "efi" ]'
check "virtualHW.version is a number" '[[ "$(vmx_get virtualHW.version)" =~ ^[0-9]+$ ]]'
check "uuid.action is keep (no moved-or-copied question)" '[ "$(vmx_get uuid.action)" = "keep" ]'
check "snapshots are disabled" '[ "$(vmx_get snapshot.disabled | tr "[:lower:]" "[:upper:]")" = "TRUE" ]'
check "no build-host identity: uuid.bios, uuid.location, generated MACs" \
  '! grep -qiE "^(uuid\.bios|uuid\.location|ethernet[0-9]+\.generatedAddress)" "$VMX"'
check "no debug channels (VNC, serial)" '! grep -qiE "^(RemoteDisplay|serial[0-9]+)\." "$VMX"'
check "installer CD is empty and never connected" \
  '[ "$(vmx_get sata0:0.startConnected | tr "[:upper:]" "[:lower:]")" = "false" ] && [ "$(vmx_get sata0:0.fileName)" = "auto detect" ]'
check "boot order is disk first" '[ "$(vmx_get bios.bootOrder)" = "hdd,cdrom" ]'

case "$NAME" in
  *gateway*)
    check "ethernet0.virtualDev is vmxnet3" '[ "$(vmx_get ethernet0.virtualDev)" = "vmxnet3" ]'
    check "ethernet1.virtualDev is e1000e" '[ "$(vmx_get ethernet1.virtualDev)" = "e1000e" ]'
    check "ethernet0 is nat" '[ "$(vmx_get ethernet0.connectionType)" = "nat" ]'
    check "ethernet1 is hostonly" '[ "$(vmx_get ethernet1.connectionType)" = "hostonly" ]' ;;
  *desktop*)
    check "ethernet0 is hostonly" '[ "$(vmx_get ethernet0.connectionType)" = "hostonly" ]' ;;
  *) check "archive name contains gateway or desktop" 'false' ;;
esac
upper() { tr '[:lower:]' '[:upper:]'; }
for key in isolation.tools.copy.disable isolation.tools.paste.disable isolation.tools.dnd.disable isolation.tools.hgfs.disable; do
  check "$key is TRUE" '[ "$(vmx_get "$key" | upper)" = TRUE ]'
done
check "isolation.tools.setGUIOptions.enable is FALSE" '[ "$(vmx_get isolation.tools.setGUIOptions.enable | upper)" = FALSE ]'
check "time sync with the host is off" '[ "$(vmx_get tools.syncTime | upper)" = FALSE ]'
check "the clock is presented in UTC (rtc.diffFromUTC = 0)" '[ "$(vmx_get rtc.diffFromUTC)" = 0 ]'
check "the installer CD is an empty drive" '[ "$(vmx_get sata0:0.deviceType)" = cdrom-raw ]'
NICS="$(grep -ciE '^ethernet[0-9]+\.present *= *"true"' "$VMX" || true)"
case "$NAME" in
  *gateway*) check "exactly two network adapters" '[ "$NICS" = 2 ]'
             check "the headless gateway has no sound card" '[ "$(vmx_get sound.present | upper)" != TRUE ]' ;;
  *desktop*) check "exactly one network adapter" '[ "$NICS" = 1 ]' ;;
esac

check "no builder residue files (locks, logs, plists, memory, snapshots)" \
  '[ -z "$(find "$BUNDLE" \( -name "*.lck" -o -name "*.log" -o -name "*.plist" -o -name "*.vmem" -o -name "*.vmss" -o -name "*.vmsn" -o -name "*.vmsd" -o -name "*.bak" \) | head -1)" ]'
check "no macOS archive litter (__MACOSX, ._ files)" \
  '[ -z "$(find "$TMP" \( -name "__MACOSX" -o -name "._*" \) | head -1)" ]'

PERSONAL='/Us''ers/|/priv''ate/|co''dy|hac''cer'
check "no personal strings in the bundle's text files" '! grep -rIlE "$PERSONAL" "$BUNDLE" >/dev/null 2>&1'

check "no NIC is pinned to a static address" '! grep -qiE "^ethernet[0-9]+\.addressType *= *\"static\"" "$VMX"'
DISK="$(vmx_get nvme0:0.fileName)"
check "the disk file exists beside the vmx" '[ -n "$DISK" ] && [ -f "$BUNDLE/$DISK" ]'
# the build disk is split (twoGbMaxExtentSparse): a text descriptor plus extent files that each start with KDMV
sparse_ok() {
  local f="$BUNDLE/$DISK" ext n=0
  if [ "$(head -c 4 "$f")" = "KDMV" ]; then return 0; fi
  grep -aq '^createType="\(monolithicSparse\|twoGbMaxExtentSparse\)"' "$f" || return 1
  for ext in $(sed -n 's/^RW [0-9]* SPARSE "\(.*\)"$/\1/p' "$f" | tr ' ' '#'); do
    ext="${ext//#/ }"
    [ "$(head -c 4 "$(dirname "$f")/$ext")" = "KDMV" ] || return 1
    n=$((n + 1))
  done
  [ "$n" -ge 1 ]
}
check "the disk is a VMware sparse disk (every extent has the sparse header)" 'sparse_ok'
if [ -x "$VDISK" ]; then
  check "Fusion's disk tool reports the disk consistent" '"$VDISK" -e "$BUNDLE/$DISK" >/dev/null 2>&1'
fi
if [ -x "$VMRUN" ]; then
  check "vmrun can read the VM" '"$VMRUN" -T fusion listSnapshots "$VMX" >/dev/null 2>&1'
fi

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
echo "ALL PASS"
