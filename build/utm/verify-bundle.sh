#!/bin/bash
#
# verify-bundle.sh — assert the shape of an Ombra UTM bundle (a .utm directory or an ombra-*.utm.zip):
# the hardware the guest code relies on, every host-guest channel off, and a disk that is intact.
# Usage: verify-bundle.sh <desktop|gateway> <bundle.utm | archive.utm.zip> [--allow-test]

set -euo pipefail

TARGET="${1:-}"; IN="${2:-}"; ALLOW_TEST=0
[ "${3:-}" = "--allow-test" ] && ALLOW_TEST=1
case "$TARGET" in desktop|gateway) ;; *) echo "usage: verify-bundle.sh <desktop|gateway> <bundle> [--allow-test]" >&2; exit 2 ;; esac
[ -e "$IN" ] || { echo "usage: verify-bundle.sh <desktop|gateway> <bundle> [--allow-test]" >&2; exit 2; }
command -v qemu-img >/dev/null || { echo "FATAL: qemu-img not found (brew install qemu)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
if [ ! -d "$IN" ]; then
  # inspect the archive's own listing: extracting with ditto would silently merge AppleDouble files back into extended attributes
  ZLIST="$(unzip -Z1 "$IN" 2>/dev/null)" || { echo "FATAL: not a readable zip" >&2; exit 1; }
  if printf '%s\n' "$ZLIST" | grep -q -E '(^|/)\._|__MACOSX|\.DS_Store'; then
    echo "FAIL  the archive carries macOS metadata files (AppleDouble, __MACOSX or .DS_Store)"; ZIPLITTER=1
  fi
fi
if [ -d "$IN" ]; then
  mkdir -p "$TMP/x"; cp -cR "$IN" "$TMP/x/" 2>/dev/null || cp -R "$IN" "$TMP/x/"
else
  mkdir -p "$TMP/x"; ditto -x -k "$IN" "$TMP/x" || { echo "FATAL: not a readable zip" >&2; exit 1; }
fi

FAILS=${ZIPLITTER:-0}
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS+1)); fi; }

BUNDLES="$(find "$TMP/x" -maxdepth 1 -name '*.utm' -type d)"
check "exactly one .utm at the top" '[ "$(printf "%s\n" "$BUNDLES" | grep -c .)" = 1 ]'
B="$(printf '%s\n' "$BUNDLES" | head -1)"
CFG="$B/config.plist"
check "config.plist exists and parses" '[ -f "$CFG" ] && plutil -lint "$CFG" >/dev/null 2>&1'
[ -f "$CFG" ] || { echo "FATAL: no config.plist"; exit 1; }

