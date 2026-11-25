#!/bin/bash
# payload-desktop-from-1.2.sh <payload-dir> [git-ref]
# Builds the desktop update payload for every installed 1.2 desktop, cumulative from v1.2.0:
#   make-bundle.sh desktop <version> 1.2 <payload-dir> ...
#
# What it carries, from the given ref (default HEAD; a release tag for a published bundle):
#   - every desktop/rootfs and update/rootfs file that changed since v1.2.0 (the grub theme is left alone: the installer
#     fills font names into it, so the file in git is a template)
#   - post steps (post.d) for what the installer does that an installed system needs: the new units, and a rebuilt
#     initramfs, because the disk-unlock agent lives in it. A failed step fails the update and the updater takes the
#     system back to its rollback point (the home folder is on its own volume and is not touched).
# Applications are not in it: Tor Browser, Feather, SimpleX and Electrum come through app updates (apps.txt).
# What it cannot do (needs a new image): the disk layout, the VM's own settings.
set -euo pipefail
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: payload-desktop-from-1.2.sh <payload-dir> [git-ref]" >&2; exit 2; }
P=$1
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TAG=${2:-HEAD}
FROM=v1.2.0
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
        desktop/rootfs/boot/grub/themes/ombra/theme.txt) continue ;;   # template: the installer fills it in
        update/rootfs/etc/ombra/version) continue ;;                   # the updater writes it after the post steps
    esac
    rel=${f#desktop/rootfs/}; rel=${rel#update/rootfs/}
    [ "$rel" != "$f" ] || fatal "unexpected path $f"
    mkdir -p "$P/$(dirname "$rel")"
    cp "$T/$f" "$P/$rel"
    n=$((n + 1))
done < <(git -C "$REPO" diff --no-renames --name-status --diff-filter=AM "$FROM" "$TAG" -- desktop/rootfs update/rootfs)
[ "$n" -ge 10 ] || fatal "only $n overlay files: the diff looks wrong"
for must in etc/nftables.conf etc/systemd/system/ombra-tproxy.socket etc/systemd/system/ombra-tproxy.service \
            usr/local/bin/ombra-tproxy usr/local/bin/ombra-gateway-notify usr/local/libexec/ombra/ombra-askpass; do
    [ -f "$P/$must" ] || fatal "the payload lacks $must"
done
# deletions this script handles itself: the shared folder with the Mac (post step 20-no-shared-folder removes it)
deleted=$(git -C "$REPO" diff --no-renames --name-status --diff-filter=D "$FROM" "$TAG" -- desktop/rootfs update/rootfs \
    | grep -vE 'desktop/rootfs/(etc/systemd/system/mnt-transfer-shared\.(mount|automount)|usr/local/bin/ombra-send-to-mac|usr/share/kio/servicemenus/ombra-send-to-mac\.desktop|etc/udev/rules\.d/91-ombra-hide-transfer-disks\.rules)$' || true)
[ -z "$deleted" ] || fatal "files were deleted since $FROM and this script does not remove them on the target: $deleted"
# the version files are written by the updater after the post steps
rm -f "$P/etc/ombra/version"

L="$P/usr/local/lib/ombra-update"
mkdir -p "$L/post.d"
install -m 0755 "$T/scripts/update/post-runner.sh" "$L/post.sh"

cat > "$L/post.d/10-units" <<'STEP'
# from 1.2.2: the transparent proxy the firewall's redirects feed (systemd holds its ports), and the session notice
# about the gateway's Tor. The new firewall file must parse before the restart that puts it in force
set -eu
chmod 0755 /usr/local/bin/ombra-tproxy /usr/local/bin/ombra-gateway-notify /usr/local/bin/ombra /usr/local/bin/ombra-statusd \
    /usr/local/libexec/ombra/ombra-askpass /usr/local/libexec/ombra/ombra-welcome
nft -c -f /etc/nftables.conf
systemctl daemon-reload
systemctl enable ombra-tproxy.socket ombra-tproxy.service >/dev/null 2>&1
[ -L /etc/systemd/system/sockets.target.wants/ombra-tproxy.socket ]
STEP

cat > "$L/post.d/20-no-shared-folder" <<'STEP'
# from 1.2.2: the desktop no longer offers a shared folder with the Mac. Remove its mount, copy command, menu entry,
# udev rule and the sidebar place (the user's own places file is edited only if the entry is there)
set -eu
systemctl disable --now mnt-transfer-shared.automount >/dev/null 2>&1 || true
systemctl stop mnt-transfer-shared.mount >/dev/null 2>&1 || true
rm -f /etc/systemd/system/mnt-transfer-shared.mount /etc/systemd/system/mnt-transfer-shared.automount \
    /etc/systemd/system/multi-user.target.wants/mnt-transfer-shared.automount \
    /usr/local/bin/ombra-send-to-mac /usr/share/kio/servicemenus/ombra-send-to-mac.desktop \
    /etc/udev/rules.d/91-ombra-hide-transfer-disks.rules
systemctl daemon-reload
for f in /home/ombra/.local/share/user-places.xbel; do
    [ -f "$f" ] && grep -q 'file:///mnt/transfer/shared' "$f" || continue
    python3 - "$f" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n = re.sub(r'[ \t]*<bookmark href="file:///mnt/transfer/shared">.*?</bookmark>[ \t]*\n?', "", s, flags=re.S)
if n != s:
    st = os.stat(p)
    t = p + ".ombra-new"
    with open(t, "w", encoding="utf-8") as o:
        o.write(n)
    os.chown(t, st.st_uid, st.st_gid)
    os.chmod(t, st.st_mode & 0o7777)
    os.replace(t, p)
PY
done
rmdir /mnt/transfer/shared /mnt/transfer 2>/dev/null || true
STEP

cat > "$L/post.d/90-boot" <<'STEP'
# LAST, the only step that writes /boot: the initramfs carries the disk-unlock agent, which changed. The updater saved
# /boot before applying; on a failure here it is restored and the update is undone.
set -eu
update-initramfs -u -k all >/dev/null 2>&1
for i in /boot/initrd.img-*; do
    l=$(lsinitramfs "$i")
    for p in scripts/local-top/cryptroot usr/local/libexec/ombra/ombra-askpass; do
        case "$l" in *"$p"*) ;; *) echo "$i lacks $p" >&2; exit 1 ;; esac
    done
done
# the unlock agent inside the new initramfs must be the one this update installed
tmp=$(mktemp -d)
i=$(ls -t /boot/initrd.img-* | head -n1)
( cd "$tmp" && unmkinitramfs "$i" . >/dev/null 2>&1 ) || { rm -rf "$tmp"; echo "could not unpack $i" >&2; exit 1; }
found=$(find "$tmp" -path '*usr/local/libexec/ombra/ombra-askpass' | head -n1)
if [ -z "$found" ] || ! cmp -s "$found" /usr/local/libexec/ombra/ombra-askpass; then
    rm -rf "$tmp"; echo "the initramfs does not carry the new unlock agent" >&2; exit 1
fi
rm -rf "$tmp"
sync
STEP

# modes: directories 0755, scripts as in git (the archive kept them), post steps run through sh
find "$P" -type d -exec chmod 0755 {} +
chmod 0644 "$L/post.d"/*
find "$P" -name '._*' -delete
echo "payload: $P ($n overlay files, $(du -sh "$P" | cut -f1))"
echo "next: make-bundle.sh desktop <version> 1.2 $P <out-dir> <private-key>"
