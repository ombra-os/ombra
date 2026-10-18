#!/bin/bash
# desktop VM on VMware Fusion: derived from the proven gateway template (drop NIC2; 6GB/4vCPU; 30GB NVMe; 3D+sound on).
# Install on NAT with pinned MAC 00:50:56:2a:00:10; the intnet swap afterwards is a host-side change. Disk stays persistent.

set -u

APP="/Applications/VMware Fusion.app"
VMRUN="$APP/Contents/Public/vmrun"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DESKTOP_ISO="${OMBRA_DESKTOP_ISO:-$REPO/build/disks/ombra-install-desktop.iso}"
VMDIR="$HOME/Virtual Machines.localized"

# ---- preflight ------------------------------------------------------------

preflight() {
  [ -x "$VMRUN" ] || { echo "FATAL: vmrun not found at $VMRUN — install VMware Fusion" >&2; exit 1; }
  [ -f "$DESKTOP_ISO" ] || {
      echo "FATAL: build/disks/ombra-install-desktop.iso missing — build it:" >&2
      echo "  stage the pinned netinst in build/isos/ (build/pins/debian-netinst-arm64.txt)," >&2
      echo "  verify it: build/verify-iso.sh" >&2
      echo "  then:      build/make-install-iso.sh desktop" >&2
      exit 1
  }
  if [ -e "$VMDIR/ombra-desktop.vmwarevm" ]; then
      echo "NOTE: $VMDIR/ombra-desktop.vmwarevm already exists (remove if stale):" >&2
      echo "  rm -rf \"$VMDIR/ombra-desktop.vmwarevm\"" >&2
  fi
}

# ---- verify / fix ----------------------------------------------------------

# vmx keys are CASE-INSENSITIVE (Fusion writes some lowercase); all
# lookups fold case and the fixer preserves the file's key spelling.
vmx_get() { awk -F' = ' -v k="$1" 'tolower($1)==tolower(k) {gsub(/"/,"",$2); print $2; exit}' "$2"; }
vmx_has() { awk -F' = ' -v k="$1" 'tolower($1)==tolower(k){f=1} END{exit !f}' "$2"; }

FAILS=0; FIXMODE=0; VMX=""
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

check_eq() { # <label> <key> <want> <file> <fixvalue-or-"">
  local label="$1" key="$2" want="$3" file="$4" fix="$5" got
  got="$(vmx_get "$key" "$file")"
  if [ "$got" = "$want" ]; then ok "$label = $want"; return 0; fi
  if [ -n "$fix" ] && [ "$FIXMODE" = 1 ]; then
      if vmx_has "$key" "$file"; then
          python3 - "$file" "$key" "$fix" <<'PYEOF'
import sys
f, k, v = sys.argv[1:4]
out = []
for line in open(f):
    key = line.split(" = ", 1)[0].rstrip()
    if key.strip().lower() == k.lower():
        out.append('%s = "%s"\n' % (key, v))  # keep the file's spelling
    else:
        out.append(line)
open(f, "w").writelines(out)
PYEOF
      else
          printf '%s = "%s"\n' "$key" "$fix" >> "$file"
      fi
      ok "$label fixed -> $fix"
  else
      bad "$label: want '$want', got '${got:-missing}'${fix:+ (fixable with --fix)}"
  fi
}

