#!/bin/bash
# build/make-install-iso.sh <gateway|desktop|single> — build the ONE self-contained installer ISO:
# the pinned netinst initrd extended with a cpio archive carrying preseed.cfg, ombra/late.sh,
# ombra/rootfs.tar.gz and usr/lib/finish-install.d/08ombra.
# single = the desktop payload plus the gateway overlay, the container overlay (gateway/container), the host-side
# overlay (desktop/single) and the ombra/edition-single marker: desktop/late-command.sh builds the gateway container.
# single is the end user's installer: its preseed is desktop/preseed.cfg through single_preseed() below (it asks the
# disk passphrase and the account password, picks the disk, reboots), with its own boot entry, an early size check
# (build/single-iso) and a README.txt at the ISO root. A TEST build (OMBRA_TEST_GUEST_PASSWORD set) stays unattended.
# Output: build/disks/ombra-install-<target>.iso

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TARGET="${1:-gateway}"
# OMBRA_ISO_OUT: another output directory (the tests build their TEST ISOs into a scratch directory)
OUT="${OMBRA_ISO_OUT:-$REPO/build/disks}"
GRUB_SRC="$REPO/build/installer-grub.cfg"
SINGLE_ISO="$REPO/build/single-iso"

case "$TARGET" in
  gateway|desktop|single) ;;
  *) printf 'usage: %s [gateway|desktop|single]\n' "$0" >&2; exit 2 ;;
esac

# SRCDIR: the tree that supplies preseed, late-command and overlay (the single edition IS the desktop install)
case "$TARGET" in
  desktop) VOLID="Ombra-desktop-arm64"; SRCDIR=desktop ;;
  gateway) VOLID="Ombra-gateway-arm64"; SRCDIR=gateway ;;
  single)  VOLID="Ombra-single-arm64";  SRCDIR=desktop; GRUB_SRC="$REPO/build/installer-grub-single.cfg" ;;
esac

command -v xorriso >/dev/null || {
  echo "FATAL: xorriso not found (brew install xorriso)" >&2; exit 1; }

# ---- pinned source netinst ------------------------------------------------
"$REPO/build/verify-iso.sh" || exit 1
SRC="$REPO/build/isos/$(awk -F= '$1=="filename"{print $2}' "$REPO/build/pins/debian-netinst-arm64.txt")"
ISO="$OUT/ombra-install-$TARGET.iso"
TEST_PASS="${OMBRA_TEST_GUEST_PASSWORD:-}"
if [ -n "$TEST_PASS" ]; then
  ISO="$OUT/ombra-install-$TARGET-test.iso"
  echo "TEST BUILD: guest password set for vmrun; output is $ISO and is never exported" >&2
fi
mkdir -p "$OUT"

# ---- assemble the preseed cpio staging tree --------------------------------

STAGE="$(mktemp -d /tmp/ombra-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/initrd/ombra" "$STAGE/initrd/usr/lib/finish-install.d"
mkdir -p "$STAGE/initrd/etc/apt/apt.conf.d"
printf 'Acquire::Retries "6";\n' > "$STAGE/initrd/etc/apt/apt.conf.d/99ombra-retries"

# single_preseed <test disk passphrase or empty>: desktop/preseed.cfg as the single edition's installer, on stdout.
# Every other line stays the desktop's (tests/build/test-install-iso.sh compares them); comments are dropped.
#   - the disk passphrase is asked (twice); a TEST build preseeds its own, never the public build value
#   - weak_passphrase false: a passphrase under 8 characters is asked again (the unlock screen refuses one that short)
#   - the account password is asked (twice); a TEST build keeps the line for the hash set below
#   - no pinned disk: /ombra/early.sh picks it (NVMe under Fusion, virtio under UTM) after checking disk and memory
#   - 512-bit XTS key (d-i's own default is 256); reboot into the system (a TEST build powers off for the build host)
#   - netcfg leaves only loopback: its finish hook would otherwise copy the installer's DHCP profile into NetworkManager
single_preseed() {
  awk -v t="$1" '
    /^#/ { next }
    $2 == "partman-crypto/passphrase" || $2 == "partman-crypto/passphrase-again" { if (t != "") print $1 " " $2 " " $3 " " t; next }
    $2 == "passwd/user-password-crypted" { if (t != "") print; next }
    $2 == "partman-auto/disk" { next }
    $2 == "partman-crypto/weak_passphrase" { print $1 " " $2 " " $3 " false"; next }
    $2 == "debian-installer/exit/poweroff" { print $1 " " $2 " " $3 " " (t != "" ? "true" : "false"); next }
    { print }
    END {
      print ""
      print "### ---- single edition (added by build/make-install-iso.sh) ----"
      print "d-i partman/early_command string sh /ombra/early.sh"
      # no partman-crypto/keysize: partman doubles it for XTS, so its default 256 already makes the 512-bit key
      # (preseeding 512 asks cryptsetup for 1024 and the format fails); late-command parks unless the key is 512 bits
      print "d-i cdrom-detect/eject boolean true"
    }' "$REPO/desktop/preseed.cfg"
}

