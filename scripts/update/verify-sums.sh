#!/bin/bash
# verify-sums.sh <update-pubkey.pem> <SHA256SUMS.txt> — check SHA256SUMS.txt.sig against Ombra's public key, then
# the hash of every listed archive present next to it. Exit 0 only if the signature is good and nothing mismatches.
#
# Needs OpenSSL 3.0 or newer (Ed25519 with pkeyutl -rawin). The openssl that ships with macOS
# (/usr/bin/openssl, LibreSSL 3.3.6 as of macOS 27) cannot load Ed25519 keys, so on a Mac install one first:
#   brew install openssl@3        (or set OPENSSL=/path/to/openssl)
set -euo pipefail
[ $# -eq 2 ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; echo "usage: verify-sums.sh <update-pubkey.pem> <SHA256SUMS.txt>" >&2; exit 2; }
PUB=$1; SUMS=$2; SIG="$2.sig"
[ -f "$SUMS" ] || { echo "FAIL: $SUMS not found" >&2; exit 1; }
[ -f "$SIG" ] || { echo "FAIL: $SIG not found: these hashes are not signed" >&2; exit 1; }
OSSL=""
for c in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl; do
  [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 || continue
  "$c" pkey -pubin -in "$PUB" -noout >/dev/null 2>&1 && { OSSL=$c; break; }
done
[ -n "$OSSL" ] || { echo "FAIL: no openssl here can read the Ed25519 key $PUB (macOS's built-in LibreSSL cannot): brew install openssl@3, or set OPENSSL=" >&2; exit 1; }
"$OSSL" pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$SUMS" -sigfile "$SIG" >/dev/null 2>&1 \
  || { echo "FAIL: the signature on $SUMS is NOT valid: do not use these downloads" >&2; exit 1; }
echo "ok: $SUMS is signed by the Ombra key"
DIR="$(cd "$(dirname "$SUMS")" && pwd)"
bad=0; seen=0
while read -r h n; do
  [ -n "${n:-}" ] || continue
  if [ ! -f "$DIR/$n" ]; then echo "     not downloaded: $n"; continue; fi
  seen=$((seen + 1))
  if [ "$(shasum -a 256 "$DIR/$n" | cut -d' ' -f1)" = "$h" ]; then echo "ok: $n"; else echo "FAIL: $n does not match" >&2; bad=1; fi
done < "$SUMS"
[ "$seen" -gt 0 ] || echo "note: none of the listed archives is next to $SUMS; only the signature was checked"
exit "$bad"
