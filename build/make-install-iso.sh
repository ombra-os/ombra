#!/bin/bash
# build/make-install-iso.sh <gateway|desktop> — build the ONE self-contained installer ISO:
# the pinned netinst initrd extended with a cpio archive carrying preseed.cfg, ombra/late.sh,
# ombra/rootfs.tar.gz and usr/lib/finish-install.d/08ombra.
# Output: build/disks/ombra-install-<target>.iso

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TARGET="${1:-gateway}"
OUT="$REPO/build/disks"
GRUB_SRC="$REPO/build/installer-grub.cfg"

case "$TARGET" in
  gateway|desktop) ;;
  *) printf 'usage: %s [gateway|desktop]\n' "$0" >&2; exit 2 ;;
esac

case "$TARGET" in
  desktop) VOLID="Ombra-desktop-arm64" ;;
  gateway) VOLID="Ombra-gateway-arm64" ;;
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
cp "$REPO/$TARGET/preseed.cfg" "$STAGE/initrd/preseed.cfg"
if [ -n "$TEST_PASS" ]; then
  HASH="$(printf '%s' "$TEST_PASS" | openssl passwd -6 -stdin)"
  awk -v h="$HASH" '$2=="passwd/user-password-crypted"{print $1" "$2" "$3" "h; next} {print}' \
    "$REPO/$TARGET/preseed.cfg" > "$STAGE/initrd/preseed.cfg"
  grep -qF "$HASH" "$STAGE/initrd/preseed.cfg" || { echo "FATAL: test password hash not applied" >&2; exit 1; }
  awk -v h="$HASH" '$2=="passwd/root-login"{print $1" "$2" "$3" true"; next} $2=="passwd/root-password-crypted"{print $1" "$2" "$3" "h; next} {print}' \
    "$STAGE/initrd/preseed.cfg" > "$STAGE/initrd/preseed.cfg.new" && mv "$STAGE/initrd/preseed.cfg.new" "$STAGE/initrd/preseed.cfg"
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

cp "$REPO/$TARGET/late-command.sh" "$STAGE/initrd/ombra/late.sh"
chmod 0755 "$STAGE/initrd/ombra/late.sh"

# ---- pinned third-party app payloads (desktop only) -------------------------
# staged from build/vendor/ (gitignored), sha256-verified against build/pins/ here and re-verified by late-command.sh inside the installer.
if [ "$TARGET" = desktop ]; then
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
fi

# redundant overlay delivery: d-i executes this hook natively, same stamp guard as preseed/late_command.
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
        echo "08ombra: late.sh FAILED WITHOUT PARKING — DO NOT ship or power off this machine" > /dev/console 2>/dev/null || true
        echo "08ombra: late.sh FAILED WITHOUT PARKING — DO NOT ship or power off this machine" >&2
    }
fi
exit 0
HOOK
chmod 0755 "$STAGE/initrd/usr/lib/finish-install.d/08ombra"

# binary drift guard: each overlay must carry exactly the core/dist binaries
if [ -d "$REPO/core/dist/aarch64" ]; then
    case "$TARGET" in
      desktop) OVERLAY_BINS="usr/local/libexec/ombra/ombra-askpass usr/local/libexec/ombra/ombra-welcome usr/local/bin/ombra usr/local/bin/ombra-statusd" ;;
      gateway) OVERLAY_BINS="usr/local/bin/ombra-torctl-filter" ;;
    esac
    for rel in $OVERLAY_BINS; do
        cmp -s "$REPO/core/dist/aarch64/$(basename "$rel")" "$REPO/$TARGET/rootfs/$rel" \
            || { echo "FATAL: overlay binary $rel differs from core/dist/aarch64 — rerun core/build.sh and reship" >&2; exit 1; }
        if strings "$REPO/$TARGET/rootfs/$rel" | grep -q "$HOME/"; then
            echo "FATAL: overlay binary $rel embeds a build-home path — rebuild with the remapped toolchain" >&2; exit 1
        fi
    done
fi

# --uid 0 --gid 0: uid-501 sudoers drop-ins are silently dropped by sudo; AppleDouble ._ members and .DS_Store must never ship.
COPYFILE_DISABLE=1 tar -czf "$STAGE/initrd/ombra/rootfs.tar.gz" --uid 0 --gid 0 \
    --exclude '._*' --exclude .DS_Store \
    -C "$REPO/$TARGET/rootfs" .

( cd "$STAGE/initrd" && find . | cpio -o -H newc --quiet | gzip ) > "$STAGE/preseed.cgz"

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

rm -f "$ISO"
xorriso \
  -indev "$SRC" -outdev "$ISO" \
  -boot_image isolinux keep \
  -volid "$VOLID" \
  -map "$STAGE/initrd-extended.gz" /install.a64/initrd.gz \
  -map "$GRUB_SRC" /boot/grub/grub.cfg \
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