# one value out of the plist, as text
pv() { python3 -c "import plistlib,sys; c=plistlib.load(open(sys.argv[1],'rb'))
for p in sys.argv[2].split('.'): c=c[int(p)] if isinstance(c,list) else c[p]
print(c)" "$CFG" "$1"; }
plen() { python3 -c "import plistlib,sys; c=plistlib.load(open(sys.argv[1],'rb'))
for p in sys.argv[2].split('.'): c=c[int(p)] if isinstance(c,list) else c[p]
print(len(c))" "$CFG" "$1"; }

check "QEMU backend, aarch64 on the virt machine, UEFI boot, hypervisor on" \
  '[ "$(pv Backend)" = QEMU ] && [ "$(pv System.Architecture)" = aarch64 ] && [ "$(pv System.Target)" = virt ] && [ "$(pv QEMU.UEFIBoot)" = True ] && [ "$(pv QEMU.Hypervisor)" = True ]'
check "exactly one additional QEMU argument, the software interrupt controller that makes a guest restart boot again" \
  '[ "$(plen QEMU.AdditionalArguments)" = 1 ] && [ "$(pv QEMU.AdditionalArguments.0)" = "-machine kernel-irqchip=off" ]'
check "no TPM, no balloon, no debug log" \
  '[ "$(pv QEMU.TPMDevice)" = False ] && [ "$(pv QEMU.BalloonDevice)" = False ] && [ "$(pv QEMU.DebugLog)" = False ]'
check "clipboard sharing is OFF" '[ "$(pv Sharing.ClipboardSharing)" = False ]'
check "no shared folder" '[ "$(pv Sharing.DirectoryShareMode)" = None ]'
check "no USB sharing, and USB support left on (UTM's keyboard and pointer need it)" '[ "$(pv Input.UsbSharing)" = False ] && [ "$(pv Input.UsbBusSupport)" != Disabled ]'
check "display scaling: nearest up, linear down (crisp text on a Retina screen)" '[ "$(pv Display.0.UpscalingFilter)" = Nearest ] && [ "$(pv Display.0.DownscalingFilter)" = Linear ]'
check "no serial port and no sound device" '[ "$(plen Serial)" = 0 ] && [ "$(plen Sound)" = 0 ]'
check "one display, virtio-gpu-pci" '[ "$(plen Display)" = 1 ] && [ "$(pv Display.0.Hardware)" = virtio-gpu-pci ]'
check "exactly one drive: an NVMe disk" '[ "$(plen Drive)" = 1 ] && [ "$(pv Drive.0.Interface)" = NVMe ] && [ "$(pv Drive.0.ImageType)" = Disk ] && [ "$(pv Drive.0.ReadOnly)" = False ]'

case "$TARGET" in
  gateway)
    check "gateway NICs: vmxnet3 on the shared NAT, then e1000e on the host-only private link" \
      '[ "$(plen Network)" = 2 ] && [ "$(pv Network.0.Hardware)" = vmxnet3 ] && [ "$(pv Network.0.Mode)" = Shared ] && [ "$(pv Network.1.Hardware)" = e1000e ] && [ "$(pv Network.1.Mode)" = Host ]'
    LINKNIC=1; WANT_SIZE=5368709120 ;;
  desktop)
    check "desktop has ONE NIC: vmxnet3 on the host-only private link, no NAT, no bridge" \
      '[ "$(plen Network)" = 1 ] && [ "$(pv Network.0.Hardware)" = vmxnet3 ] && [ "$(pv Network.0.Mode)" = Host ]'
    LINKNIC=0; WANT_SIZE=32212254720 ;;
esac
check "the private link has its own subnet (10.55.20.0/24), not the guests' static 10.55.10.0/24, and no port forwards" \
  '[ "$(pv Network.$LINKNIC.VlanGuestAddress)" = 10.55.20.0/24 ] && [ "$(plen Network.$LINKNIC.PortForward)" = 0 ]'
macs_ok() { python3 -c "import plistlib,sys; m=[n['MacAddress'] for n in plistlib.load(open(sys.argv[1],'rb'))['Network']]
assert len(set(m))==len(m)
assert all((int(x.split(':')[0],16)&2) and not (int(x.split(':')[0],16)&1) for x in m), m" "$CFG"; }
check "every NIC has its own locally administered unicast MAC" 'macs_ok'

DISK="$B/Data/$(pv Drive.0.ImageName)"
check "the disk file exists beside the config" '[ -f "$DISK" ]'
if [ -f "$DISK" ]; then
  INFO="$(qemu-img info --output=json "$DISK")"
  check "the disk is a qcow2 with no backing file" 'printf "%s" "$INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"format\"]==\"qcow2\" and \"backing-filename\" not in d"'
  check "the disk is the expected size ($WANT_SIZE bytes)" 'printf "%s" "$INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"virtual-size\"]==$WANT_SIZE"'
  check "qemu-img reports the disk consistent" 'qemu-img check "$DISK" >/dev/null 2>&1'
fi
check "the UEFI variable store is present" '[ -s "$B/Data/efi_vars.fd" ]'
check "nothing else is in the bundle (no locks, logs, screenshots, snapshots, macOS litter)" \
  '[ "$(find "$B" -type f ! -name config.plist ! -name efi_vars.fd ! -name "$(basename "$DISK")" | wc -l | tr -d " ")" = 0 ] && ! find "$TMP/x" \( -name __MACOSX -o -name "._*" -o -name .DS_Store \) | grep -q .'
check "no personal strings in the config (the builder's home path or account name)" '! grep -qF -e "$HOME" -e "$(id -un)" "$CFG"'
if [ "$ALLOW_TEST" = 1 ]; then
  echo "NOTE  test-build bundle: checked for shape only, not for release"
fi

echo
if [ "$FAILS" = 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
