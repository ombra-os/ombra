#!/bin/bash
# host-side finish pass after the gateway installer powers off: connect NIC2, disk-first boot order,
# install-time VNC keys stripped. OMBRA_LIVE=1 optionally marks the NVMe disk Independent/Non-persistent (the guest is amnesic without it). Idempotent.
# Usage: post-install-gateway.sh [vmx-path] [--no-start]

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
VMX="$HOME/Virtual Machines.localized/ombra-gateway.vmwarevm/ombra-gateway.vmx"
START=1
for arg in "$@"; do
  case "$arg" in
    --no-start) START=0 ;;
    *) VMX="$arg" ;;
  esac
done

if [ ! -f "$VMX" ]; then
  printf 'FATAL: vmx not found: %s\n' "$VMX" >&2
  exit 2
fi

VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
[ -x "$VMRUN" ] || { printf 'FATAL: vmrun not found at %s\n' "$VMRUN" >&2; exit 2; }
if ! RUNNING="$("$VMRUN" -T fusion list 2>&1)"; then
  printf 'FATAL: vmrun list failed — cannot tell whether the VM is running:\n%s\n' "$RUNNING" >&2
  exit 2
fi
if printf '%s\n' "$RUNNING" | grep -Fq "$VMX"; then
  printf 'VM is running — this pass edits the vmx; power it off first\n' >&2
  exit 1
fi

# key-spelling-preserving, case-insensitive overwrite
vmx_set() { # <key-lower> <value>
  local key="$1" val="$2" k
  k=$(grep -i "^${key} *=" "$VMX" | head -1 | cut -d= -f1 | tr -d ' ')
  if [ -n "$k" ]; then
    sed -i '' -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${k} = \"${val}\"|" "$VMX"
  else
    printf '%s = "%s"\n' "$key" "$val" >> "$VMX"
  fi
}

vmx_set ethernet1.startConnected true    # internal net: tor/dnsmasq bind 10.55.10.1
vmx_set memsize 512
vmx_set sata0:0.startConnected  false    # keep the install ISO attached but never boot it
vmx_set bios.bootOrder          "hdd,cdrom"
vmx_set snapshot.disabled        TRUE      # no snapshots: they keep old disk states and RAM on the host

# install-time debug channels never ship: strip any VNC keys from the vmx
if grep -qE '^(RemoteDisplay|serial[0-9]+)\.' "$VMX"; then
  cp "$VMX" "$VMX.bak"
  sed -i '' -E '/^(RemoteDisplay|serial[0-9]+)\./d' "$VMX"
fi
if grep -qE '^(RemoteDisplay|serial[0-9]+)\.' "$VMX"; then
  printf 'FATAL: RemoteDisplay (VNC) keys survived the strip: %s\n' "$VMX" >&2
  exit 1
fi

if [ "${OMBRA_LIVE:-0}" = "1" ]; then
  vmx_set nvme0:0.mode "independent-nonpersistent"
  printf 'live mode ON: disk writes are discarded on every power-off\n'
fi

if [ "$START" = 1 ]; then
  "$VMRUN" -T fusion start "$VMX" gui >/dev/null 2>&1 \
    || { printf 'FATAL: vmrun start failed — open the VM in Fusion and press Play\n' >&2; exit 1; }
fi
if [ "$START" = 1 ]; then
  printf 'gateway started: NIC2 connected, CD detached, disk-first\n'
else
  printf 'gateway vmx finished (not started): NIC2 connected, CD detached, disk-first\n'
fi
