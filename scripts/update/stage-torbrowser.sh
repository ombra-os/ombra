#!/bin/bash
# stage-torbrowser.sh <payload-dir> <tor-browser-linux-aarch64-*.tar.xz> <sha256>
# Adds a Tor Browser release to a DESKTOP update payload. On apply, the browser in /opt/tor-browser is replaced
# and the user's profile (Browser/TorBrowser/Data) and Ombra's policies.json are carried over. Ombra disables the
# browser's own updater, so this is how browser security releases reach installed machines: ship one for every
# Tor Browser release on the channel the image uses. The step refuses while Tor Browser is running (Update Ombra
# asks the user to close it first).
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: stage-torbrowser.sh <payload-dir> <tarball> <sha256>" >&2; exit 2; }
P=$1; TB=$2; WANT=$3
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$(basename "$TB")" in tor-browser-linux-aarch64-*.tar.xz) ;; *) echo "not a linux-aarch64 Tor Browser tarball: $TB" >&2; exit 2 ;; esac
GOT=$(shasum -a 256 "$TB" | cut -d' ' -f1)
[ "$GOT" = "$WANT" ] || { echo "sha256 mismatch: got $GOT, want $WANT" >&2; exit 1; }
L="$P/usr/local/lib/ombra-update"
mkdir -p "$L/post.d"
cp "$TB" "$L/torbrowser.tar.xz"
[ -e "$L/post.sh" ] || install -m 0755 "$HERE/post-runner.sh" "$L/post.sh"
cat > "$L/post.d/20-torbrowser" <<'STEP'
# replace /opt/tor-browser with the bundled release; the profile and Ombra's policies move across.
# Re-runnable: once the profile sits in the new tree (marker), a rerun only finishes the swap and never deletes it.
set -eu
SRC=/usr/local/lib/ombra-update/torbrowser.tar.xz
OLD=/opt/tor-browser
NEW=/opt/tor-browser.new
READY=.ombra-swap-ready
[ -f "$SRC" ] || exit 0
if pgrep -f "$OLD/Browser/" >/dev/null 2>&1; then
    echo "Tor Browser is running: close it, then update again" >&2; exit 1
fi
if [ ! -e "$NEW/$READY" ]; then
    rm -rf "$NEW"; mkdir -p "$NEW"
    tar -xJf "$SRC" -C "$NEW" --strip-components=1 --no-same-owner
    [ -e "$NEW/Browser/firefox" ] || { echo "the bundled Tor Browser is incomplete" >&2; rm -rf "$NEW"; exit 1; }
    chmod -R a+rX "$NEW"
    mkdir -p "$NEW/Browser/distribution"
    [ ! -f "$OLD/Browser/distribution/policies.json" ] || cp -p "$OLD/Browser/distribution/policies.json" "$NEW/Browser/distribution/"
    if [ -d "$OLD/Browser/TorBrowser/Data" ]; then
        rm -rf "$NEW/Browser/TorBrowser/Data"
        mv "$OLD/Browser/TorBrowser/Data" "$NEW/Browser/TorBrowser/Data"
    fi
    : > "$NEW/$READY"
else
    echo "finishing an interrupted Tor Browser swap"
fi
if [ -d "$OLD" ]; then rm -rf "$OLD.old"; mv "$OLD" "$OLD.old"; fi
mv "$NEW" "$OLD"; rm -f "$OLD/$READY"; rm -rf "$OLD.old"
[ ! -f "$OLD/Browser/browser/chrome/icons/default/default48.png" ] \
    || cp "$OLD/Browser/browser/chrome/icons/default/default48.png" /usr/share/icons/hicolor/48x48/apps/tor-browser.png
rm -f "$SRC"
STEP
echo "staged $(basename "$TB") into $P (desktop payload)"
