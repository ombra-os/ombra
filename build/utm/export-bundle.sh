#!/bin/bash
#
# export-bundle.sh — turn a powered-off, freshly installed Fusion-built VM into a distributable
# UTM archive. The disk is the SAME image the Fusion archive carries (converted to qcow2); only the
# hypervisor wrapper differs. The wrapper keeps the guest's hardware (NVMe disk, vmxnet3 and e1000e
# NICs) so the disk and NIC names the guest code relies on stay identical, and it turns every
# host-guest channel off: no clipboard sharing, no shared folder, no USB sharing, no serial port.
# Run AFTER the post-install runbook, BEFORE first boot.
#
# Needs qemu-img (brew install qemu) and UTM.app (its blank UEFI variable store ships in the bundle).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VMROOT="${HOME}/Virtual Machines.localized"
VERSION="${OMBRA_VERSION:-1.1.0}"
OUT_DIR="${OMBRA_RELEASE_DIR:-$REPO/build/releases}"
UTM_VARS="/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd"

usage() {
  cat <<EOF2
usage: bash build/utm/export-bundle.sh <desktop|gateway> [vmx-path] [--allow-test]

  The Fusion VM must be powered OFF and post-install (the desktop must never have been booted).
  Writes <outdir>/ombra-<target>-arm64-v$VERSION.utm.zip and runs verify-bundle.sh on it.
  --allow-test  accept a TEST build and write ombra-<target>-TEST.utm (no zip, no release
                name) into OMBRA_RELEASE_DIR; for end-to-end testing only, never published.

  env: OMBRA_VERSION (default $VERSION), OMBRA_RELEASE_DIR (default build/releases)
EOF2
}

fatal() { echo "FATAL: $*" >&2; exit 1; }

TARGET="${1:-}"
if [ "$TARGET" != "desktop" ] && [ "$TARGET" != "gateway" ]; then usage; exit 2; fi
shift
SRC_VMX=""; ALLOW_TEST=0
for arg in "$@"; do
  case "$arg" in
    --allow-test) ALLOW_TEST=1 ;;
    *) SRC_VMX="$arg" ;;
  esac
done
SRC_VMX="${SRC_VMX:-$VMROOT/ombra-$TARGET.vmwarevm/ombra-$TARGET.vmx}"
[ -f "$SRC_VMX" ] || fatal "vmx not found: $SRC_VMX"
command -v qemu-img >/dev/null || fatal "qemu-img not found (brew install qemu)"
[ -f "$UTM_VARS" ] || fatal "UTM.app not found: $UTM_VARS is its blank UEFI variable store"
command -v python3 >/dev/null || fatal "python3 not found"
mkdir -p "$OUT_DIR"

VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
if [ -x "$VMRUN" ]; then
  RUNNING="$("$VMRUN" -T fusion list 2>&1)" || fatal "vmrun list failed — cannot tell whether the VM is running: $RUNNING"
  if printf '%s\n' "$RUNNING" | grep -qF "$SRC_VMX"; then
    fatal "VM is running — power it off first (export is pre-first-boot by design)"
  fi
fi
IS_TEST=0
if grep -qE '\-test\.iso' "$SRC_VMX" || grep -qE '^displayName = .*TEST' "$SRC_VMX"; then IS_TEST=1; fi
if [ "$IS_TEST" = 1 ] && [ "$ALLOW_TEST" != 1 ]; then
  fatal "the vmx references a test-build ISO or is named TEST — test builds are never exported (use --allow-test for a local end-to-end test)"
fi
if [ "$IS_TEST" = 0 ] && [ "$ALLOW_TEST" = 1 ]; then
  fatal "--allow-test is only for TEST builds"
fi

vmx_get() { awk -F' = ' -v k="$1" 'tolower($1)==tolower(k) {gsub(/"/,"",$2); print $2; exit}' "$SRC_VMX"; }
DISK_NAME="$(vmx_get nvme0:0.fileName)"
[ -n "$DISK_NAME" ] || fatal "the vmx has no NVMe disk (nvme0:0.fileName) — wrong VM?"
SRC_DIR="$(dirname "$SRC_VMX")"
[ -f "$SRC_DIR/$DISK_NAME" ] || fatal "disk descriptor missing: $SRC_DIR/$DISK_NAME"
MEM_MB="$(vmx_get memsize)"; CPUS="$(vmx_get numvcpus)"
[ -n "$MEM_MB" ] && [ -n "$CPUS" ] || fatal "the vmx lacks memsize or numvcpus"
if [ "$TARGET" = gateway ] && { [ "$(vmx_get ethernet0.connectionType)" != nat ] || [ "$(vmx_get ethernet1.connectionType)" != hostonly ]; }; then
  fatal "gateway NICs must be NAT then hostonly"
fi
if [ "$TARGET" = desktop ] && [ "$(vmx_get ethernet0.connectionType)" != hostonly ]; then
  fatal "the desktop's one NIC must be hostonly"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
BUNDLE="$STAGE/ombra-$TARGET.utm"
mkdir -p "$BUNDLE/Data"

echo "converting the disk to qcow2 (this reads the whole disk) ..."
DISK_FILE="ombra-$TARGET.qcow2"
qemu-img convert -f vmdk -O qcow2 "$SRC_DIR/$DISK_NAME" "$BUNDLE/Data/$DISK_FILE" || fatal "qemu-img convert failed"
cp "$UTM_VARS" "$BUNDLE/Data/efi_vars.fd"

