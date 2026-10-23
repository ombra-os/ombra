#!/bin/bash
# make-index.sh <private-key> <out-dir> <valid-days> <role=bundle-file>...
# e.g.  make-index.sh key out 400 desktop=out/ombra-desktop-1.2.update gateway=out/ombra-gateway-1.2.update
# Writes <out-dir>/latest.txt and latest.txt.sig. Upload both, plus the bundles, to the updates/ folder.
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: make-index.sh <private-key> <out-dir> <valid-days> <role=bundle>..." >&2; exit 2; }
KEY=$1; OUT=$2; DAYS=$3; shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
{
  echo "expires=$(( $(date +%s) + DAYS * 86400 ))"
  for a in "$@"; do
    role=${a%%=*}; f=${a#*=}
    ver=$(tar -xOf "$f" manifest | awk -F= '$1=="version"{print $2}')
    echo "$role.version=$ver"
    echo "$role.bundle=$(basename "$f")"
    echo "$role.sha256=$(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
} > "$OUT/latest.txt"
bash "$HERE/sign.sh" "$KEY" "$OUT/latest.txt"
cat "$OUT/latest.txt"
