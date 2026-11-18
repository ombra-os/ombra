#!/bin/bash
# payload-desktop-1.1-to-1.2.sh <payload-dir>
# Builds the update payload that takes an installed 1.1 desktop (two-VM edition) to 1.2, for
# make-bundle.sh desktop 1.2 1.1 <payload-dir> <out-dir> <key>.
#
# What it carries, all taken from the v1.2.0 tag so an updated machine matches a fresh 1.2 image:
#   - every desktop/rootfs and update/rootfs file that changed since v1.1.0 (the grub theme is edited in place instead:
#     the installer fills font names into it, so the file in git is a template)
#   - the dpkg exclusions for VMware's clipboard, drag-and-drop and shared-folder plugins
#   - post steps that run during Update Ombra (post.d): SimpleX upgrades as a package, Tor Browser and Feather unpack
#     next to the current ones, and a one-time unit swaps those two folders in at the next start (under a second),
#     so an open browser or wallet is never touched
# What it cannot do (needs a new image): /home on its own volume, the Fusion VM's hardware clock setting.
# Tor Browser stays on the gateway's port 9050, which every gateway version serves.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: payload-desktop-1.1-to-1.2.sh <payload-dir>" >&2; exit 2; }
P=$1
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TAG=v1.2.0
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
done < <(git -C "$REPO" diff --name-status --diff-filter=AM "$FROM" "$TAG" -- desktop/rootfs update/rootfs)
[ "$n" -gt 50 ] || fatal "only $n overlay files: the diff looks wrong"

mkdir -p "$P/etc/dpkg/dpkg.cfg.d"
printf 'path-exclude=/usr/lib/*open-vm-tools/plugins/*/libdndcp.so\npath-exclude=/usr/lib/*open-vm-tools/plugins/*/libhgfsServer.so\n' \
    > "$P/etc/dpkg/dpkg.cfg.d/ombra-no-host-channels"