if [ "$TARGET" = single ]; then
  TEST_DISK=""
  if [ -n "$TEST_PASS" ]; then
    TEST_DISK="${OMBRA_TEST_DISK_PASSPHRASE:-ombra-test-disk}"
    case "$TEST_DISK" in
      ombra-disk) echo "FATAL: OMBRA_TEST_DISK_PASSPHRASE may not be the public build passphrase" >&2; exit 1 ;;
      ????????*) ;;
      *) echo "FATAL: OMBRA_TEST_DISK_PASSPHRASE must have at least 8 characters (the unlock screen refuses fewer)" >&2; exit 1 ;;
    esac
    case "$TEST_DISK" in *[!A-Za-z0-9._-]*) echo "FATAL: OMBRA_TEST_DISK_PASSPHRASE may only use A-Z a-z 0-9 . _ -" >&2; exit 1 ;; esac
    echo "TEST BUILD: the single ISO preseeds the disk passphrase from OMBRA_TEST_DISK_PASSPHRASE (default ombra-test-disk)" >&2
  fi
  single_preseed "$TEST_DISK" > "$STAGE/initrd/preseed.cfg"
else
  cp "$REPO/$SRCDIR/preseed.cfg" "$STAGE/initrd/preseed.cfg"
fi
if [ -n "$TEST_PASS" ]; then
  HASH="$(printf '%s' "$TEST_PASS" | openssl passwd -6 -stdin)"
  awk -v h="$HASH" '$2=="passwd/user-password-crypted"{print $1" "$2" "$3" "h; next} {print}' \
    "$STAGE/initrd/preseed.cfg" > "$STAGE/initrd/preseed.cfg.new" && mv "$STAGE/initrd/preseed.cfg.new" "$STAGE/initrd/preseed.cfg"
  grep -qF "$HASH" "$STAGE/initrd/preseed.cfg" || { echo "FATAL: test password hash not applied" >&2; exit 1; }
  awk -v h="$HASH" '$2=="passwd/root-login"{print $1" "$2" "$3" true"; next} $2=="passwd/root-password-crypted"{print $1" "$2" "$3" "h; next} {print}' \
    "$STAGE/initrd/preseed.cfg" > "$STAGE/initrd/preseed.cfg.new" && mv "$STAGE/initrd/preseed.cfg.new" "$STAGE/initrd/preseed.cfg"
fi

# TEST builds also let the QEMU guest agent run commands and read files, so the host can drive the guest under UTM like vmrun does under Fusion
mkdir -p "$STAGE/extra/etc/qemu"
if [ -n "$TEST_PASS" ]; then
  : > "$STAGE/initrd/ombra/test-build"
  printf '[general]\nallow-rpcs=guest-sync,guest-sync-delimited,guest-ping,guest-info,guest-exec,guest-exec-status,guest-file-open,guest-file-close,guest-file-read,guest-file-write\n' > "$STAGE/extra/etc/qemu/qemu-ga.conf"
else
  rmdir "$STAGE/extra/etc/qemu" "$STAGE/extra/etc" 2>/dev/null || true
fi

