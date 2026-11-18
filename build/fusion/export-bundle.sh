#!/bin/bash
#
# export-bundle.sh — turn a powered-off, freshly installed VM into a distributable
# .vmwarevm archive. Run AFTER the post-install runbook, BEFORE first boot.
# The archive carries the VM exactly as built, including its ARM guest type, which
# an OVA cannot express. The install itself scrubs the disk; this script strips
# builder residue from a COPY of the bundle, asserts the shipped shape, zips the
# copy, verifies the archive and writes the sums.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VMROOT="${HOME}/Virtual Machines.localized"
# the release version comes from the image itself (1.1 -> 1.1.0 for file names); OMBRA_VERSION overrides
image_version() {
  local v
  v="$(tr -d '[:space:]' < "$REPO/update/rootfs/etc/ombra/version")"
  case "$v" in *.*.*) ;; *.*) v="$v.0" ;; esac
  printf '%s' "$v"
}
VERSION="${OMBRA_VERSION:-$(image_version)}"
OUT_DIR="${OMBRA_RELEASE_DIR:-$REPO/build/releases}"

usage() {
  cat <<EOF2
usage: bash build/fusion/export-bundle.sh <desktop|gateway> [vmx-path]

  VM must be powered OFF and post-install (gateway: post-install first);
  the desktop must never have been booted. Writes
  <outdir>/ombra-<target>-arm64-v$VERSION.vmwarevm.zip, runs verify-bundle.sh on it
  and rewrites <outdir>/SHA256SUMS.txt with one line per archive present.

  env: OMBRA_VERSION (default $VERSION), OMBRA_RELEASE_DIR (default build/releases)

  the single edition ships only as its installer ISO: build/release-single-iso.sh
EOF2
}

fatal() { echo "FATAL: $*" >&2; exit 1; }

TARGET="${1:-}"
case "$TARGET" in desktop|gateway) ;; *) usage; exit 2 ;; esac
SRC_VMX="${2:-$VMROOT/ombra-$TARGET.vmwarevm/ombra-$TARGET.vmx}"
[ -f "$SRC_VMX" ] || fatal "vmx not found: $SRC_VMX"
mkdir -p "$OUT_DIR"

VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
[ -x "$VMRUN" ] || fatal "vmrun not found at: $VMRUN"
RUNNING="$("$VMRUN" -T fusion list 2>&1)" || fatal "vmrun list failed — cannot tell whether the VM is running: $RUNNING"
if printf '%s\n' "$RUNNING" | grep -qF "$SRC_VMX"; then
  fatal "VM is running — power it off first (export is pre-first-boot by design)"
fi
if grep -qE '\-test\.iso' "$SRC_VMX" || grep -qE '^displayName = .*TEST' "$SRC_VMX"; then
  fatal "the vmx references a test-build ISO or is named TEST — test builds are never exported"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
BUNDLE="$STAGE/ombra-$TARGET.vmwarevm"
cp -cR "$(dirname "$SRC_VMX")" "$BUNDLE" 2>/dev/null || cp -R "$(dirname "$SRC_VMX")" "$BUNDLE"
VMX="$BUNDLE/$(basename "$SRC_VMX")"

for pattern in '*.lck' '*.log' '*.bak' '*.scoreboard' '*.plist' '*.vmsd' '*.vmxf' '*.vmss' '*.vmem' '*.vmsn' 'caches' '.DS_Store'; do
  find "${BUNDLE:?}" -maxdepth 1 -name "$pattern" -exec rm -rf {} +
done
sed -E -i '' \
  -e '/^#/d' \
  -e '/^(RemoteDisplay\.|serial[0-9]+\.|uuid\.bios|uuid\.location|checkpoint\.vmState|vmxstats\.filename)/d' \
  -e '/^ethernet[0-9]+\.(generatedAddress|generatedAddressOffset|address) *=/d' \
  -e 's|^(sata0:0\.fileName = ).*|\1"auto detect"|' \
  "$VMX"
grep -qE '^(RemoteDisplay\.|serial[0-9]+\.)' "$VMX" && fatal "debug keys survived the strip — refusing to export"

vmx_put() { # <key> <value>: case-insensitive, spelling-preserving overwrite
  local key="$1" val="$2" k
  k=$(grep -i "^${key} *=" "$VMX" | head -1 | cut -d= -f1 | tr -d ' ' || true)
  if [ -n "$k" ]; then
    sed -i '' -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${k} = \"${val}\"|" "$VMX"
  else
    printf '%s = "%s"\n' "$key" "$val" >> "$VMX"
  fi
}
vmx_put uuid.action keep
# the build pins static MACs; a shipped copy must not, or the strip above leaves "static" with no address and Fusion refuses to start it
for key in $(grep -oE '^ethernet[0-9]+\.addressType' "$VMX" | sort -u); do vmx_put "$key" generated; done
vmx_put snapshot.disabled TRUE
# the installer CD ships as an empty drive on both machines (an image path to a missing ISO only confuses Fusion)
vmx_put sata0:0.deviceType cdrom-raw

