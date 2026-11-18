#!/bin/bash
# sign-sums.sh <private-key> <SHA256SUMS.txt> — write SHA256SUMS.txt.sig with the update-signing key (sign.sh), so a
# downloader can check the image hashes against the public key instead of trusting the download host.
# Sign after the last exporter run: every export rewrites SHA256SUMS.txt and makes an older .sig stale.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: sign-sums.sh <private-key> <SHA256SUMS.txt>" >&2; exit 2; }
KEY=$1; SUMS=$2
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -s "$SUMS" ] || { echo "FATAL: $SUMS is missing or empty" >&2; exit 1; }
# every line must be "<sha256>  <file name>", and every named archive must be here and match
DIR="$(cd "$(dirname "$SUMS")" && pwd)"
while read -r h n; do
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && [ -n "$n" ] && [[ "$n" != */* ]] || { echo "FATAL: malformed line in $SUMS: $h $n" >&2; exit 1; }
  [ -f "$DIR/$n" ] || { echo "FATAL: $n is listed but missing in $DIR" >&2; exit 1; }
  [ "$(shasum -a 256 "$DIR/$n" | cut -d' ' -f1)" = "$h" ] || { echo "FATAL: $n does not match $SUMS" >&2; exit 1; }
done < "$SUMS"
bash "$HERE/sign.sh" "$KEY" "$SUMS"
echo "publish $SUMS.sig next to $SUMS (scripts/upload-r2.sh picks it up)"