# LINT: every preseed line must be <owner> <template> <type> <value>;
while IFS= read -r line; do
  case "$line" in ""|"#"*|" "*|"	"*) continue ;; esac
  set -- $line
  [ $# -ge 3 ] || { echo "FATAL: preseed line has <4 fields: $line" >&2; exit 1; }
  case "$3" in
    string|boolean|select|multiselect|text|password|note|seen) ;;
    *) echo "FATAL: preseed line bad type '$3': $line" >&2; exit 1 ;;
  esac
done < "$STAGE/initrd/preseed.cfg"

cp "$REPO/$SRCDIR/late-command.sh" "$STAGE/initrd/ombra/late.sh"
chmod 0755 "$STAGE/initrd/ombra/late.sh"

# single: the early disk/memory check and its dialog (d-i's startup hook S20templates loads /var/lib/dpkg/info/*.templates)
if [ "$TARGET" = single ]; then
  cp "$SINGLE_ISO/early.sh" "$STAGE/initrd/ombra/early.sh"
  chmod 0755 "$STAGE/initrd/ombra/early.sh"
  mkdir -p "$STAGE/initrd/var/lib/dpkg/info"
  cp "$SINGLE_ISO/ombra-single.templates" "$STAGE/initrd/var/lib/dpkg/info/ombra-single.templates"
  # an end user's ISO carries no secret: no passphrase, no password hash, no test marker
  if [ -z "$TEST_PASS" ]; then
    if grep -qE '^[^#]*(partman-crypto/passphrase|passwd/user-password-crypted|passwd/root-password |ombra-disk|ombra-test-disk)' "$STAGE/initrd/preseed.cfg" \
       || grep -q '\$[0-9a-z]*\$' "$STAGE/initrd/preseed.cfg" || [ -e "$STAGE/initrd/ombra/test-build" ]; then
      echo "FATAL: the single ISO's preseed carries a passphrase, a password or a test marker" >&2; exit 1
    fi
  fi
fi

# ---- pinned third-party app payloads (desktop and single) --------------------
# staged from build/vendor/ (gitignored), sha256-verified against build/pins/ here and re-verified by late-command.sh inside the installer.
if [ "$SRCDIR" = desktop ]; then
    mkdir -p "$STAGE/initrd/ombra/vendor"
    stage_pinned() {  # $1 pin name, $2 filename in build/vendor
        local pin="$1" file="$2" want got
        want="$(awk -F= '$1=="sha256"{print $2}' "$REPO/build/pins/$pin.txt")"
        [ -n "$want" ] || { echo "FATAL: build/pins/$pin.txt has no sha256" >&2; exit 1; }
        [ -f "$REPO/build/vendor/$file" ] || {
            echo "FATAL: build/vendor/$file missing — fetch+verify it per build/pins/$pin.txt" >&2
            exit 1; }
        got="$(shasum -a 256 "$REPO/build/vendor/$file" | awk '{print $1}')"
        [ "$got" = "$want" ] || {
            echo "FATAL: build/vendor/$file sha256 mismatch" >&2
            echo "       got  $got" >&2
            echo "       want $want  (see build/pins/$pin.txt)" >&2
            exit 1; }
        cp "$REPO/build/vendor/$file" "$STAGE/initrd/ombra/vendor/$file"
        printf '  staged %s (%s bytes, sha256 pinned)\n' "$file" "$(stat -f %z "$REPO/build/vendor/$file")"
    }
    stage_pinned torbrowser "$(awk -F= '$1=="file"{print $2}' "$REPO/build/pins/torbrowser.txt")"
    # the expected hash travels INTO the initrd for the in-installer re-verify
    cp "$REPO/build/pins/torbrowser.txt" "$STAGE/initrd/ombra/vendor/torbrowser.sha256"
    for app in feather simplex electrum; do
        stage_pinned "$app" "$(awk -F= '$1=="file"{print $2}' "$REPO/build/pins/$app.txt")"
        cp "$REPO/build/pins/$app.txt" "$STAGE/initrd/ombra/vendor/$app.sha256"
    done
fi