python3 - "$TARGET" "$BUNDLE/config.plist" "$DISK_FILE" "$MEM_MB" "$CPUS" <<'PY'
import plistlib, sys, uuid, random

target, out, disk, mem, cpus = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

def mac():
    # locally administered, unicast; a fresh one per export, never a vendor prefix
    b = [random.randrange(256) for _ in range(6)]
    b[0] = (b[0] | 0x02) & 0xFE
    return ":".join("%02X" % x for x in b)

# The private link: UTM's host-only network on its own subnet, different from the guests' static 10.55.10.x,
# so the Mac itself has no address on the guests' subnet (same as under Fusion).
LINK = {"Mode": "Host", "VlanGuestAddress": "10.55.20.0/24",
        "VlanDhcpStartAddress": "10.55.20.100", "VlanDhcpEndAddress": "10.55.20.200"}

def nic(hw, extra):
    d = {"Hardware": hw, "IsolateFromHost": False, "MacAddress": mac(), "PortForward": []}
    d.update(extra)
    return d

if target == "gateway":
    network = [nic("vmxnet3", {"Mode": "Shared"}), nic("e1000e", dict(LINK))]
else:
    network = [nic("vmxnet3", dict(LINK))]

cfg = {
    "Backend": "QEMU",
    "ConfigurationVersion": 4,
    "Display": [{
        # a Retina window is scaled by exactly 2: nearest keeps text crisp, linear blurs it; shrinking uses linear
        "DownscalingFilter": "Linear", "UpscalingFilter": "Nearest",
        "DynamicResolution": target == "desktop", "NativeResolution": False,
        "Hardware": "virtio-gpu-pci",
    }],
    "Drive": [{
        "Identifier": str(uuid.uuid4()).upper(), "ImageName": disk, "ImageType": "Disk",
        "Interface": "NVMe", "InterfaceVersion": 1, "ReadOnly": False,
    }],
    "Information": {"IconCustom": False, "Name": "ombra-" + target, "UUID": str(uuid.uuid4()).upper()},
    # USB support must stay on: UTM attaches the keyboard and pointer over USB, so with it off the guest could not
    # type its unlock passphrase. UsbSharing off means no host USB device is offered to the guest.
    "Input": {"MaximumUsbShare": 3, "UsbBusSupport": "3.0", "UsbSharing": False},
    "Network": network,
    "QEMU": {
        # UTM 5.0.8's QEMU (10.0.12) does not reset the hypervisor's interrupt controller on a guest restart, so the next
        # boot hangs before the kernel prints anything ("Display output is not active"). Running the controller in QEMU
        # itself avoids it: reproduced 3 of 3 without the flag, 0 of 3 with it. Costs about 15% of a core at idle.
        "AdditionalArguments": ["-machine kernel-irqchip=off"], "BalloonDevice": False, "DebugLog": False, "Hypervisor": True,
        "PS2Controller": False, "RNGDevice": True, "RTCLocalTime": False, "TPMDevice": False,
        "TSO": False, "UEFIBoot": True,
    },
    "Serial": [],
    "Sharing": {"ClipboardSharing": False, "DirectoryShareMode": "None", "DirectoryShareReadOnly": False},
    "Sound": [],
    "System": {
        "Architecture": "aarch64", "CPU": "default", "CPUCount": cpus,
        "CPUFlagsAdd": [], "CPUFlagsRemove": [], "ForceMulticore": False, "JITCacheSize": 0,
        "MemorySize": mem, "Target": "virt",
    },
}
with open(out, "wb") as f:
    plistlib.dump(cfg, f, fmt=plistlib.FMT_XML)
PY

if [ "$IS_TEST" = 1 ]; then
  DEST="$OUT_DIR/ombra-$TARGET-TEST.utm"
  rm -rf "${DEST:?}"
  mv "$BUNDLE" "$DEST"
  echo "TEST bundle written: $DEST (never zip, publish or ship this)"
  bash "$HERE/verify-bundle.sh" "$TARGET" "$DEST" --allow-test
  exit 0
fi

ZIP="$OUT_DIR/ombra-$TARGET-arm64-v$VERSION.utm.zip"
rm -f "$ZIP"
( cd "$STAGE" && ditto -c -k --keepParent --noqtn --norsrc --noextattr --zlibCompressionLevel 1 "ombra-$TARGET.utm" "$ZIP" )
bash "$HERE/verify-bundle.sh" "$TARGET" "$ZIP" || { rm -f "$ZIP"; fatal "the archive failed verification and was removed"; }
# one SHA256SUMS.txt for every archive present, Fusion and UTM alike (the Fusion exporter does the same)
( cd "$OUT_DIR" && : > SHA256SUMS.txt.new && for f in ombra-*.vmwarevm.zip ombra-*.utm.zip; do
    [ -f "$f" ] || continue
    printf '%12s bytes  %s\n' "$(stat -f %z "$f")" "$f"
    shasum -a 256 "$f" >> SHA256SUMS.txt.new
  done && mv SHA256SUMS.txt.new SHA256SUMS.txt )
echo "done: $ZIP ($(du -h "$ZIP" | awk '{print $1}'))"
