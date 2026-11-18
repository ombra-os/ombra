#!/bin/bash
#
# release-single-iso.sh — publish the single edition's installer ISO (the only form that edition ships in): copy
# build/disks/ombra-install-single.iso to <outdir>/ombra-single-arm64-v<version>.iso and record its sha256 in
# <outdir>/SHA256SUMS.txt in the exporters' format ("<sha256>  <file>"; a line for the same file is replaced).
# Refuses a TEST ISO: a -test file name, or an initrd that carries the test marker, a preseeded disk passphrase or a
# password hash. Usage: release-single-iso.sh [iso]
# env: OMBRA_VERSION (default: update/rootfs/etc/ombra/version, 1.1 -> 1.1.0), OMBRA_RELEASE_DIR (default build/releases)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
image_version() {
  local v
  v="$(tr -d '[:space:]' < "$REPO/update/rootfs/etc/ombra/version")"
  case "$v" in *.*.*) ;; *.*) v="$v.0" ;; esac
  printf '%s' "$v"
}
VERSION="${OMBRA_VERSION:-$(image_version)}"
OUT_DIR="${OMBRA_RELEASE_DIR:-$REPO/build/releases}"
SRC="${1:-$REPO/build/disks/ombra-install-single.iso}"

fatal() { echo "FATAL: $*" >&2; exit 1; }

case "$VERSION" in ''|*[!0-9.]*) fatal "version '$VERSION' is not a release version (digits and dots)" ;; esac
[ -f "$SRC" ] || fatal "ISO not found: $SRC (build it with: bash build/make-install-iso.sh single)"
case "$(basename "$SRC")" in *-test*|*TEST*) fatal "$SRC is a TEST build — test builds are never released" ;; esac
command -v xorriso >/dev/null || fatal "xorriso not found (brew install xorriso)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

# the ISO must be the single edition's, and its initrd must carry no secret: decompress the whole initrd (the stock
# archive and Ombra's appended one are concatenated gzip members) and look for the markers as plain bytes
volid="$(xorriso -indev "$SRC" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p')"
[ "$volid" = "Ombra-single-arm64" ] || fatal "$SRC is not the single edition's ISO (volume id '${volid:-none}')"
xorriso -osirrox on -indev "$SRC" -extract /install.a64/initrd.gz "$TMP/initrd.gz" >/dev/null 2>&1 \
  || fatal "could not read the installer initrd from $SRC"
gzip -dc "$TMP/initrd.gz" > "$TMP/initrd.cpio" 2>/dev/null || fatal "the installer initrd does not decompress"
grep -aq 'ombra/edition-single' "$TMP/initrd.cpio" || fatal "the initrd carries no single-edition payload"
# the marker is a cpio ENTRY (newc header "070701" + 13 hex fields, then the name): scripts in the initrd mention the
# path (early.sh tests for it), so a plain string match would refuse every real ISO
# (count, not grep -q: -q stops reading early, tr dies of SIGPIPE and pipefail would turn a match into "no match")
if [ "$(LC_ALL=C tr '\0' '\n' < "$TMP/initrd.cpio" | LC_ALL=C grep -acE '070701[0-9A-Fa-f]{104}(\./)?ombra/test-build$')" != 0 ]; then
  fatal "the initrd carries the test-build marker — test builds are never released"
fi
if grep -aqE '^d-i (partman-crypto/passphrase|partman-crypto/passphrase-again|passwd/user-password-crypted|passwd/root-password-crypted string \$)' "$TMP/initrd.cpio" \
   || grep -aqE 'ombra-test-disk|partman-crypto/passphrase password ombra-disk' "$TMP/initrd.cpio"; then
  fatal "the preseed in the initrd carries a disk passphrase or a password hash — not an end-user ISO"
fi

mkdir -p "$OUT_DIR"
NAME="ombra-single-arm64-v$VERSION.iso"
cp "$SRC" "$OUT_DIR/$NAME.part" && mv "$OUT_DIR/$NAME.part" "$OUT_DIR/$NAME" || fatal "could not copy the ISO to $OUT_DIR"
cmp -s "$SRC" "$OUT_DIR/$NAME" || fatal "the copy in $OUT_DIR differs from $SRC"

# the sums: every other line kept, this file's line replaced (the VM exporters rewrite the file and keep ombra-*.iso)
( cd "$OUT_DIR"
  touch SHA256SUMS.txt
  awk -v n="$NAME" '$2 != n' SHA256SUMS.txt > SHA256SUMS.txt.new
  shasum -a 256 "$NAME" >> SHA256SUMS.txt.new
  mv SHA256SUMS.txt.new SHA256SUMS.txt )
printf '%12s bytes  %s\n' "$(stat -f %z "$OUT_DIR/$NAME")" "$OUT_DIR/$NAME"
echo "done: $NAME (sums: $OUT_DIR/SHA256SUMS.txt)"
echo "next: sign the sums (any older SHA256SUMS.txt.sig is now stale): bash scripts/update/sign-sums.sh <private-key> $OUT_DIR/SHA256SUMS.txt"
