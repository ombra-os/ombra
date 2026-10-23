#!/bin/bash
# gateway VM on VMware Fusion. No hand-written vmx: Fusion-ARM's PCIe allocator rejects device trees Fusion did not generate.
# The vmx is the captured, proven-bootable template + a fresh 5GB disk; --verify [--fix] audits it. MACs pinned :01 (NAT) + :02 (intnet, disconnected for install).

set -u

APP="/Applications/VMware Fusion.app"
VMRUN="$APP/Contents/Public/vmrun"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GATEWAY_ISO="${OMBRA_GATEWAY_ISO:-$REPO/build/disks/ombra-install-gateway.iso}"
VMDIR="$HOME/Virtual Machines.localized"

# ---- preflight ------------------------------------------------------------

preflight() {
  [ -x "$VMRUN" ] || { echo "FATAL: vmrun not found at $VMRUN — install VMware Fusion" >&2; exit 1; }
  [ -f "$GATEWAY_ISO" ] || {
      echo "FATAL: build/disks/ombra-install-gateway.iso missing — build it:" >&2
      echo "  stage the pinned netinst in build/isos/ (build/pins/debian-netinst-arm64.txt)," >&2
      echo "  verify it: build/verify-iso.sh" >&2
      echo "  then:      build/make-install-iso.sh gateway" >&2
      exit 1
  }
  if [ -e "$VMDIR/ombra-gateway.vmwarevm" ]; then
      echo "NOTE: $VMDIR/ombra-gateway.vmwarevm already exists." >&2
      echo "Remove it first if it is stale:" >&2
      echo "  rm -rf \"$VMDIR/ombra-gateway.vmwarevm\"" >&2
  fi
}

# ---- verify / fix ----------------------------------------------------------