# overlay delivery: d-i runs finish-install.d hooks natively; late.sh is stamp-guarded and parks on any failure.
cat > "$STAGE/initrd/usr/lib/finish-install.d/08ombra" <<'HOOK'
#!/bin/sh
cat > /usr/lib/finish-install.d/10apt-cdrom-setup <<'FAST'
#!/bin/sh
sed -i "/^deb cdrom:/s/^/#/" /target/etc/apt/sources.list
exit 0
FAST
HOOK
if [ -z "$TEST_PASS" ]; then
cat >> "$STAGE/initrd/usr/lib/finish-install.d/08ombra" <<'HOOK'
cat > /usr/lib/finish-install.d/94save-logs <<'NOLOGS'
#!/bin/sh
exit 0
NOLOGS
HOOK
fi
cat >> "$STAGE/initrd/usr/lib/finish-install.d/08ombra" <<'HOOK'
if [ ! -e /target/var/lib/ombra/late-ran ] && [ -x /ombra/late.sh ]; then
    /ombra/late.sh || {
        # late.sh parks itself; this is the backstop: never let a failed run reach the power-off
        db_set debian-installer/exit/poweroff false >/dev/null 2>&1 || true
        while :; do
            echo "08ombra: late.sh FAILED — install parked; DO NOT ship this machine" > /dev/console 2>/dev/null || true
            sleep 60
        done
    }
fi
exit 0
HOOK
chmod 0755 "$STAGE/initrd/usr/lib/finish-install.d/08ombra"

# binary drift guard: each overlay must carry exactly the core/dist binaries (single carries both overlays)
if [ -d "$REPO/core/dist/aarch64" ]; then
    case "$TARGET" in
      single) DRIFT_TREES="desktop gateway" ;;
      *)      DRIFT_TREES="$TARGET" ;;
    esac
    for tree in $DRIFT_TREES; do
        case "$tree" in
          desktop) OVERLAY_BINS="usr/local/libexec/ombra/ombra-askpass usr/local/libexec/ombra/ombra-welcome usr/local/bin/ombra usr/local/bin/ombra-statusd" ;;
          gateway) OVERLAY_BINS="usr/local/bin/ombra usr/local/bin/ombra-torctl-filter" ;;
        esac
        for rel in $OVERLAY_BINS; do
            cmp -s "$REPO/core/dist/aarch64/$(basename "$rel")" "$REPO/$tree/rootfs/$rel" \
                || { echo "FATAL: $tree overlay binary $rel differs from core/dist/aarch64 — rerun core/build.sh and reship" >&2; exit 1; }
            if strings "$REPO/$tree/rootfs/$rel" | grep -q "$HOME/"; then
                echo "FATAL: $tree overlay binary $rel embeds a build-home path — rebuild with the remapped toolchain" >&2; exit 1
            fi
        done
    done
fi

# --uid 0 --gid 0: uid-501 sudoers drop-ins are silently dropped by sudo; AppleDouble ._ members and .DS_Store must never ship.
# the updater overlay (shared by both machines) and the release public key ride in the same tarball
UPDATE_PUBKEY="${OMBRA_UPDATE_PUBKEY:-$REPO/build/update-pubkey.pem}"
[ -f "$UPDATE_PUBKEY" ] || { echo "FATAL: update public key missing: $UPDATE_PUBKEY (scripts/update/keygen.sh creates the pair)" >&2; exit 1; }
openssl pkey -pubin -in "$UPDATE_PUBKEY" -noout 2>/dev/null || { echo "FATAL: $UPDATE_PUBKEY is not a public key" >&2; exit 1; }
mkdir -p "$STAGE/extra/usr/share/ombra"
cp "$UPDATE_PUBKEY" "$STAGE/extra/usr/share/ombra/update-pubkey.pem"
chmod 0644 "$STAGE/extra/usr/share/ombra/update-pubkey.pem"
pack_overlay() {  # $1 output tarball, $2 machine tree (gateway|desktop): the overlay exactly as that machine's ISO packs it
    COPYFILE_DISABLE=1 tar -czf "$1" --uid 0 --gid 0 \
        --exclude '._*' --exclude .DS_Store \
        -C "$REPO/$2/rootfs" . -C "$REPO/update/rootfs" . -C "$STAGE/extra" .
}
pack_overlay "$STAGE/initrd/ombra/rootfs.tar.gz" "$SRCDIR"

