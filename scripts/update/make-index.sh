#!/bin/bash
# make-index.sh <private-key> <out-dir> <valid-days> <role=bundle-file>...
# e.g.  make-index.sh key out 400 desktop=out/ombra-desktop-1.2.update gateway=out/ombra-gateway-1.2.update \
#         single=out/ombra-single-1.2.update
# Writes <out-dir>/latest.txt and latest.txt.sig. Upload the bundles first, then both index files, to the updates/
# folder (scripts/upload-r2.sh --prefix updates/ does that order). Fields: expires (machines refuse the index after
# it), issued (machines that saw a newer index refuse an older one), and per role version, bundle, sha256, size.
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: make-index.sh <private-key> <out-dir> <valid-days> <role=bundle>..." >&2; exit 2; }
KEY=$1; OUT=$2; DAYS=$3; shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 0 ] || { echo "valid-days must be a positive number" >&2; exit 2; }
mkdir -p "$OUT"
{
  now=$(date +%s)
  echo "issued=$now"
  echo "expires=$(( now + DAYS * 86400 ))"
  for a in "$@"; do
    role=${a%%=*}; f=${a#*=}
    case "$role" in desktop|gateway|single) ;; *) echo "role must be desktop, gateway or single: $a" >&2; exit 2 ;; esac
    [ -f "$f" ] || { echo "no such bundle: $f" >&2; exit 2; }
    [ "$(tar -xOf "$f" manifest | awk -F= '$1=="role"{print $2}')" = "$role" ] || { echo "$f is not a $role bundle" >&2; exit 2; }
    ver=$(tar -xOf "$f" manifest | awk -F= '$1=="version"{print $2}')
    echo "$role.version=$ver"
    echo "$role.bundle=$(basename "$f")"
    echo "$role.sha256=$(shasum -a 256 "$f" | cut -d' ' -f1)"
    echo "$role.size=$(wc -c < "$f" | tr -d ' ')"
  done
} > "$OUT/latest.txt"
bash "$HERE/sign.sh" "$KEY" "$OUT/latest.txt"
cat "$OUT/latest.txt"
