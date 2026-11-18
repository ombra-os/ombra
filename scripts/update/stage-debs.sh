#!/bin/bash
# stage-debs.sh <payload-dir> <file.deb>...
# Adds Debian packages (typically trixie security updates for arm64, fetched with `apt-get download` on any
# trixie arm64 machine and checked against Debian's signed indexes there) to an update payload. On apply they are
# installed offline with dpkg. A pre-flight (apt's resolver in simulation, offline) runs first: if the packages need
# anything that is not bundled or already installed, the step fails before dpkg unpacks anything, and ombra-update
# rolls the update's own files back.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: stage-debs.sh <payload-dir> <file.deb>..." >&2; exit 2; }
P=$1; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
L="$P/usr/local/lib/ombra-update"
mkdir -p "$L/debs" "$L/post.d"
for d in "$@"; do
  case "$d" in *_arm64.deb|*_all.deb) ;; *) echo "not an arm64 or all-arch .deb: $d" >&2; exit 2 ;; esac
  cp "$d" "$L/debs/"
done
[ -e "$L/post.sh" ] || install -m 0755 "$HERE/post-runner.sh" "$L/post.sh"
cat > "$L/post.d/30-debs" <<'STEP'
# install the bundled Debian packages offline, keeping Ombra's configuration files
set -eu
D=/usr/local/lib/ombra-update/debs
[ -d "$D" ] || exit 0
# pre-flight, before anything is unpacked: the plan may only install the bundled packages and remove nothing
names=$(for f in "$D"/*.deb; do dpkg-deb -f "$f" Package; done)
if command -v apt-get >/dev/null 2>&1; then
    plan=$(apt-get -s -q --no-download -o Debug::NoLocking=1 install "$D"/*.deb 2>&1) || {
        printf '%s\n' "$plan" | tail -n 20 >&2
        echo "the bundled packages cannot be installed (unmet dependencies); nothing was installed" >&2; exit 1; }
    extra=$(printf '%s\n' "$plan" | awk '$1=="Inst" || $1=="Remv" {print $1, $2}' | while read -r act p; do
        p=${p%%:*}
        if [ "$act" = Remv ]; then echo "remove $p"; continue; fi
        printf '%s\n' "$names" | grep -qx "$p" || echo "install $p"
    done)
    [ -z "$extra" ] || { echo "the bundled packages would also need: $extra; nothing was installed" >&2; exit 1; }
else
    dpkg --dry-run -i "$D"/*.deb || { echo "dpkg pre-flight failed; nothing was installed" >&2; exit 1; }
fi
DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$D"/*.deb
rm -rf "$D"
STEP
echo "staged $# package(s) into $P"