# single edition: the gateway overlay (as the gateway ISO packs it), the container overlay (etc/ only: its README stays
# in the repo), the host-side overlay that only this edition carries, and the marker late-command keys on
if [ "$TARGET" = single ]; then
    pack_overlay "$STAGE/initrd/ombra/gateway-rootfs.tar.gz" gateway
    COPYFILE_DISABLE=1 tar -czf "$STAGE/initrd/ombra/gateway-container.tar.gz" --uid 0 --gid 0 \
        --exclude '._*' --exclude .DS_Store -C "$REPO/gateway/container" ./etc
    COPYFILE_DISABLE=1 tar -czf "$STAGE/initrd/ombra/single-rootfs.tar.gz" --uid 0 --gid 0 \
        --exclude '._*' --exclude .DS_Store -C "$REPO/desktop/single" .
    : > "$STAGE/initrd/ombra/edition-single"
fi

# pipefail only here: a failed find or cpio must not leave a truncated archive that gzip alone reports as success
# owned root:root (not the builder's macOS uid), and no file name or time in the gzip header
( set -o pipefail; cd "$STAGE/initrd" && bsdtar -c --format newc --uid 0 --gid 0 --uname root --gname root -f - . | gzip -n ) > "$STAGE/preseed.cgz" \
    || { echo "FATAL: packing the initrd extension failed" >&2; exit 1; }

# self-check: the packed preseed must hash equal to the source.
rm -rf "$STAGE/verify"; mkdir -p "$STAGE/verify"
( cd "$STAGE/verify" && gzip -dc "$STAGE/preseed.cgz" | cpio -id --quiet ) >/dev/null 2>&1
cmp -s "$STAGE/verify/preseed.cfg" "$STAGE/initrd/preseed.cfg" || {
  echo "FATAL: packed preseed.cfg != staged preseed.cfg" >&2; exit 1; }

# ---- extend the installer initrd (kernel-native concatenation) -------------

# the kernel unpacks a sequence of concatenated compressed cpio archives (Debian's documented preseeding mechanism).
xorriso -osirrox on -indev "$SRC" -extract /install.a64/initrd.gz "$STAGE/initrd.gz" >/dev/null 2>&1
[ -s "$STAGE/initrd.gz" ] || { echo "FATAL: could not extract initrd.gz from the source ISO" >&2; exit 1; }
cat "$STAGE/initrd.gz" "$STAGE/preseed.cgz" > "$STAGE/initrd-extended.gz"

# ---- write the ISO: xorriso preserves the El Torito/EFI boot equipment ------

# single: the end user's README replaces Debian's at the ISO root
README_SRC=""
[ "$TARGET" != single ] || README_SRC="$SINGLE_ISO/README.txt"
rm -f "$ISO"
xorriso \
  -indev "$SRC" -outdev "$ISO" \
  -boot_image isolinux keep \
  -volid "$VOLID" \
  -map "$STAGE/initrd-extended.gz" /install.a64/initrd.gz \
  -map "$GRUB_SRC" /boot/grub/grub.cfg \
  ${README_SRC:+-map "$README_SRC" /README.txt} \
  -chown_r 0 / -- -chgrp_r 0 / -- \
  >/dev/null

# ---- verify our own output ---------------------------------------------------

GOT_INITRD=$(xorriso -osirrox on -indev "$ISO" -ls /install.a64 2>/dev/null | awk '{print $NF}' | grep -c initrd.gz || true)
GOT_GRUB=$(xorriso -osirrox on -indev "$ISO" -ls /boot/grub 2>/dev/null | grep -c grub.cfg || true)
xorriso -osirrox on -indev "$ISO" -extract /install.a64/initrd.gz "$STAGE/out-initrd.gz" >/dev/null 2>&1
SIZE_IN=$(stat -f %z "$STAGE/initrd-extended.gz"); SIZE_OUT=$(stat -f %z "$STAGE/out-initrd.gz")
[ "$GOT_INITRD" = 1 ] && [ "$GOT_GRUB" = 1 ] && [ "$SIZE_IN" = "$SIZE_OUT" ] || {
  echo "FATAL: output ISO verification failed (initrd/grub/size)" >&2; exit 1; }

printf 'built %s (%s bytes): initrd +%s bytes of preseed payload, boot equipment preserved\n' \
  "$ISO" "$(stat -f %z "$ISO")" "$(stat -f %z "$STAGE/preseed.cgz")"