# vmx reading: lines look like  key = "value"; keys are CASE-INSENSITIVE
# (all lookups fold case; the fixer preserves the file's key spelling).
vmx_get() { # <key> <file>
  awk -F' = ' -v k="$1" 'tolower($1)==tolower(k) {gsub(/"/,"",$2); print $2; exit}' "$2"
}
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
      echo "locating a gateway vmx in $VMDIR ..."
      VMX="$( "$VMDIR"/*.vmwarevm/*.vmx 2>/dev/null | head -1)"
  fi
  if [ -z "$VMX" ] || [ ! -f "$VMX" ]; then
      echo "FATAL: no ombra-gateway vmx found in $VMDIR — pass the vmx path" >&2
      exit 1
  fi
  echo "== verifying $VMX =="
  if [ "$FIXMODE" = 1 ]; then cp "$VMX" "$VMX.pre-ombra"; echo "(backup: $VMX.pre-ombra)"; fi

  check_eq "RAM (install; post-install restores 512)" memSize 2048 "$VMX" 2048
  check_eq "vCPUs"       numvcpus      1   "$VMX" 1
  check_eq "installer CD" sata0:0.fileName "$GATEWAY_ISO" "$VMX" ""
  check_eq "NIC1 type"   ethernet0.connectionType nat "$VMX" nat
  check_eq "NIC1 MAC"    ethernet0.address  00:50:56:2a:00:01 "$VMX" 00:50:56:2a:00:01
  check_eq "NIC1 virtualDev" ethernet0.virtualDev vmxnet3 "$VMX" vmxnet3
  check_eq "NIC1 addrType" ethernet0.addressType static "$VMX" static
  if vmx_has ethernet1.present "$VMX"; then
      check_eq "NIC2 type"      ethernet1.connectionType hostonly "$VMX" hostonly
      check_eq "NIC2 MAC"       ethernet1.address        00:50:56:2a:00:02 "$VMX" 00:50:56:2a:00:02
      check_eq "NIC2 virtualDev" ethernet1.virtualDev  e1000e "$VMX" e1000e
      check_eq "NIC2 addrType"  ethernet1.addressType    static "$VMX" static
      check_eq "NIC2 DISCONNECTED for install" ethernet1.startConnected FALSE "$VMX" FALSE
  else
      bad "NIC2 missing — Add Device -> Network Adapter in the UI, then re-run --verify"
  fi
  check_eq "time sync OFF (Tor owns time)" tools.syncTime      FALSE "$VMX" FALSE
  check_eq "vmci present (vmrun needs it)" vmci0.present TRUE "$VMX" TRUE
  check_eq "3D OFF (headless)"             mks.enable3d       FALSE "$VMX" FALSE
  check_eq "no .vmem backing file"         mainMem.useNamedFile FALSE "$VMX" FALSE
  if vmx_get sound.present "$VMX" | grep -qi '^TRUE$'; then
      if [ "$FIXMODE" = 1 ]; then
          check_eq "sound card off" sound.present FALSE "$VMX" FALSE
      else
          bad "sound card enabled (headless box) — remove in the UI or run --fix"
      fi
  else
      ok "sound card off/absent"
  fi
  if vmx_has nvme0:0.mode "$VMX"; then
      bad "disk mode '$(vmx_get nvme0:0.mode "$VMX")' is set — Independent/Non-persistent goes ON only AFTER a verified install (otherwise the install is discarded at poweroff)"
  else
      ok "disk writable for install (live flip comes post-verify)"
  fi
  VMDK="$(cd "$(dirname "$VMX")" && pwd)/$(vmx_get nvme0:0.fileName "$VMX")"
  if [ -f "$VMDK" ]; then
      secs=$(grep -ao 'RW [0-9]*' "$VMDK" | awk '{s+=$2} END{print s}')
      gb=$(( ${secs:-0} / 2097152 ))
      case "$gb" in
          5)  ok   "disk 5GB" ;;
          *)  warn "disk size reads ${gb}GB — expected 5GB; resize in the UI if wrong" ;;
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
  BUNDLE="$VMDIR/ombra-gateway.vmwarevm"
  if [ -e "$BUNDLE" ]; then
      echo "FATAL: $BUNDLE exists — remove it first (if it is a dead attempt):" >&2
      echo "  rm -rf \"$BUNDLE\"" >&2
      exit 1
  fi
  mkdir -p "$BUNDLE"
  "$APP/Contents/Library/vmware-vdiskmanager" -c -s 5GB -a lsilogic -t 1 \
      "$BUNDLE/Virtual Disk.vmdk" >/dev/null
  # CD rewritten explicitly (template placeholders must never drift through)
  sed -e "s|@REPO@|$REPO|g" \
      -e '/^sata0:1\./d' \
      -e "s|^sata0:0.fileName = .*|sata0:0.fileName = \"$GATEWAY_ISO\"|" \
      -e 's|^memsize = .*|memsize = "2048"|' \
      "$REPO/build/fusion/gateway-vm-template.vmx" \
      > "$BUNDLE/ombra-gateway.vmx"
  case "$GATEWAY_ISO" in
    *-test.iso) sed -i '' -e 's|^displayName = .*|displayName = "ombra-gateway-TEST"|' "$BUNDLE/ombra-gateway.vmx" ;;
  esac
  # OMBRA_INSTALL_SERIAL=1: file-backed serial log of the installer's phase timings (build VMs only; post-install strips it).
  if [ "${OMBRA_INSTALL_SERIAL:-0}" = 1 ]; then
    rm -f "/tmp/ombra-install-gateway.log"
    printf 'serial0.present = "TRUE"\nserial0.fileType = "file"\nserial0.fileName = "/tmp/ombra-install-gateway.log"\n' \
      >> "$BUNDLE/ombra-gateway.vmx"
  fi
  echo "instantiated $BUNDLE from the saved template (512MB/1vCPU/5GB NVMe, MACs pinned, NIC2 disconnected)"
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
  echo "== booting installer (Fusion opens headed) =="
  open -a "VMware Fusion"
  "$VMRUN" -T fusion start "$VMDIR/ombra-gateway.vmwarevm/ombra-gateway.vmx" \
      || echo "(vmrun start failed — open the VM in Fusion and press Play)"
  cat <<'RB'

== gateway install runbook ==
- Unattended: grub auto-boots, the installer runs ~5-15 min, and the VM
  POWERS OFF when done. An unexpectedly early poweroff is a failed install.
- After poweroff, run: bash build/fusion/post-install-gateway.sh
  (connects NIC2, detaches the installer CD, disk-first boot, starts the VM)
- Check the gateway's console health report, then power off and run
  bash build/fusion/export-bundle.sh gateway to build the release archive.
RB
fi