# ---- applications, checked against the v1.2.0 pins ------------------------------------------------------------------
pin() { awk -F= -v k="$2" '$1 == k {print $2; exit}' "$T/build/pins/$1.txt"; }
V="$REPO/build/vendor"
L="$P/usr/local/lib/ombra-update"
S="$L/staged"
mkdir -p "$S" "$L/post.d"
stage() { # <src> <dest name> <want sha256>
    [ -f "$1" ] || fatal "missing $1"
    [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$3" ] || fatal "$1 does not match its v1.2.0 pin"
    cp "$1" "$S/$2"
}
grep -q '^version=16.0.1$' "$T/build/pins/torbrowser.txt" || fatal "unexpected Tor Browser pin"
stage "$V/tor-browser-linux-aarch64-16.0.1.tar.xz" torbrowser.tar.xz "$(pin torbrowser sha256)"
stage "$V/feather-$(pin feather version)-arm64.AppImage" feather.AppImage "$(pin feather sha256)"
stage "$V/simplex-desktop-ubuntu-24_04-aarch64.deb" simplex.deb "$(pin simplex sha256)"

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
    tar -cf "$S/$p.tar" --one-file-system $ex -C "$d" .
done
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
systemctl enable ombra-kwin-compositing.service ombra-update-finish.service >/dev/null 2>&1
STEP

cat > "$L/post.d/90-boot" <<'STEP'
# LAST, the only step that writes /boot: the new initramfs (unlock screen, display driver, crypttab) and boot menu
# (IPv6 off on the kernel line, Amnesic now also covers /home). On any failure /boot is put back as it was.
set -eu
S=/var/lib/ombra-update
[ -f "$S/boot.tar" ] || { echo "no copy of /boot: the boot files stay as they were" >&2; exit 0; }
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
        printf '%s\n' "$l" | grep -q "$p" || restore
    done
    printf '%s\n' "$l" | grep -qE 'virtio[-_]gpu[.]ko' || restore
done
update-grub >/dev/null 2>&1 || restore
G=/boot/grub/grub.cfg
grep -q 'overlayroot=tmpfs:recurse=1' "$G" && grep -q 'ipv6.disable=1' "$G" && [ "$(grep -c '^menuentry ' "$G")" = 2 ] || restore
sync
STEP

# ---- applications: unpacked and installed during the update; only a quick swap waits for the next start -------------
cat > "$L/post.d/40-apps" <<'STEP'
# SimpleX upgrades like any package (a running copy keeps its old files until it is closed). Tor Browser and Feather
# are unpacked next to the current ones; the folders are swapped at the next start, before the login screen, so an
# open browser or wallet is never touched.
set -u
S=/usr/local/lib/ombra-update/staged
[ ! -f "$S/simplex.deb" ] || ( set -e
    plan=$(apt-get -s -q --no-download -o Debug::NoLocking=1 install "$S/simplex.deb" 2>&1) || { echo "SimpleX: unmet dependencies" >&2; exit 1; }
    extra=$(printf '%s\n' "$plan" | awk '($1 == "Inst" && $2 != "simplex") || $1 == "Remv" {print $1, $2}')
    [ -z "$extra" ] || { echo "SimpleX would change other packages: $extra" >&2; exit 1; }
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$S/simplex.deb" >/dev/null
    [ -x /opt/simplex/bin/simplex ]
    rm -f "$S/simplex.deb"
) || echo "SimpleX stays at its current version" >&2
[ ! -f "$S/torbrowser.tar.xz" ] || ( set -e
    rm -rf /opt/tor-browser.next; mkdir -p /opt/tor-browser.next
    tar -xJf "$S/torbrowser.tar.xz" -C /opt/tor-browser.next --strip-components=1 --no-same-owner
    [ -e /opt/tor-browser.next/Browser/firefox ] || { rm -rf /opt/tor-browser.next; echo "the Tor Browser archive is incomplete" >&2; exit 1; }
    rm -rf /opt/tor-browser.next/Browser/TorBrowser/Data
    chmod -R a+rX /opt/tor-browser.next
    rm -f "$S/torbrowser.tar.xz"
) || { rm -rf /opt/tor-browser.next; echo "Tor Browser stays at its current version" >&2; }
[ ! -f "$S/feather.AppImage" ] || ( set -e
    W=/var/tmp/ombra-feather; rm -rf "$W"; mkdir -p "$W"
    cp "$S/feather.AppImage" "$W/f.AppImage"; chmod 0755 "$W/f.AppImage"
    (cd "$W" && ./f.AppImage --appimage-extract >/dev/null 2>&1)
    [ -x "$W/squashfs-root/usr/bin/feather" ] || { rm -rf "$W"; echo "Feather would not unpack" >&2; exit 1; }
    chmod -R a+rX "$W/squashfs-root"
    rm -rf /opt/feather.next; mv "$W/squashfs-root" /opt/feather.next; rm -rf "$W" "$S/feather.AppImage"
) || { rm -rf /opt/feather.next /var/tmp/ombra-feather; echo "Feather stays at its current version" >&2; }
rm -rf "$S"
update-desktop-database -q >/dev/null 2>&1 || true
mkdir -p /usr/share/ombra
awk '/^Package: /{p=$2} /^Architecture: /{a=$2} /^Version: /{v=$2} /^Status: .* installed$/{i=1} /^$/{if(i)print p" "v" "a; p=v=a="";i=0} END{if(i)print p" "v" "a}' \
    /var/lib/dpkg/status | sort > /usr/share/ombra/packages.txt.new
[ -s /usr/share/ombra/packages.txt.new ] && mv /usr/share/ombra/packages.txt.new /usr/share/ombra/packages.txt
STEP

cat > "$L/finish" <<'FINISH'
#!/bin/sh
# ombra-update-finish: swaps in the Tor Browser and Feather releases unpacked by the 1.2 update. Runs at the first
# Persistent start after it, before the login screen (renames only, under a second). The browser profile, bookmarks
# and Ombra's browser policy move into the new browser unchanged. Every part can run again.
set -eu
say() { echo "ombra-update-finish: $*"; }
OLD=/opt/tor-browser; NEXT=/opt/tor-browser.next
if [ -d "$NEXT" ]; then
    if [ -d "$OLD/Browser/TorBrowser/Data" ] && [ ! -e "$NEXT/Browser/TorBrowser/Data" ]; then
        mv "$OLD/Browser/TorBrowser/Data" "$NEXT/Browser/TorBrowser/Data"
    fi
    mkdir -p "$NEXT/Browser/distribution"
    [ -f "$NEXT/Browser/distribution/policies.json" ] || [ ! -f "$OLD/Browser/distribution/policies.json" ] \
        || cp -p "$OLD/Browser/distribution/policies.json" "$NEXT/Browser/distribution/"
    rm -rf "$OLD.old"; [ ! -d "$OLD" ] || mv "$OLD" "$OLD.old"
    mv "$NEXT" "$OLD"; rm -rf "$OLD.old"
    [ ! -f "$OLD/Browser/browser/chrome/icons/default/default48.png" ] \
        || cp "$OLD/Browser/browser/chrome/icons/default/default48.png" /usr/share/icons/hicolor/48x48/apps/tor-browser.png
    say "Tor Browser updated"
fi
if [ -d /opt/feather.next ]; then
    rm -rf /opt/feather.old; [ ! -d /opt/feather ] || mv /opt/feather /opt/feather.old
    mv /opt/feather.next /opt/feather; rm -rf /opt/feather.old
    say "Feather updated"
fi
rm -f /usr/local/lib/ombra-update/finish
systemctl disable ombra-update-finish.service >/dev/null 2>&1 || true
say "done"
FINISH
chmod 0755 "$L/finish"

mkdir -p "$P/etc/systemd/system"
cat > "$P/etc/systemd/system/ombra-update-finish.service" <<'UNIT'
[Unit]
Description=Finish the Ombra update (applications)
ConditionPathExists=/usr/local/lib/ombra-update/finish
ConditionKernelCommandLine=!overlayroot
After=local-fs.target
Before=display-manager.service systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/ombra-update/finish
TimeoutStartSec=5min
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# modes: directories 0755, scripts as in git (the archive kept them), post steps run through sh
find "$P" -type d -exec chmod 0755 {} +
chmod 0644 "$L/post.d"/*
find "$P" -name '._*' -delete
echo "payload: $P ($n overlay files, $(du -sh "$P" | cut -f1))"
