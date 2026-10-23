#!/bin/bash
# sign.sh <private-key> <file> — write <file>.sig, a raw Ed25519 signature the images verify with openssl
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: sign.sh <private-key> <file>" >&2; exit 2; }
if [ -n "${OMBRA_KEY_PASS:-}" ]; then export OMBRA_KEY_PASS; openssl pkeyutl -sign -inkey "$1" -passin env:OMBRA_KEY_PASS -rawin -in "$2" -out "$2.sig"
else openssl pkeyutl -sign -inkey "$1" -rawin -in "$2" -out "$2.sig"; fi
echo "signed $2"
