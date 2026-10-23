#!/bin/bash
# keygen.sh <dir> — create the Ed25519 update-signing key pair, once, on an offline machine.
# The private key signs every release and must never leave you; only the public key ships in the images.
set -euo pipefail
DIR="${1:-}"; [ -n "$DIR" ] || { echo "usage: keygen.sh <dir>" >&2; exit 2; }
[ ! -e "$DIR/update-signing.key" ] || { echo "refusing to overwrite $DIR/update-signing.key" >&2; exit 1; }
mkdir -p "$DIR"; chmod 700 "$DIR"
umask 077
# the private key is encrypted with a passphrase you choose (prompted twice); OMBRA_KEY_PASS is for automated tests only
if [ -n "${OMBRA_KEY_PASS:-}" ]; then
  export OMBRA_KEY_PASS
  openssl genpkey -algorithm ed25519 -aes-256-cbc -pass env:OMBRA_KEY_PASS -out "$DIR/update-signing.key"
  openssl pkey -in "$DIR/update-signing.key" -passin env:OMBRA_KEY_PASS -pubout -out "$DIR/update-pubkey.pem"
else
  openssl genpkey -algorithm ed25519 -aes-256-cbc -out "$DIR/update-signing.key"
  openssl pkey -in "$DIR/update-signing.key" -pubout -out "$DIR/update-pubkey.pem"
fi
echo "private key: $DIR/update-signing.key  (passphrase-protected; back it up offline; losing it means no existing install can take a signed update again)"
echo "public key:  $DIR/update-pubkey.pem   (copy to build/update-pubkey.pem and rebuild the images)"