verify() {
  if [ -z "$VMX" ]; then
      echo "locating a desktop vmx in $VMDIR ..."
      VMX="$( "$VMDIR"/*.vmwarevm/*.vmx 2>/dev/null | head -1)"
  fi
  if [ -z "$VMX" ] || [ ! -f "$VMX" ]; then
      echo "FATAL: no ombra-desktop vmx found in $VMDIR — pass the vmx path" >&2
      exit 1
  fi
  echo "== verifying $VMX =="
  if [ "$FIXMODE" = 1 ]; then cp "$VMX" "$VMX.pre-ombra"; echo "(backup: $VMX.pre-ombra)"; fi

  check_eq "RAM"         memSize       6144 "$VMX" 6144
  check_eq "vCPUs"       numvcpus      4    "$VMX" 4
  check_eq "installer CD" sata0:0.fileName "$DESKTOP_ISO" "$VMX" ""
  check_eq "NIC type (NAT for install)" ethernet0.connectionType nat "$VMX" nat
  check_eq "NIC MAC (pinned desktop role)" ethernet0.address 00:50:56:2a:00:10 "$VMX" 00:50:56:2a:00:10
  check_eq "NIC addrType" ethernet0.addressType static "$VMX" static
  check_eq "time sync OFF (time.synchronize.* set stays whole; runtime time is ombra-timesync over Tor)" tools.syncTime FALSE "$VMX" FALSE
  check_eq "3D ON (MKS/Metal; the session renders via software GL by policy)" mks.enable3d TRUE "$VMX" TRUE
  if vmx_get sound.present "$VMX" | grep -qi '^TRUE$'; then
      ok "sound card on (desktop keeps audio)"
  else
      warn "sound card off/absent — the image ships pipewire-audio; enable it in the UI"
  fi
  if vmx_has nvme0:0.mode "$VMX"; then
      bad "disk mode '$(vmx_get nvme0:0.mode "$VMX")' is set — the DESKTOP disk stays persistent (LUKS + user data); live mode is gateway-only"
  else
      ok "disk persistent (correct for the desktop)"
  fi
  VMDK="$(cd "$(dirname "$VMX")" && pwd)/$(vmx_get nvme0:0.fileName "$VMX")"
  if [ -f "$VMDK" ]; then
      secs=$(grep -ao 'RW [0-9]*' "$VMDK" | awk '{s+=$2} END{print s}')
      gb=$(( ${secs:-0} / 2097152 ))
      case "$gb" in
          30) ok "disk 30GB" ;;
          *)  warn "disk size reads ${gb}GB — expected 30GB; resize in the UI before first boot" ;;
      esac
  else
      bad "NVMe disk vmdk not found ($VMDK)"
  fi
  if vmx_get firmware "$VMX" | grep -qi efi; then ok "firmware EFI"; else warn "firmware key absent (ARM Fusion defaults to EFI — fine)"; fi
  gos="$(vmx_get guestOS "$VMX")"
  case "$gos" in
      arm-debian*) ok "guestOS $gos" ;;
      *) warn "guestOS '$gos' — want an arm-debian-* id (Debian 64-bit ARM)" ;;
  esac

  echo
  if [ "$FAILS" -gt 0 ]; then
      echo "RESULT: $FAILS FAIL(S)${FIXMODE:+ remaining — device-tree items need the UI}"
      exit 1
  fi
  echo "RESULT: all settings verified — boot it."
}

# ---- entry -----------------------------------------------------------------

VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=1 ;;
    --fix)    VERIFY=1; FIXMODE=1 ;;
    *)        [ -f "$arg" ] && VMX="$arg" ;;
  esac
done

preflight

