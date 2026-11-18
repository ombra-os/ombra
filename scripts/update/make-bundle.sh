#!/bin/bash
# make-bundle.sh <desktop|gateway|single> <version> <min-from> <payload-dir> <out-dir> <private-key>
# The payload dir is a tree of files that overlay / on the target (paths relative to /).
# An optional <payload-dir>/usr/local/lib/ombra-update/post.sh runs once after the files land.
# Output: <out-dir>/ombra-<role>-<version>.update (a tar of manifest, manifest.sig, payload.tar.gz)
# single is the one-VM edition's desktop; only its bundles may carry var/lib/ombra/gateway.img, and then always with
# a matching usr/share/ombra/gateway.img.sha256 (the updater checks it again after applying).
set -euo pipefail
[ $# -eq 6 ] || { echo "usage: make-bundle.sh <role> <version> <min-from> <payload-dir> <out-dir> <private-key>" >&2; exit 2; }
ROLE=$1; VER=$2; MIN=$3; SRC=$4; OUT=$5; KEY=$6
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$ROLE" in desktop|gateway|single) ;; *) echo "role must be desktop, gateway or single" >&2; exit 2 ;; esac
GI="$SRC/var/lib/ombra/gateway.img"; GS="$SRC/usr/share/ombra/gateway.img.sha256"
if [ -e "$GI" ] || [ -e "$GS" ]; then
  [ "$ROLE" = single ] || { echo "only single bundles may carry the gateway image" >&2; exit 2; }
  [ -f "$GI" ] && [ -f "$GS" ] || { echo "the gateway image and its .sha256 must ship together" >&2; exit 2; }
  [ "$(shasum -a 256 "$GI" | cut -d' ' -f1)" = "$(awk '{print $1; exit}' "$GS")" ] || { echo "gateway.img does not match gateway.img.sha256" >&2; exit 2; }
fi
[[ "$VER" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || { echo "bad version" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
COPYFILE_DISABLE=1 tar -czf "$T/payload.tar.gz" --no-xattrs --no-mac-metadata --uid 0 --gid 0 --exclude '._*' --exclude .DS_Store -C "$SRC" .
cat > "$T/manifest" <<EOM
role=$ROLE
version=$VER
min-from=$MIN
payload-sha256=$(shasum -a 256 "$T/payload.tar.gz" | cut -d' ' -f1)
EOM
bash "$HERE/sign.sh" "$KEY" "$T/manifest" >/dev/null
mkdir -p "$OUT"
F="$OUT/ombra-$ROLE-$VER.update"
COPYFILE_DISABLE=1 tar -cf "$F" --no-xattrs --no-mac-metadata -C "$T" manifest manifest.sig payload.tar.gz
echo "$F"
shasum -a 256 "$F"
