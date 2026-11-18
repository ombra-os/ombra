#!/bin/bash
# make-apps.sh <out-dir> <valid-days> [private-key]
# Writes <out-dir>/apps.txt, the app list Update Ombra checks for app updates: for Tor Browser, Feather, SimpleX and
# Electrum, the version, upstream download (url, and url2 as a fallback), sha256 and size, all from build/pins/*.txt.
# Pin a version only after checking its upstream signature (the pin files record how). With a key it also writes
# apps.txt.sig; otherwise sign it with scripts/update/sign.sh. Upload both to updates/ with scripts/upload-r2.sh.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: make-apps.sh <out-dir> <valid-days> [private-key]" >&2; exit 2; }
OUT=$1; DAYS=$2; KEY=${3:-}
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 0 ] || { echo "valid-days must be a positive number" >&2; exit 2; }
pin() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$REPO/build/pins/$1.txt"; }
mkdir -p "$OUT"
{
  now=$(date +%s)
  echo "issued=$now"
  echo "expires=$(( now + DAYS * 86400 ))"
  for a in torbrowser feather simplex electrum; do
    v=$(pin "$a" version); f=$(pin "$a" file); s=$(pin "$a" sha256); u=$(pin "$a" url); u2=$(pin "$a" archive_url)
    [ -n "$v" ] && [ -n "$f" ] && [[ "$s" =~ ^[0-9a-f]{64}$ ]] && [[ "$u" == https://*/ ]] || { echo "incomplete pin: $a" >&2; exit 1; }
    local_file="$REPO/build/vendor/$f"
    [ -f "$local_file" ] || { echo "$f is not in build/vendor (needed to check the hash and record the size)" >&2; exit 1; }
    [ "$(shasum -a 256 "$local_file" | cut -d' ' -f1)" = "$s" ] || { echo "build/vendor/$f does not match its pin" >&2; exit 1; }
    echo "$a.version=$v"
    echo "$a.url=$u$f"
    [ -z "$u2" ] || [ "$u2" = "$u" ] || echo "$a.url2=$u2$f"
    echo "$a.sha256=$s"
    echo "$a.size=$(wc -c < "$local_file" | tr -d ' ')"
  done
} > "$OUT/apps.txt"
[ -z "$KEY" ] || bash "$HERE/sign.sh" "$KEY" "$OUT/apps.txt"
cat "$OUT/apps.txt"
