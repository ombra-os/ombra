#!/bin/bash
# tests/build/test-utm-verify.sh — the UTM bundle verifier must pass a correct bundle and fail every
# bundle that opens a host-guest channel or changes the hardware the guest code relies on.
# Needs qemu-img (brew install qemu); builds synthetic bundles, never touches a real VM.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERIFY="$REPO/build/utm/verify-bundle.sh"
TMP="$(mktemp -d /tmp/ombra-utmtest.XXXXXX)"
trap 'rm -rf "${TMP:?}"' EXIT

FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

command -v qemu-img >/dev/null || { echo "FAIL: qemu-img missing (brew install qemu)"; exit 1; }

# make_bundle <dir> <target>: a bundle shaped exactly like build/utm/export-bundle.sh writes
make_bundle() {
  local dir="$1" target="$2" size
  case "$target" in gateway) size=5G ;; desktop) size=30G ;; esac
  mkdir -p "$dir/ombra-$target.utm/Data"
  qemu-img create -q -f qcow2 "$dir/ombra-$target.utm/Data/ombra-$target.qcow2" "$size"
  printf 'blank' > "$dir/ombra-$target.utm/Data/efi_vars.fd"
  python3 - "$target" "$dir/ombra-$target.utm/config.plist" <<'PY'
import plistlib, sys
target, out = sys.argv[1], sys.argv[2]
link = {"Mode": "Host", "VlanGuestAddress": "10.55.20.0/24", "VlanDhcpStartAddress": "10.55.20.100", "VlanDhcpEndAddress": "10.55.20.200"}
def nic(hw, mac, extra):
    d = {"Hardware": hw, "IsolateFromHost": False, "MacAddress": mac, "PortForward": []}; d.update(extra); return d
network = [nic("vmxnet3", "32:3F:C2:78:FA:A3", {"Mode": "Shared"}), nic("e1000e", "46:45:44:86:17:45", dict(link))] if target == "gateway" \
    else [nic("vmxnet3", "76:AF:D3:D2:79:4B", dict(link))]
cfg = {
    "Backend": "QEMU", "ConfigurationVersion": 4,
    "Display": [{"DownscalingFilter": "Linear", "UpscalingFilter": "Nearest", "DynamicResolution": target == "desktop", "NativeResolution": False, "Hardware": "virtio-gpu-pci"}],
    "Drive": [{"Identifier": "9842A613-1EC7-40E2-A74A-5CF4391D0FCC", "ImageName": "ombra-%s.qcow2" % target, "ImageType": "Disk", "Interface": "NVMe", "InterfaceVersion": 1, "ReadOnly": False}],
    "Information": {"IconCustom": False, "Name": "ombra-" + target, "UUID": "11111111-2222-3333-4444-555555555555"},
    "Input": {"MaximumUsbShare": 3, "UsbBusSupport": "3.0", "UsbSharing": False},
    "Network": network,
    "QEMU": {"AdditionalArguments": ["-machine kernel-irqchip=off"], "BalloonDevice": False, "DebugLog": False, "Hypervisor": True, "PS2Controller": False, "RNGDevice": True, "RTCLocalTime": False, "TPMDevice": False, "TSO": False, "UEFIBoot": True},
    "Serial": [], "Sharing": {"ClipboardSharing": False, "DirectoryShareMode": "None", "DirectoryShareReadOnly": False}, "Sound": [],
    "System": {"Architecture": "aarch64", "CPU": "default", "CPUCount": 2, "CPUFlagsAdd": [], "CPUFlagsRemove": [], "ForceMulticore": False, "JITCacheSize": 0, "MemorySize": 1024, "Target": "virt"},
}
plistlib.dump(cfg, open(out, "wb"), fmt=plistlib.FMT_XML)
PY
}

# mutate <dir> <target> <python expression on cfg>
mutate() {
  python3 - "$1/ombra-$2.utm/config.plist" "$3" <<'PY'
import plistlib, sys
p, expr = sys.argv[1], sys.argv[2]
cfg = plistlib.load(open(p, "rb")); exec(expr); plistlib.dump(cfg, open(p, "wb"), fmt=plistlib.FMT_XML)
PY
}

expect_pass() { # <label> <target> <dir>
  if bash "$VERIFY" "$2" "$3/ombra-$2.utm" --allow-test >"$TMP/out.txt" 2>&1; then ok "$1"; else bad "$1"; sed 's/^/       /' "$TMP/out.txt" | grep FAIL | head -3; fi
}
expect_fail() { # <label> <target> <dir>
  if bash "$VERIFY" "$2" "$3/ombra-$2.utm" --allow-test >"$TMP/out.txt" 2>&1; then bad "$1 (verifier passed a broken bundle)"; else ok "$1"; fi
}

