#!/bin/bash
# host-side finish pass after the desktop installer powers off: NIC1 to intnet (pinned MAC), CD becomes an
# empty raw drive, disk-first boot order, install-time VNC keys stripped. Idempotent.
# Usage: post-install-desktop.sh [vmx-path] [--no-start]

set -eu

VMX="${HOME}/Virtual Machines.localized/ombra-desktop.vmwarevm/ombra-desktop.vmx"
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

vmx_set() { # <key-lower> <value>
  local key="$1" val="$2" k
  k=$(grep -i "^${key} *=" "$VMX" | head -1 | cut -d= -f1 | tr -d ' ')
  if [ -n "$k" ]; then
    sed -i '' -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${k} = \"${val}\"|" "$VMX"
  else
    printf '%s = "%s"\n' "$key" "$val" >> "$VMX"
  fi
}

vmx_set ethernet0.connectionType hostonly   # NAT -> "Private to my Mac" (vmnet1)
vmx_set sata0:0.deviceType        cdrom-raw # image -> empty physical drive
vmx_set sata0:0.fileName          "auto detect"
vmx_set sata0:0.startConnected    false     # no media at any boot, ever
vmx_set bios.bootOrder            "hdd,cdrom"
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

if [ "$START" = 1 ]; then
  "$VMRUN" -T fusion start "$VMX" gui >/dev/null 2>&1 \
    || { printf 'FATAL: vmrun start failed — open the VM in Fusion and press Play\n' >&2; exit 1; }
fi
if [ "$START" = 1 ]; then
  printf 'desktop started: intnet-only (via gateway), empty CD, disk-first\n'
else
  printf 'desktop vmx finished (not started): intnet-only (via gateway), empty CD, disk-first\n'
fi
printf 'console: first boot = ombra-welcome (set disk passphrase + password)\n'
