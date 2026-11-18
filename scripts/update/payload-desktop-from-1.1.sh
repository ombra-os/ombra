#!/bin/bash
# payload-desktop-from-1.1.sh <payload-dir> [git-ref]
# Builds the desktop update payload for every installed 1.1 or later desktop (both editions), cumulative from v1.1.0,
# so one bundle serves 1.1 and 1.2 machines alike: make-bundle.sh desktop <version> 1.1 <payload-dir> ... and
# make-bundle.sh single <version> 1.2 <payload-dir> ...
#
# What it carries, from the given ref (default HEAD; a release tag for a published bundle):
#   - every desktop/rootfs and update/rootfs file that changed since v1.1.0 (the grub theme is edited in place instead:
#     the installer fills font names into it, so the file in git is a template)
#   - the dpkg exclusions for VMware's clipboard, drag-and-drop and shared-folder plugins
#   - post steps (post.d) for what the installer does that an installed system needs; every step can run again and
#     none can fail the update (the 1.1 updater rolls back on a failed step, and on 1.1 layouts that reverts /home)
# Applications are not in it: Tor Browser, Feather, SimpleX and Electrum come through app updates (apps.txt).
# What it cannot do (needs a new image): /home on its own volume, the Fusion VM's hardware clock setting.
set -euo pipefail
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: payload-desktop-from-1.1.sh <payload-dir> [git-ref]" >&2; exit 2; }
P=$1
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TAG=${2:-HEAD}
FROM=v1.1.0
fatal() { echo "FATAL: $*" >&2; exit 1; }
[ ! -e "$P" ] || fatal "$P exists; give a new directory"
git -C "$REPO" rev-parse -q --verify "$TAG^{commit}" >/dev/null || fatal "tag $TAG not found"

T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
git -C "$REPO" archive "$TAG" desktop/rootfs update/rootfs build/pins scripts/update/post-runner.sh | tar -x -C "$T"
umask 022
mkdir -p "$P"; chmod 0755 "$P"

# ---- changed overlay files ------------------------------------------------------------------------------------------
n=0
while read -r st f; do
    case "$f" in
        desktop/rootfs/boot/grub/themes/ombra/theme.txt) continue ;;   # template: edited in place (post.d/90-boot)
        update/rootfs/etc/ombra/version) continue ;;                   # the updater writes it after the post steps
    esac
    rel=${f#desktop/rootfs/}; rel=${rel#update/rootfs/}
    [ "$rel" != "$f" ] || fatal "unexpected path $f"
    mkdir -p "$P/$(dirname "$rel")"
    cp "$T/$f" "$P/$rel"
    n=$((n + 1))
done < <(git -C "$REPO" diff --no-renames --name-status --diff-filter=AM "$FROM" "$TAG" -- desktop/rootfs update/rootfs)
[ "$n" -gt 50 ] || fatal "only $n overlay files: the diff looks wrong"
# the version files are written by the updater after the post steps
rm -f "$P/etc/ombra/version"

mkdir -p "$P/etc/dpkg/dpkg.cfg.d"
printf 'path-exclude=/usr/lib/*open-vm-tools/plugins/*/libdndcp.so\npath-exclude=/usr/lib/*open-vm-tools/plugins/*/libhgfsServer.so\n' \
    > "$P/etc/dpkg/dpkg.cfg.d/ombra-no-host-channels"

L="$P/usr/local/lib/ombra-update"
mkdir -p "$L/post.d"

cat > "$L/post.sh" <<'RUNNER'
#!/bin/sh
# Runs every step in post.d. A step that cannot finish leaves its part as it was and the update still completes: the
# 1.1 updater rolls back on a failed post step, and on 1.1 layouts (/home on the system volume) that would also take
# /home back to the start of the update. So this runner never fails.
D=/usr/local/lib/ombra-update/post.d
[ -d "$D" ] || exit 0
for step in "$D"/*; do
    [ -f "$step" ] || continue
    echo "post step: ${step##*/}"
    sh "$step" "$@" || echo "post step ${step##*/} did not finish; that part stays as it was" >&2
done
rm -rf "$D"
exit 0
RUNNER
chmod 0755 "$L/post.sh"

# ---- post.d: run by Update Ombra right after the files land (the old rollback point is still valid) ----------------