instantiate() {
  BUNDLE="$VMDIR/ombra-desktop.vmwarevm"
  if [ -e "$BUNDLE" ]; then
      echo "FATAL: $BUNDLE exists — remove it first (if it is a dead attempt):" >&2
      echo "  rm -rf \"$BUNDLE\"" >&2
      exit 1
  fi
  mkdir -p "$BUNDLE"
  "$APP/Contents/Library/vmware-vdiskmanager" -c -s 30GB -a lsilogic -t 1 \
      "$BUNDLE/Virtual Disk.vmdk" >/dev/null
  # derive from the proven gateway template: values + removing
  # ethernet1; CD lines rewritten EXPLICITLY (the template carries
  # placeholders).
  sed -e "s|@REPO@|$REPO|g" \
      -e '/^ethernet1\./d' \
      -e '/^sata0:1\./d' \
      -e "s|^sata0:0.fileName = .*|sata0:0.fileName = \"$DESKTOP_ISO\"|" \
      -e 's|^memsize = .*|memsize = "6144"|' \
      -e 's|^numvcpus = .*|numvcpus = "4"|' \
      -e 's|^cpuid.coresPerSocket = .*|cpuid.coresPerSocket = "4"|' \
      -e 's|^mks.enable3d = .*|mks.enable3d = "TRUE"|' \
      -e 's|^tools.syncTime = .*|tools.syncTime = "FALSE"|' \
      -e 's|^sound.present = .*|sound.present = "TRUE"|' \
      -e 's|^ethernet0.address = .*|ethernet0.address = "00:50:56:2a:00:10"|' \
      "$REPO/build/fusion/gateway-vm-template.vmx" > "$BUNDLE/ombra-desktop.vmx"
  sed -i '' -e 's|^displayName = .*|displayName = "ombra-desktop"|' \
      -e 's|^nvram = .*|nvram = "ombra-desktop.nvram"|' \
      -e 's|^extendedConfigFile = .*|extendedConfigFile = "ombra-desktop.vmxf"|' \
      "$BUNDLE/ombra-desktop.vmx"
  case "$DESKTOP_ISO" in
    *-test.iso) sed -i '' -e 's|^displayName = .*|displayName = "ombra-desktop-TEST"|' "$BUNDLE/ombra-desktop.vmx" ;;
  esac
  # no display-mode pin: Fusion's default auto-fit is the product posture — sizing belongs to the user, not the image
  # OMBRA_INSTALL_VNC=1: local unauthenticated VNC for the test bench. NEVER set for shipped images — a debug channel.
  if [ "${OMBRA_INSTALL_VNC:-0}" = 1 ]; then
    printf 'RemoteDisplay.vnc.enabled = "TRUE"\nRemoteDisplay.vnc.port = "5977"\n' \
      >> "$BUNDLE/ombra-desktop.vmx"
  fi
  # OMBRA_INSTALL_SERIAL=1: file-backed serial log of the installer's phase timings (build VMs only; post-install strips it).
  if [ "${OMBRA_INSTALL_SERIAL:-0}" = 1 ]; then
    rm -f "/tmp/ombra-install-desktop.log"
    printf 'serial0.present = "TRUE"\nserial0.fileType = "file"\nserial0.fileName = "/tmp/ombra-install-desktop.log"\n' \
      >> "$BUNDLE/ombra-desktop.vmx"
  fi
  echo "instantiated $BUNDLE (6GB/4vCPU/30GB NVMe, 3D+sound on, MAC 00:50:56:2a:00:10, NAT for install)"
}

if [ "$VERIFY" = 1 ]; then
  verify
else
  instantiate
  echo
  echo "== installer DNS failures:"
  echo "   1. DISCONNECT any VPN that intercepts DNS; it blocks the"
  echo "      installer's DNS (packages are GPG-verified; egress is harmless)."
  echo "   2. If the VPN was EVER connected while Fusion ran, ALSO restart"
  echo "      Fusion's network daemons now — vmnet-natd snapshots the host"
  echo "      resolver at STARTUP and serves that stale state forever:"
  echo "        sudo \"/Applications/VMware Fusion.app/Contents/Library/vmnet-cli\" --stop"
  echo "        sudo \"/Applications/VMware Fusion.app/Contents/Library/vmnet-cli\" --start"
  echo "      (its 'Failed to start' output lies — check --status / just boot)."
  echo
  echo "== booting installer =="
  if [ "${OMBRA_START_NOGUI:-0}" = 1 ]; then
    "$VMRUN" -T fusion start "$VMDIR/ombra-desktop.vmwarevm/ombra-desktop.vmx" nogui \
        || echo "(vmrun start failed — open the VM in Fusion and press Play)"
  else
    open -a "VMware Fusion"
    "$VMRUN" -T fusion start "$VMDIR/ombra-desktop.vmwarevm/ombra-desktop.vmx" \
        || echo "(vmrun start failed — open the VM in Fusion and press Play)"
  fi
  cat <<'RB'

== desktop install runbook ==
- Unattended: the installer runs ~10-25 min (varies with the network) and
  the VM POWERS OFF when done. A failed install parks on a visible
  console instead of powering off; do not export a parked VM.
- After poweroff, run: bash build/fusion/post-install-desktop.sh
  (moves the NIC to "Private to my Mac", detaches the installer CD,
  disk-first boot, starts the VM). The gateway must be running.
- First boot: the first-use screen sets your disk passphrase and password.
RB
fi
