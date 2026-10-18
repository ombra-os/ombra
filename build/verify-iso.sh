#!/bin/bash
#
# build/verify-iso.sh — verify the local installer ISO against its pin
# (no unpinned artifact is ever booted). Exit: 0 verified, 1 mismatch,
# 2 usage. Env overrides: ISO_DIR, PINS_FILE.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PINS_FILE="${PINS_FILE:-$REPO/build/pins/debian-netinst-arm64.txt}"
if [ $# -ge 1 ]; then PINS_FILE="$1"; fi
ISO_DIR="${ISO_DIR:-$REPO/build/isos}"

pin_get() { # <key>
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$PINS_FILE"
}

if [ ! -f "$PINS_FILE" ]; then
  printf 'FATAL: pin file not found: %s\n' "$PINS_FILE" >&2
  exit 2
fi

PIN_NAME="$(pin_get filename)"
PIN_SHA="$(pin_get sha256)"
PIN_SIZE="$(pin_get size_bytes)"
if [ -z "$PIN_NAME" ] || [ -z "$PIN_SHA" ] || [ -z "$PIN_SIZE" ]; then
  printf 'FATAL: pin file %s is missing filename/sha256/size_bytes\n' "$PINS_FILE" >&2
  exit 2
fi

ISO_PATH="$ISO_DIR/$PIN_NAME"
fail=0

if [ ! -f "$ISO_PATH" ]; then
  printf 'FAIL missing: %s\n' "$ISO_PATH"
  printf '     put the pinned ISO there (see the pin file for its source)\n'
  exit 1
fi

actual_size=$(stat -f %z "$ISO_PATH" 2>/dev/null || echo "")
if [ "$actual_size" != "$PIN_SIZE" ]; then
  printf 'FAIL size: expected %s bytes, got %s\n' "$PIN_SIZE" "${actual_size:-unknown}"
  fail=1
else
  printf 'ok   size: %s bytes\n' "$actual_size"
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha=$(shasum -a 256 "$ISO_PATH" | awk '{ print $1 }')
else
  actual_sha=$(sha256sum "$ISO_PATH" | awk '{ print $1 }')
fi
if [ "$actual_sha" != "$PIN_SHA" ]; then
  printf 'FAIL sha256: expected %s\n         got %s\n' "$PIN_SHA" "$actual_sha"
  fail=1
else
  printf 'ok   sha256: %s\n' "$actual_sha"
fi

if [ "$fail" -ne 0 ]; then
  printf 'RESULT: NOT VERIFIED — do not build from this ISO\n'
  exit 1
fi
printf 'RESULT: verified %s (%s)\n' "$PIN_NAME" "$(pin_get suite)"
exit 0