cat > "$L/post.d/05-boot-save" <<'STEP'
# copies of /boot and the EFI partition (their own partitions, outside the rollback point), in the layout the 1.2
# updater restores on rollback and deletes on commit
set -eu
S=/var/lib/ombra-update
rm -f "$S/boot.tar" "$S/efi.tar"
for p in boot efi; do
    d=/boot; [ "$p" = efi ] && d=/boot/efi
    mountpoint -q "$d" || continue
    ex=""; [ "$p" = boot ] && mountpoint -q /boot/efi && ex=--exclude=./efi
    used=$(du -skx "$d" | awk '{print $1}'); free=$(df -Pk "$S" | awk 'NR==2 {print $4}')
    [ "$free" -gt $((used + 262144)) ] || { rm -f "$S/boot.tar" "$S/efi.tar"; echo "no room to copy $d" >&2; exit 1; }
    # written beside, read back, then renamed: a half-written copy is never taken for a good one
    rm -f "$S/$p.tar.tmp"
    if tar -cf "$S/$p.tar.tmp" --one-file-system $ex -C "$d" . && tar -tf "$S/$p.tar.tmp" >/dev/null; then
        mv "$S/$p.tar.tmp" "$S/$p.tar"
    else
        rm -f "$S/$p.tar.tmp" "$S/boot.tar" "$S/efi.tar"; echo "could not copy $d" >&2; exit 1
    fi
done
sync
STEP

cat > "$L/post.d/10-system" <<'STEP'
# what the 1.2 installer does that an installed system needs; every command can run again and stands alone
set -u
[ -s /etc/ombra/edition ] || printf 'two-vm\n' > /etc/ombra/edition
rm -f /usr/share/sddm/themes/Colloid-dark/background.png
# the security and updates suites, for Check Debian security updates
SL=/etc/apt/sources.list
grep -q '^deb .*debian-security trixie-security' "$SL" || printf 'deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware\n' >> "$SL"
grep -q '^deb .* trixie-updates ' "$SL" || printf 'deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware\n' >> "$SL"
# VMware clipboard, drag-and-drop and shared-folder plugins: gone, and kept out by the dpkg exclusions in the payload
find /usr/lib -path '*open-vm-tools/plugins/*' \( -name libdndcp.so -o -name libhgfsServer.so \) -delete
# the stock grub menu generators stay off across grub upgrades
for g in 10_linux 20_linux_xen 30_os-prober 30_uefi-firmware; do
    dpkg-statoverride --list "/etc/grub.d/$g" >/dev/null 2>&1 || dpkg-statoverride --update --add root root 0644 "/etc/grub.d/$g" 2>/dev/null || true
    [ ! -e "/etc/grub.d/$g" ] || chmod 0644 "/etc/grub.d/$g"
done
# no TRIM through the encrypted disk (applies from the next start; the initramfs is rebuilt in 90-boot)
sed -i '/^[^#].*keyscript=/s/,discard,/,/; /^[^#].*keyscript=/s/,discard$//; /^[^#].*keyscript=/s/,x-initrd\.attach,x-initrd\.attach/,x-initrd.attach/' /etc/crypttab
systemctl mask fstrim.timer fstrim.service >/dev/null 2>&1
# the installer's own DHCP profile (1.1 installs kept it; 1.2 installs never create it); only the stock one
W="/etc/NetworkManager/system-connections/Wired connection 1"
if [ -f "$W" ] && grep -qx 'id=Wired connection 1' "$W" && ! grep -q '^interface-name=' "$W" && grep -qx 'method=auto' "$W"; then
    rm -f "$W"
fi
systemctl daemon-reload
systemctl enable ombra-kwin-compositing.service >/dev/null 2>&1
STEP

cat > "$L/post.d/90-boot" <<'STEP'
# LAST, the only step that writes /boot: the new initramfs (unlock screen, display driver, crypttab) and boot menu
# (IPv6 off on the kernel line, Amnesic now also covers /home). On any failure /boot is put back as it was.
set -eu
S=/var/lib/ombra-update
[ -f "$S/boot.tar" ] && tar -tf "$S/boot.tar" >/dev/null 2>&1 || { echo "no readable copy of /boot: the boot files stay as they were" >&2; exit 0; }
restore() {
    echo "boot files could not be updated; they stay as they were" >&2
    tar -xf "$S/boot.tar" -C /boot
    exit 0
}
sed -i '/^    height = 150$/s/150/122/' /boot/grub/themes/ombra/theme.txt || restore
update-initramfs -u -k all >/dev/null 2>&1 || restore
for i in /boot/initrd.img-*; do
    l=$(lsinitramfs "$i") || restore
    for p in scripts/local-top/cryptroot usr/local/libexec/ombra/ombra-askpass; do
        case "$l" in *"$p"*) ;; *) restore ;; esac
    done
    case "$l" in *virtio-gpu.ko*|*virtio_gpu.ko*) ;; *) restore ;; esac
done
update-grub >/dev/null 2>&1 || restore
G=/boot/grub/grub.cfg
grep -q 'overlayroot=tmpfs:recurse=1' "$G" && grep -q 'ipv6.disable=1' "$G" && [ "$(grep -c '^menuentry ' "$G")" = 2 ] || restore
sync
STEP

# modes: directories 0755, scripts as in git (the archive kept them), post steps run through sh
find "$P" -type d -exec chmod 0755 {} +
chmod 0644 "$L/post.d"/*
find "$P" -name '._*' -delete
echo "payload: $P ($n overlay files, $(du -sh "$P" | cut -f1))"
