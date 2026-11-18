#!/bin/sh
# build/single-iso/early.sh — partman/early_command of the single-edition ISO, run as /ombra/early.sh before partman
# touches any disk. The user made this VM by hand: pick the install disk (the first disk that is not the install medium;
# Fusion shows NVMe, UTM virtio) and stop here, with a dialog, when the VM is too small for the recipe: on a small disk
# partman silently falls back to Debian's default layout, which late-command would only catch at the very end.
# BusyBox sh inside debian-installer; stdout goes to the syslog (preseed_command runs this under log-output).

. /usr/share/debconf/confmodule

# the recipe needs about 20 GB (ESP, /boot, then 88% of the volume group for 12 GB root + 4 GB swap + 2 GB home)
MIN_DISK_BYTES=24000000000
# a VM given 3 GB of memory reports about 2.9 GB to Linux; 2 GB reports about 1.9 GB
MIN_MEM_KB=2750000

stop() {  # $1 what is wrong: shown in a dialog that never lets the install go on
    echo "ombra early: $1 — install stopped"
    while :; do
        db_fset ombra/vm-too-small seen false
        db_subst ombra/vm-too-small REASON "$1"
        if db_input critical ombra/vm-too-small; then
            db_go || true
        else
            # no dialog (the template did not load): the same words on the console, where ombra_fatal puts its own
            chvt 3 >/dev/null 2>&1 || true
            echo "OMBRA: $1 — power off this virtual machine, give it at least 24 GB of disk and 3 GB of memory, and start the installer again" > /dev/console 2>/dev/null || true
            sleep 60
        fi
    done
}

mem_kb="$(awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null)"
case "$mem_kb" in ''|*[!0-9]*) stop "The installer could not read how much memory this virtual machine has." ;; esac
if [ "$mem_kb" -lt "$MIN_MEM_KB" ]; then
    stop "This virtual machine has about $((mem_kb / 1000000)).$((mem_kb % 1000000 / 100000)) GB of memory; Ombra needs at least 3 GB."
fi

# the install medium never counts as a disk, even when it is attached as one (a UTM VirtIO or USB drive)
cd_src="$(mount | awk '$3 == "/cdrom" {print $1; exit}')"
disk=""
for d in $(list-devices disk); do
    case "$cd_src" in "$d"|"$d"[0-9]*|"$d"p[0-9]*) continue ;; esac
    disk="$d"
    break
done
[ -n "$disk" ] || stop "The installer found no disk in this virtual machine to install Ombra on."

sectors="$(cat "/sys/block/${disk#/dev/}/size" 2>/dev/null)"
case "$sectors" in ''|*[!0-9]*) stop "The installer could not read the size of the disk $disk." ;; esac
bytes=$((sectors * 512))
if [ "$bytes" -lt "$MIN_DISK_BYTES" ]; then
    stop "The disk $disk holds about $((bytes / 1000000000)) GB; Ombra needs at least 24 GB."
fi

db_set partman-auto/disk "$disk"
echo "ombra early: installing on $disk ($((bytes / 1000000000)) GB), memory ${mem_kb} kB"
exit 0
