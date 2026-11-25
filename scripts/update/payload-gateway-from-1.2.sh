#!/bin/bash
# payload-gateway-from-1.2.sh <payload-dir> <apparmor_*_arm64.deb> [git-ref]
# Builds the gateway update payload for every installed 1.2 gateway, cumulative from v1.2.0:
#   make-bundle.sh gateway <version> 1.2 <payload-dir> ...
#
# What it carries, from the given ref (default HEAD; a release tag for a published bundle):
#   - every gateway/rootfs and update/rootfs file that changed since v1.2.0
#   - Debian's apparmor package. 1.2.0 and 1.2.1 gateways were installed without it, and from 1.2.2 Tor's unit
#     requires its AppArmor profile: without the package Tor would not start. Fetch it on any trixie arm64 machine
#     (a test gateway will do: apt checks Debian's signature there):
#       apt-get -o Acquire::http::Proxy=socks5h://127.0.0.1:9050 update && apt-get download apparmor
#   - post steps (post.d): install that package offline, then what the installer does for Tor's confinement.
#     If the profile cannot be loaded afterwards the step fails and the updater puts the gateway's files back.
set -euo pipefail
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: payload-gateway-from-1.2.sh <payload-dir> <apparmor_*_arm64.deb> [git-ref]" >&2; exit 2; }
P=$1; DEB=$2
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TAG=${3:-HEAD}
FROM=v1.2.0
fatal() { echo "FATAL: $*" >&2; exit 1; }
[ ! -e "$P" ] || fatal "$P exists; give a new directory"
case "$(basename "$DEB")" in apparmor_*_arm64.deb) ;; *) fatal "$DEB is not an apparmor_<version>_arm64.deb" ;; esac
[ -s "$DEB" ] && [ "$(head -c 7 "$DEB")" = '!<arch>' ] || fatal "$DEB is not a Debian package"
git -C "$REPO" rev-parse -q --verify "$TAG^{commit}" >/dev/null || fatal "ref $TAG not found"

T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
git -C "$REPO" archive "$TAG" gateway/rootfs update/rootfs scripts/update/post-runner.sh | tar -x -C "$T"
umask 022
mkdir -p "$P"; chmod 0755 "$P"

n=0
while read -r st f; do
    case "$f" in
        update/rootfs/etc/ombra/version) continue ;;                   # the updater writes it after the post steps
        gateway/rootfs/boot/*) continue ;;                             # the boot menu and theme need a new image
        gateway/rootfs/usr/lib/os-release|gateway/rootfs/etc/lsb-release) continue ;;  # version fields: the updater's
    esac
    rel=${f#gateway/rootfs/}; rel=${rel#update/rootfs/}
    [ "$rel" != "$f" ] || fatal "unexpected path $f"
    mkdir -p "$P/$(dirname "$rel")"
    cp -p "$T/$f" "$P/$rel"
    n=$((n + 1))
done < <(git -C "$REPO" diff --no-renames --name-status --diff-filter=AM "$FROM" "$TAG" -- gateway/rootfs update/rootfs)
[ "$n" -ge 10 ] || fatal "only $n overlay files: the diff looks wrong"
for must in etc/ombra/tor-freshness.list etc/tor/torrc etc/nftables.conf etc/dnsmasq.d/ombra.conf usr/local/sbin/ombra-tor-tripwire \
            usr/local/sbin/ombra-tor-freshness etc/systemd/system/tor@default.service.d/20-ombra-hardening.conf \
            etc/systemd/system/tor@default.service.d/30-ombra-apparmor.conf usr/local/bin/ombra-torctl-filter; do
    [ -f "$P/$must" ] || fatal "the payload lacks $must"
done
deleted=$(git -C "$REPO" diff --no-renames --name-status --diff-filter=D "$FROM" "$TAG" -- gateway/rootfs update/rootfs)
[ -z "$deleted" ] || fatal "files were deleted since $FROM and this script does not remove them on the target: $deleted"

L="$P/usr/local/lib/ombra-update"
mkdir -p "$L/post.d"
install -m 0755 "$T/scripts/update/post-runner.sh" "$L/post.sh"

# the apparmor package: installed offline by post.d/30-debs, before the step below
bash "$HERE/stage-debs.sh" "$P" "$DEB" >/dev/null
[ -f "$L/post.d/30-debs" ] || fatal "stage-debs.sh did not write its post step"

cat > "$L/post.d/50-tor-hardening" <<'STEP'
# what the 1.2.2 installer does for Tor's confinement, on an installed gateway; every command can run again
set -eu
chmod 0755 /usr/local/sbin/ombra-tor-tripwire /usr/local/sbin/ombra-tor-freshness /usr/local/sbin/ombra-systemcheck \
    /usr/local/sbin/ombra-leak-probe /usr/local/bin/ombra-torctl-filter /usr/local/bin/ombra
# both files must parse before the restart that puts them in force: a gateway whose Tor or firewall does not start has no network
nft -c -f /etc/nftables.conf
tor --defaults-torrc /usr/share/tor/tor-service-defaults-torrc -f /etc/tor/torrc --verify-config >/dev/null
dnsmasq --test >/dev/null 2>&1
# Tor's AppArmor profile is required from here on (30-ombra-apparmor.conf): it must load now, or this update is undone
command -v apparmor_parser >/dev/null 2>&1 || { echo "apparmor is not installed: Tor would not start" >&2; exit 1; }
[ -d /sys/kernel/security/apparmor ] || { echo "this kernel has AppArmor off: Tor would not start" >&2; exit 1; }
apparmor_parser -r /etc/apparmor.d/system_tor >/dev/null 2>&1 || { echo "Tor's AppArmor profile does not load" >&2; exit 1; }
systemctl enable apparmor.service >/dev/null 2>&1
systemctl daemon-reload
systemctl enable ombra-tor-freshness.timer >/dev/null 2>&1
STEP

echo "gateway payload from $FROM to $TAG: $n overlay files, $(ls "$L/post.d" | wc -l | tr -d ' ') post step(s) in $P"
echo "next: make-bundle.sh gateway <version> 1.2 $P <out-dir> <private-key>"