echo "== correct bundles pass =="
for t in gateway desktop; do
  make_bundle "$TMP/good-$t" "$t"
  expect_pass "a correct $t bundle passes" "$t" "$TMP/good-$t"
done

echo "== every opened channel or changed device is refused =="
broken() { # <label> <target> <python mutation>
  local d="$TMP/b-$RANDOM"; make_bundle "$d" "$2"; mutate "$d" "$2" "$3"; expect_fail "$1" "$2" "$d"
}
broken "clipboard sharing on"                        desktop 'cfg["Sharing"]["ClipboardSharing"] = True'
broken "a shared folder"                             desktop 'cfg["Sharing"]["DirectoryShareMode"] = "VirtFS"'
broken "USB sharing on"                              desktop 'cfg["Input"]["UsbSharing"] = True'
broken "a serial port"                               desktop 'cfg["Serial"] = [{"Mode": "Ptty", "Target": "Auto"}]'
broken "a sound device"                              desktop 'cfg["Sound"] = [{"Hardware": "intel-hda"}]'
broken "an extra QEMU argument"                      desktop 'cfg["QEMU"]["AdditionalArguments"].append("-vnc 127.0.0.1:1")'
broken "a different QEMU argument instead"           desktop 'cfg["QEMU"]["AdditionalArguments"] = ["-vnc 127.0.0.1:1"]'
broken "the interrupt-controller argument missing"   desktop 'cfg["QEMU"]["AdditionalArguments"] = []'
broken "the same fix missing on the gateway"         gateway 'cfg["QEMU"]["AdditionalArguments"] = []'
broken "a TPM device"                                desktop 'cfg["QEMU"]["TPMDevice"] = True'
broken "the GL display card"                         desktop 'cfg["Display"][0]["Hardware"] = "virtio-gpu-gl-pci"'
broken "a virtio disk instead of NVMe"               desktop 'cfg["Drive"][0]["Interface"] = "VirtIO"'
broken "a second NIC on the desktop"                 desktop 'cfg["Network"].append(dict(cfg["Network"][0], MacAddress="02:00:00:00:00:09"))'
broken "the desktop NIC on NAT"                      desktop 'cfg["Network"][0]["Mode"] = "Shared"'
broken "the desktop NIC bridged"                     desktop 'cfg["Network"][0]["Mode"] = "Bridged"'
broken "a port forward on the private link"          desktop 'cfg["Network"][0]["PortForward"] = [{"Protocol": "TCP"}]'
broken "the private link on the guests' own subnet"  desktop 'cfg["Network"][0]["VlanGuestAddress"] = "10.55.10.0/24"'
broken "duplicate MAC addresses"                     gateway 'cfg["Network"][1]["MacAddress"] = cfg["Network"][0]["MacAddress"]'
broken "gateway private link on NAT too"            gateway 'cfg["Network"][1]["Mode"] = "Shared"'
broken "gateway upstream not on NAT"                 gateway 'cfg["Network"][0]["Mode"] = "Host"'
broken "wrong architecture"                          desktop 'cfg["System"]["Architecture"] = "x86_64"'
broken "the builder's home path in the config"       desktop "cfg['Information']['Name'] = '$HOME/vm'"

echo "== disk checks =="
d="$TMP/disk1"; make_bundle "$d" desktop; qemu-img create -q -f qcow2 "$d/ombra-desktop.utm/Data/ombra-desktop.qcow2" 10G
expect_fail "wrong disk size" desktop "$d"
d="$TMP/disk2"; make_bundle "$d" desktop; touch "$d/ombra-desktop.utm/Data/.DS_Store"
expect_fail "macOS litter in the bundle" desktop "$d"
d="$TMP/disk3"; make_bundle "$d" desktop; : > "$d/ombra-desktop.utm/Data/ombra-desktop.qcow2"
expect_fail "an empty disk file" desktop "$d"

echo "== archive checks =="
d="$TMP/zip1"; make_bundle "$d" gateway
( cd "$d" && ditto -c -k --keepParent --noqtn --norsrc --noextattr ombra-gateway.utm clean.zip )
if bash "$VERIFY" gateway "$d/clean.zip" --allow-test >"$TMP/out.txt" 2>&1; then ok "a clean archive passes"; else bad "a clean archive passes"; fi
mkdir -p "$d/dirtyroot" && cp -R "$d/ombra-gateway.utm" "$d/dirtyroot/" && touch "$d/dirtyroot/ombra-gateway.utm/._config.plist"
( cd "$d/dirtyroot" && ditto -c -k --keepParent --noqtn --norsrc --noextattr ombra-gateway.utm ../dirty.zip )
if bash "$VERIFY" gateway "$d/dirty.zip" --allow-test >"$TMP/out.txt" 2>&1; then bad "an archive with AppleDouble files (verifier passed it)"; else ok "an archive with AppleDouble files is refused"; fi

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS test(s)"; exit 1; fi
echo "ALL PASS"