PERSONAL='/Us''ers/|/priv''ate/|co''dy|hac''cer'
if grep -rIl -E "$PERSONAL" "$BUNDLE" >/dev/null 2>&1; then
  fatal "personal path or name found in the bundle text files: $(grep -rIl -E "$PERSONAL" "$BUNDLE" | head -3 | tr '\n' ' ')"
fi

vmx_get() { awk -F= -v k="$1" '{kk=$1; gsub(/^[ \t]+|[ \t]+$/, "", kk); if (tolower(kk)==tolower(k)) {v=substr($0, index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v); print v; exit}}' "$VMX"; }
case "$(vmx_get guestOS)" in
  arm-*) ;;
  *) fatal "guestOS is '$(vmx_get guestOS)' — an ARM guest id (arm-*) is required" ;;
esac
if [ "$TARGET" = "desktop" ]; then
  [ "$(vmx_get ethernet0.connectionType)" = "hostonly" ] \
    || fatal "desktop NIC is not on the private link — run the post-install runbook first"
  case "$(vmx_get nvme0:0.mode)" in
    ""|persistent) ;;
    *) fatal "$TARGET disk must stay persistent" ;;
  esac
else
  [ "$(vmx_get ethernet0.connectionType)" = "nat" ] || fatal "gateway upstream NIC must be NAT"
  [ "$(vmx_get ethernet0.virtualDev)" = "vmxnet3" ] || fatal "gateway ethernet0 is not vmxnet3"
  [ "$(vmx_get ethernet1.connectionType)" = "hostonly" ] || fatal "gateway private-link NIC must be hostonly"
  [ "$(vmx_get ethernet1.virtualDev)" = "e1000e" ] || fatal "gateway ethernet1 is not e1000e"
  [ "$(vmx_get ethernet1.startConnected | tr '[:upper:]' '[:lower:]')" = "true" ] \
    || fatal "gateway private-link NIC not connected"
  [ "$(vmx_get memsize)" = "512" ] || fatal "gateway RAM is not the shipped 512 MB — run post-install first"
  [ "$(vmx_get sound.present | tr '[:upper:]' '[:lower:]')" != "true" ] || fatal "the headless gateway has a sound card"
fi
# exactly the shipped NICs: two on the gateway, one on the desktop, never a third
want_nics=2; [ "$TARGET" != gateway ] && want_nics=1
got_nics="$(grep -ciE '^ethernet[0-9]+\.present *= *"true"' "$VMX" || true)"
[ "$got_nics" = "$want_nics" ] || fatal "$TARGET has $got_nics network adapters, want $want_nics"
[ "$(vmx_get sata0:0.startConnected | tr '[:upper:]' '[:lower:]')" = "false" ] || fatal "installer CD still connected"
[ "$(vmx_get bios.bootOrder)" = "hdd,cdrom" ] || fatal "boot order is not hdd-first"
for key in isolation.tools.copy.disable isolation.tools.paste.disable isolation.tools.dnd.disable isolation.tools.hgfs.disable; do
  [ "$(vmx_get "$key" | tr '[:lower:]' '[:upper:]')" = "TRUE" ] || fatal "$key is not TRUE in the vmx"
done
[ "$(vmx_get isolation.tools.setGUIOptions.enable | tr '[:lower:]' '[:upper:]')" = "FALSE" ] \
  || fatal "isolation.tools.setGUIOptions.enable is not FALSE in the vmx"

ARCHIVE="$OUT_DIR/ombra-$TARGET-arm64-v$VERSION.vmwarevm.zip"
rm -f "${ARCHIVE:?}"
echo "archiving $ARCHIVE (the disk is encrypted, so it will not compress)"
# a zip that carries no builder metadata: no macOS uid/gid or extended-time fields (-X), DOS times in UTC from fixed
# mtimes (the local time would give away the builder's time zone); run on the export copy, never the source VM
zip_clean() { # <parent dir> <entry> <out.zip>
  ( cd "$1" && find "$2" -exec env TZ=UTC touch -h -t 202601010000.00 {} + && TZ=UTC zip -X -r -q -1 "$3" "$2" )
}
zip_clean "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")" "$ARCHIVE" \
  || fatal "zip could not create the archive"
[ -s "$ARCHIVE" ] || fatal "the archive is empty"

bash "$HERE/verify-bundle.sh" "$ARCHIVE" || fatal "the archive failed verification"

cd "$OUT_DIR"
: > SHA256SUMS.txt.new
# the single edition's installer ISO (build/release-single-iso.sh) keeps its line too
for f in ombra-*.vmwarevm.zip ombra-*.utm.zip ombra-*.iso; do
  [ -f "$f" ] || continue
  printf '%12s bytes  %s\n' "$(stat -f %z "$f")" "$f"
  shasum -a 256 "$f" >> SHA256SUMS.txt.new
done
mv SHA256SUMS.txt.new SHA256SUMS.txt
echo "done: $TARGET (sums: $OUT_DIR/SHA256SUMS.txt)"
echo "next: sign the sums after the last export (any older SHA256SUMS.txt.sig is now stale): bash scripts/update/sign-sums.sh <private-key> $OUT_DIR/SHA256SUMS.txt"
