#!/bin/bash
# tests/build/test-install-iso.sh — offline test for the single-ISO installer builder
# (preseed carried verbatim in the initrd's appended cpio segment; unattended grub).
# Requires: xorriso + the pinned netinst in build/isos/.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d /tmp/ombra-isotest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

command -v xorriso >/dev/null || { echo "FAIL: xorriso missing (brew install xorriso)"; exit 1; }

echo "== public hygiene (leak guard, before any slow step) =="
if bash "$REPO/tests/build/test-public-hygiene.sh"; then
  ok "public hygiene clean"
else
  bad "public hygiene found leaks"; exit 1
fi

SRC="$REPO/build/isos/$(awk -F= '$1=="filename"{print $2}' "$REPO/build/pins/debian-netinst-arm64.txt")"
[ -f "$SRC" ] || { echo "FAIL: pinned netinst missing from build/isos/ ($SRC)"; exit 1; }

stock_initrd() { # extract the stock initrd size
  xorriso -osirrox on -indev "$SRC" -extract /install.a64/initrd.gz "$TMP/stock.gz" >/dev/null 2>&1
  stat -f %z "$TMP/stock.gz"
}
STOCK=$(stock_initrd)

echo "== build both targets =="
for t in gateway desktop; do
  if bash "$REPO/build/make-install-iso.sh" "$t" > "$TMP/build-$t.log" 2>&1; then
    ok "$t ISO built"
  else
    bad "$t build failed:"; sed 's/^/       /' "$TMP/build-$t.log" | tail -5; exit 1
  fi
done

echo "== ISO volume id =="
for t in gateway desktop; do
  ISO="$REPO/build/disks/ombra-install-$t.iso"
  got="$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p')"
  [ "$got" = "Ombra-$t-arm64" ] \
    && ok "$t volume id: $got" \
    || bad "$t volume id is '${got:-none}', want Ombra-$t-arm64 (Debian's PVD leaked through)"
done

echo "== one ISO, no second-disc/HTTP artifacts =="
for t in gateway desktop; do
  [ -f "$REPO/build/disks/ombra-install-$t.iso" ] && ok "ombra-install-$t.iso" || bad "ombra-install-$t.iso missing"
done
[ -e "$REPO/build/disks/preseed-gateway.iso" ] && bad "second-disc artifact preseed-gateway.iso exists" || ok "no second-disc artifacts"
[ -e "$REPO/build/serve" ] && bad "build/serve (HTTP preseed staging) exists" || ok "no HTTP-preseed artifacts"

echo "== payload segment per target (wrong-payload guard) =="
for t in gateway desktop; do
  ISO="$REPO/build/disks/ombra-install-$t.iso"
  xorriso -osirrox on -indev "$ISO" -extract /install.a64/initrd.gz "$TMP/$t.gz" >/dev/null 2>&1
  CGZ=$(( $(stat -f %z "$TMP/$t.gz") - STOCK ))
  [ "$CGZ" -gt 1000 ] || { bad "$t: initrd not extended (+${CGZ}B)"; continue; }
  tail -c "$CGZ" "$TMP/$t.gz" > "$TMP/$t.seg"
  mkdir -p "$TMP/x-$t"
  ( cd "$TMP/x-$t" && gzip -dc "$TMP/$t.seg" | cpio -id --quiet ) >/dev/null 2>&1
  [ "$(cat "$TMP/x-$t/preseed.cfg")" = "$(cat "$REPO/$t/preseed.cfg")" ] \
    && ok "$t initrd carries $t/preseed.cfg verbatim" \
    || bad "$t payload differs from $t/preseed.cfg"
done
cmp -s "$TMP/gateway.seg" "$TMP/desktop.seg" \
  && bad "gateway and desktop payloads are identical (per-target split broken)" \
  || ok "per-target payloads differ"

echo "== payload members =="
CGZ=$(( $(stat -f %z "$TMP/gateway.gz") - STOCK ))
for m in "./preseed.cfg" "./ombra/late.sh" "./ombra/rootfs.tar.gz" "./usr/lib/finish-install.d/08ombra"; do
  ( cd "$TMP/x-gateway" && gzip -dc "$TMP/gateway.seg" | cpio -it 2>/dev/null | grep -qx "$m" ) \
    && ok "$m" || bad "$m missing from payload"
done
[ -x "$TMP/x-gateway/ombra/late.sh" ] && ok "late.sh executable" || bad "late.sh not executable"
[ -x "$TMP/x-gateway/usr/lib/finish-install.d/08ombra" ] && ok "hook executable" || bad "hook not executable"
# a late.sh failure must be LOUD: the hook must carry the no-park scream.
grep -q 'FAILED WITHOUT PARKING' "$TMP/x-gateway/usr/lib/finish-install.d/08ombra" \
  && ok "08ombra screams on the console if late.sh fails without parking" \
  || bad "08ombra failure branch missing — FATALs would be swallowed"

echo "== grub.cfg =="
xorriso -osirrox on -indev "$REPO/build/disks/ombra-install-gateway.iso" -extract /boot/grub/grub.cfg "$TMP/g.cfg" >/dev/null 2>&1
grep -q 'menuentry "ombra install (unattended)"' "$TMP/g.cfg" \
  && ok "unattended entry present" || bad "grub.cfg lacks the unattended entry"
grep -q "auto=true priority=critical" "$TMP/g.cfg" \
  && ok "auto=true priority=critical" || bad "grub.cfg lacks unattended params"
for cfg in "$REPO/build/installer-grub.cfg" "$TMP/g.cfg"; do
  if grep -q 'console=ttyAMA0' "$cfg"; then
    bad "serial console on the installer boot path: $cfg"
  elif ! grep -q 'console=tty0' "$cfg"; then
    bad "no display console on the installer boot path: $cfg"
  else
    ok "grub console=tty0 only (no serial channel): $(basename "$cfg")"
  fi
done
echo
# no early exit: the FAIL count is enforced at the very end

# ---- late-command shell hygiene: no escaped-quote junk, heredocs closed ----
for f in "$REPO/gateway/late-command.sh" "$REPO/desktop/late-command.sh"; do
  if grep -q "\\\\'" "$f"; then
    echo "  FAIL escaped-quote junk in $f (heredoc-delimiter corruption class)"
    exit 1
  fi
  bad=0
  while IFS= read -r line; do
    d=$(printf '%s\n' "$line" | sed -n "s/.*<<'\([A-Za-z0-9_]*\)'.*/\1/p")
    [ -n "$d" ] || continue
    grep -qx "$d" "$f" || bad=1
  done < "$f"
  if [ "$bad" = 1 ]; then
    echo "  FAIL unterminated heredoc in $f"
    exit 1
  fi
done
echo "  ok   late-commands: no quote junk, heredocs closed"

# parser-state walker: catches corruption classes bash -n passes
python3 "$REPO/tests/build/late-command-walker.py" \
    "$REPO/gateway/late-command.sh" "$REPO/desktop/late-command.sh" \
  && echo "  ok   late-commands: parser-state clean" || exit 1

# the desktop vmx must not pin the guest display mode: Fusion auto-fit is the product posture
if grep -qi 'fitGuestUsingNativeDisplayResolution' "$REPO/build/fusion/create-desktop-vm.sh"; then
  echo "  FAIL create-desktop-vm.sh pins the guest display mode (fitGuestUsingNativeDisplayResolution)"
  exit 1
fi
echo "  ok   desktop vmx leaves the display mode to Fusion auto-fit"
# host time sync stays OFF: tools.syncTime=TRUE fights the time.synchronize.*=FALSE set
if grep -qEi 'tools\.syncTime[[:space:]]*=[[:space:]]*"TRUE"' "$REPO/build/fusion/create-desktop-vm.sh" \
   || grep -q 'syncTime TRUE' "$REPO/build/fusion/create-desktop-vm.sh"; then
  echo "  FAIL create-desktop-vm.sh turns host time sync ON (tools.syncTime TRUE)"
  exit 1
fi
if grep -q 'tools.syncTime = "FALSE"' "$REPO/build/fusion/create-desktop-vm.sh"; then
  echo "  ok   desktop vmx: host time sync OFF (tools.syncTime=FALSE)"
else
  echo "  FAIL create-desktop-vm.sh lost the tools.syncTime=FALSE pin"
  exit 1
fi


# ---- ombra-boot ships; plymouth/old-firstuse are gone ----
T2=$(mktemp -d)
( cd "$T2" && gzip -dc "$TMP/desktop.seg" | cpio -id --quiet ) >/dev/null 2>&1
( cd "$T2" && tar -xzf ./ombra/rootfs.tar.gz ) >/dev/null 2>&1
for f in ./usr/local/libexec/ombra/ombra-askpass ./usr/local/libexec/ombra/ombra-welcome \
         ./etc/systemd/system/ombra-setup-gate.service \
         ./etc/systemd/system/ombra-welcome.service \
         ./etc/systemd/system/ombra-askpass.service \
         ./etc/systemd/system/ombra-askpass-fallback.service \
         ./etc/systemd/system/sddm.service.d/10-ombra-firstuse.conf \
         ./usr/share/initramfs-tools/hooks/ombra-askpass \
         ; do
  if [ -e "$T2/$f" ]; then ok "desktop ships $f"; else bad "desktop MISSING $f (ombra-boot delivery broken)"; fi
done
for f in ./usr/share/initramfs-tools/hooks/ombra-askpass \
         ; do
  if [ -x "$T2/$f" ]; then ok "executable in initrd build/boot: $f"; else bad "NOT executable: $f"; fi
done
if [ -e "$T2/usr/share/plymouth" ]; then bad "plymouth theme still in overlay"; else ok "no plymouth in overlay"; fi
if [ -e "$T2/usr/local/sbin/ombra-firstuse" ]; then bad "old firstuse still in overlay"; else ok "old firstuse gone"; fi
# units must gate on the RUNTIME marker only — no persistent stamp
if grep -rq 'first-use-done' "$T2/etc/systemd/" 2>/dev/null; then
  bad "persistent first-use stamp referenced in units (design regression)"
else
  ok "units gate on /run marker only (disk is the state)"
fi
# ombra owns unlock retries, never the initramfs shell
if grep -q 'tries=0' "$REPO/desktop/late-command.sh"; then
  ok "crypttab wires tries=0 (ombra owns unlock retries)"
else
  bad "tries=0 missing from crypttab wiring (3-strike shell lockout)"
fi
if grep -q 'x-initrd.attach,keyscript=/usr/local/libexec/ombra/ombra-askpass,tries=0' "$REPO/desktop/late-command.sh"; then
  ok "crypttab wires the full pinned option tuple"
else
  bad "x-initrd.attach/keyscript tuple missing from crypttab wiring"
fi
if sh "$REPO/tests/build/test-crypttab-wiring.sh"; then
  ok "crypttab wiring functional test"
else
  bad "crypttab wiring functional test failed"
fi
# plymouth purged AND masked at install time
if grep -qE 'purge(_present)? .*plymouth' "$REPO/desktop/late-command.sh" && grep -q 'plymouth-quit-wait' "$REPO/desktop/late-command.sh"; then
  ok "plymouth purged + quit units masked at install"
else
  bad "plymouth purge/mask missing from late.sh"
fi
# ---- the session-stack kill class: a capped or swallowed transaction ships ----
# ---- half a desktop (sddm up, plasma missing)                                ----
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'timeout 420'; then
  bad "desktop late.sh still caps the session transaction (timeout 420 = the half-landed-desktop bomb)"
else
  ok "desktop session transaction runs uncapped"
fi
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'Acquire::Retries=3' \
   && grep -q 'ombra-session-failed' "$REPO/desktop/late-command.sh" \
   && ! grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'dpkg-query'; then
  ok "desktop session stack: apt retries, transaction failure parks the install, no probe sensors"
else
  bad "desktop session-stack gate drifted — probe sensors must stay deleted (they lie via in-target)"
fi
if grep -vE '^\s*#' "$REPO/gateway/late-command.sh" | grep -q 'timeout 300 dpkg --configure'; then
  bad "gateway late.sh still caps dpkg --configure -a (a killed configure is corruption)"
else
  ok "gateway dpkg --configure -a uncapped"
fi
# ---- the drkonqi cascade class: plasma-workspace HARD depends on drkonqi ----
# ---- so purging it removes the desktop                                    ----
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'purge -y drkonqi'; then
  bad "desktop late.sh purges drkonqi (plasma-workspace hard-depends on it — the cascade ships a desktopless machine)"
else
  ok "desktop late.sh never purges drkonqi (the cascade class is dead)"
fi
if grep -q 'drkonqi-sentry-postman.timer' "$REPO/desktop/late-command.sh" \
   && grep -q 'drkonqi-coredump-launcher@.service' "$REPO/desktop/late-command.sh"; then
  ok "drkonqi sentry/coredump units masked unconditionally at install"
else
  bad "drkonqi unit masks missing — the hourly Sentry timer could re-arm"
fi
# ---- the gutless-initrd class: late.sh must OWN the unlock engine ----
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'apt-get install -y --no-install-recommends -o APT::ExtractTemplates::TempDir=/var/tmp cryptsetup-initramfs' \
   && grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'apt-get update'; then
  ok "late.sh ensures cryptsetup-initramfs before the initrd rebuild (index refreshed, staging on the root LV)"
else
  bad "late.sh does not ensure cryptsetup-initramfs — d-i drift can ship a gutless initrd again"
fi
# the ENGINE gate: Debian's cryptroot script must be IN the rebuilt initrd.
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'scripts/local-top/cryptroot'; then
  ok "late.sh gates on cryptroot being IN the rebuilt initrd (the engine, not just our binary)"
else
  bad "engine gate missing — a crypt-less initrd with our binary check alone ships unbootable machines"
fi
# a FATAL must PARK the installer (exit codes are swallowed) and put the reason ON SCREEN:
# d-i's frontend repaints over tty1, so the park must switch to the syslog VT.
if grep -vE '^\s*#' "$REPO/desktop/late-command.sh" | grep -q 'debian-installer/exit/poweroff false' \
   && grep -q '^ombra_fatal()' "$REPO/desktop/late-command.sh" \
   && grep -A6 '^ombra_fatal()' "$REPO/desktop/late-command.sh" | grep -q 'chvt 3'; then
  ok "late.sh FATALs park the installer on a visible VT (poweroff off, chvt 3)"
else
  bad "FATAL park mechanism missing or invisible — failures power off and ship bricks"
fi

# ---- Plasma/X11 session stack ----
PKGSEL="$(grep '^d-i pkgsel/include' "$REPO/desktop/preseed.cfg")"
[ -n "$PKGSEL" ] || bad "pkgsel/include line missing from desktop preseed"
for w in lightdm lightdm-gtk-greeter foot; do
  if echo "$PKGSEL" | grep -qw "$w"; then bad "pkgsel still carries $w"; else ok "pkgsel: $w gone"; fi
done
# sddm is enabled by its own package postinst, not by late.sh; assert only the invariant: no other DM is enabled anywhere.
if ! grep -qE '^\s*(in-target )?systemctl (enable|disable) .*(lightdm|hypr)' "$REPO/desktop/late-command.sh" \
   && ! grep -qE '^d-i.*lightdm' "$REPO/desktop/preseed.cfg"; then
  ok "late.sh: no DM enable at all (sddm postinst owns it); lightdm never enabled"
else
  bad "late.sh/preseed enable a display manager other than sddm's postinst"
fi
if grep -q 'kde-plasma-desktop sddm kwin-x11 kitty qt-style-kvantum' "$REPO/desktop/late-command.sh"; then
  ok "late.sh session transaction carries the plasma stack"
else
  bad "late.sh session transaction missing the plasma package set"
fi
if grep -qE 'Install-Recommends=false' "$REPO/desktop/late-command.sh"; then
  ok "session transaction runs recommends-off (no app-suite pull-in)"
else
  bad "session transaction lacks Install-Recommends=false"
fi
for w in hyprland-guiutils swaybg mako-notifier xdg-desktop-portal-hyprland; do
  if grep -q "$w" "$REPO/desktop/late-command.sh"; then bad "late.sh still references $w"; else ok "late.sh: $w gone"; fi
done
if grep -q 'sources.list.d/trixie-backports' "$REPO/desktop/late-command.sh"; then
  bad "late.sh still wires the trixie-backports source"
else
  ok "late.sh: no backports source wiring"
fi
if grep -q 'plasma-discover kdeconnect' "$REPO/desktop/late-command.sh" \
   && grep -q 'kdeconnectd.service' "$REPO/desktop/late-command.sh"; then
  ok "late.sh purges/masks discover + kdeconnect"
else
  bad "session privacy belt (discover/kdeconnect purge+mask) missing"
fi
# klipper persists clipboard history to ~/.local/share/klipper (sqlite): the overlay must
# strip the applet's tray eligibility AND carry the no-history rc
CLIPMETA="$REPO/desktop/rootfs/usr/share/plasma/plasmoids/org.kde.plasma.clipboard/metadata.json"
if [ -f "$CLIPMETA" ] \
   && ! grep -q 'NotificationAreaCategory' "$CLIPMETA" \
   && grep -q '"EnabledByDefault": false' "$CLIPMETA" \
   && grep -q 'KeepClipboardContents=false' "$REPO/desktop/rootfs/etc/skel/.config/klipperrc" \
   && grep -q 'MaxClipItems=1' "$REPO/desktop/rootfs/etc/skel/.config/klipperrc"; then
  ok "clipboard: tray applet de-registered + klipper keeps no history on disk"
else
  bad "clipboard privacy belt missing (metadata override and/or klipperrc)"
fi

# ---- the vendored Plasma session (overlay layer) ---------------------------
for f in ./etc/sddm.conf.d/50-ombra.conf \
         ./etc/systemd/system/sddm.service.d/10-ombra-firstuse.conf \
         ./usr/share/plasma/look-and-feel/com.github.vinceliuice.Colloid-dark/contents/defaults \
         ./usr/share/plasma/look-and-feel/com.github.vinceliuice.Colloid-dark/contents/layouts/org.kde.plasma.desktop-layout.js \
         ./usr/share/plasma/desktoptheme/Colloid-dark/metadata.desktop \
         ./usr/share/aurorae/themes/Colloid-dark/metadata.desktop \
         ./usr/share/color-schemes/ColloidDark.colors \
         ./usr/share/Kvantum/ColloidDark/ColloidDark.kvconfig \
         ./usr/share/sddm/themes/Colloid-dark/metadata.desktop \
         ./usr/share/sddm/themes/Colloid-dark/background.png \
         ./usr/share/sddm/faces/ombra.face.icon \
         ./etc/skel/.face.icon \
         ./usr/share/icons/phinger-cursors-light/index.theme \
         ./usr/share/icons/Kaze-dark/index.theme \
         ./usr/share/ombra-assets/Kaze-GPL-3.0 \
         ./usr/share/ombra-assets/phinger-cursors-CC-BY-SA-4.0 \
         ./usr/local/share/applications/kitty.desktop \
         ./usr/share/plasma/plasmoids/luisbocanegra.panel.colorizer/metadata.json \
         ./usr/share/plasma/plasmoids/org.ombra.status/metadata.json \
         ./usr/share/plasma/plasmoids/org.ombra.status/contents/ui/main.qml \
         ./usr/share/plasma/plasmoids/org.ombra.status/contents/config/main.xml \
         ./usr/local/bin/ombra-led-ensure \
         ./etc/skel/.config/autostart/org.ombra.status-ensure.desktop \
         ./usr/share/fonts/ombra/jetbrainsmono-nerdfont/JetBrainsMonoNerdFont-Regular.ttf \
         ./etc/skel/.config/kdedefaults/package \
         ./etc/skel/.config/kdedefaults/kdeglobals \
         ./etc/skel/.config/kdedefaults/kwinrc \
         ./etc/skel/.config/kdedefaults/kcminputrc \
         ./etc/skel/.config/kdedefaults/plasmarc \
         ./etc/skel/.config/baloofilerc \
         ./etc/skel/.config/kscreenlockerrc \
         ./etc/skel/.config/kitty/kitty.conf \
         ./etc/skel/.config/Kvantum/kvantum.kvconfig \
         ./etc/skel/.local/state/UserFeedback.org.kde.plasmashell \
         ./etc/NetworkManager/system-connections/ombra-intnet.nmconnection \
         ./etc/NetworkManager/conf.d/10-ombra-no-auto-default.conf \
         ./etc/skel/.config/klipperrc \
         ./usr/share/plasma/plasmoids/org.kde.plasma.clipboard/metadata.json \
         ; do
  if [ -e "$T2/$f" ]; then ok "session ships $f"; else bad "session MISSING $f"; fi
done
# kitty glass pinned at 88%
KCONF="$T2/etc/skel/.config/kitty/kitty.conf"
if grep -qE '^[[:space:]]*background_opacity[[:space:]]+0\.88[[:space:]]*$' "$KCONF" \
   && grep -qE '^window_padding_width[[:space:]]+14' "$KCONF"; then
  ok "kitty ships at 88% opacity with 14px padding"
else
  bad "kitty background_opacity is not 0.88 or padding lost — the terminal glass regressed"
fi
if grep -q 'ConditionPathExists=/run/ombra/setup-complete' "$T2/etc/systemd/system/sddm.service.d/10-ombra-firstuse.conf" \
   && ! grep -rq 'first-use-done' "$T2/etc/systemd/" 2>/dev/null; then
  ok "sddm gated on the /run marker (no persistent stamp)"
else
  bad "sddm firstuse gate wrong or stale stamp reference"
fi
SDDM_CONF="$T2/etc/sddm.conf.d/50-ombra.conf"
if grep -q 'DisplayServer=x11' "$SDDM_CONF" \
   && grep -q 'Current=Colloid-dark' "$SDDM_CONF" \
   && grep -q 'CursorTheme=phinger-cursors-light' "$SDDM_CONF" \
   && grep -q 'CursorTheme=phinger-cursors-light' "$SDDM_CONF" && ! grep -qi 'autologin' "$SDDM_CONF"; then
  ok "sddm pins the X11 display server + Colloid theme + phinger cursors, no autologin"
else
  bad "sddm.conf wrong (X11/Colloid/cursors/autologin)"
fi
# the session pin is the DIVERT, not a config key: assert both halves.
if grep -qE '^[[:space:]]*Session=' "$SDDM_CONF"; then
  bad "sddm.conf sets Session= — sddm ignores it for an interactive login; the greeter default comes back"
else
  ok "sddm.conf claims no session default it cannot enforce"
fi
if grep -q 'wayland-sessions/plasma.desktop' "$REPO/desktop/late-command.sh" \
   && grep -q 'dpkg-divert' "$REPO/desktop/late-command.sh"; then
  ok "late.sh diverts the Plasma (Wayland) session away (X11-only greeter)"
else
  bad "late.sh does NOT divert the Wayland session — greeter will offer Plasma (Wayland)"
fi
# ---- the image must speak UTF-8 ----
if grep -q 'locale-gen en_US.UTF-8' "$REPO/desktop/late-command.sh" \
   && grep -q 'update-locale' "$REPO/desktop/late-command.sh" \
   && grep -q 'LANG=en_US.UTF-8' "$REPO/desktop/late-command.sh"; then
  ok "late.sh generates en_US.UTF-8 and makes it the system default"
else
  bad "late.sh does not generate en_US.UTF-8 — Qt will keep falling back to C.UTF-8 and xkbcommon will fail"
fi

LC="$REPO/desktop/late-command.sh"
MKI="$REPO/build/make-install-iso.sh"

# ---- the console font: carried by the BINARIES, never configured ----
# a configured console font can brick the boot: the boot path stays font-FREE so the class is structurally impossible.
LC_CODE="$(grep -vE '^\s*#' "$LC")"
if ! printf '%s' "$LC_CODE" | grep -qE 'fonts-unifont|console-setup|setfont' \
   && ! printf '%s' "$LC_CODE" | grep -q 'initramfs-tools/hooks/console'; then
  ok "boot path configures no console font"
else
  bad "a console font is being configured again"
fi

# the vendored font asset must match its recorded provenance hashes.
FONT_ASSET="$REPO/core/assets/Uni2-Terminus16.psf"
FONT_README="$REPO/desktop/rootfs/usr/share/ombra-assets/README.md"
FONT_GZ_SHA="76b38323e80e09cd44a4ca4b0eaa681101874f208b8b5ba00c8c594cfd3b91c2"
FONT_SHA="002f331400ea0257f894a6b81fafa7a0ab8ba8b816149b81487043dbf2d37e1a"
if [ -f "$FONT_ASSET" ] \
   && [ "$(shasum -a 256 "$FONT_ASSET" | awk '{print $1}')" = "$FONT_SHA" ] \
   && grep -q "$FONT_SHA" "$FONT_README" && grep -q "$FONT_GZ_SHA" "$FONT_README"; then
  ok "boot font asset matches its recorded provenance hash (Terminus 8x16 PSF, console-setup-linux 1.242~deb13u1)"
else
  bad "core/assets/Uni2-Terminus16.psf drifted from the pinned upstream bytes (or its provenance rows are gone)"
fi

# PRESENCE IS NOT FUNCTION: parse the font OUT of the shipped binaries and demand its map covers every boot-TUI glyph.
PSF_CHECK='
import sys
NEED = [0x256D, 0x256E, 0x256F, 0x2570, 0x2500, 0x2502, 0x00B7, 0x2588]
NEED += list(range(0x20, 0x7F))
def parse_font_at(blob, i):
    mode, charsize = blob[i+2], blob[i+3]
    if mode not in (2, 3, 6, 7) or not (0 < charsize <= 32):
        return None
    glyphs = 512 if mode & 1 else 256
    pos = i + 4 + glyphs * charsize
    table = set()
    for _ in range(glyphs):
        while True:
            if pos + 2 > len(blob):
                return None
            v = blob[pos] | (blob[pos+1] << 8)
            pos += 2
            if v == 0xFFFF:
                break
            table.add(v)
    return table
for path in sys.argv[1:]:
    blob = open(path, "rb").read()
    found = None
    i = blob.find(b"\x36\x04")
    while i >= 0 and found is None:
        table = parse_font_at(blob, i)
        if table and all(c in table for c in NEED):
            found = table
        i = blob.find(b"\x36\x04", i + 1)
    if not found:
        print(f"FAIL {path}: no well-formed boot font covering the drawn glyphs")
        sys.exit(1)
    print(f"ok {path}: font map covers all {len(NEED)} required codepoints")
'
if python3 -c "$PSF_CHECK"      "$REPO/desktop/rootfs/usr/local/libexec/ombra/ombra-askpass"      "$REPO/desktop/rootfs/usr/local/libexec/ombra/ombra-welcome"; then
  ok "shipped boot binaries embed a PSF font that translates every glyph they draw"
else
  bad "boot binaries do not carry a covering font — the unlock's rounded corners would draw boxy (or ASCII would break)"
fi

# ---- wallets: Feather (monero) and Electrum (bitcoin) ship; Sparrow does not ----
SPARROW_HITS="$(grep -rl -i 'sparrow' "$T2" 2>/dev/null | head -5)"
if [ -z "$SPARROW_HITS" ] \
   && [ ! -e "$REPO/build/pins/sparrow.txt" ] \
   && ! grep -qi 'stage.*sparrow' "$MKI"; then
  ok "no Sparrow Wallet anywhere in the shipped image, pins or staging"
else
  bad "Sparrow Wallet is still referenced (must not ship): ${SPARROW_HITS:-pin/staging}"
fi
# ---- the pinned upstream apps: pinned, staged, re-verified in the installer, unpacked, launched ----
LC_APPS="$REPO/desktop/late-command.sh"
for app in feather simplex; do
  PIN="$REPO/build/pins/$app.txt"
  if [ -f "$PIN" ] \
     && awk -F= '$1=="sha256"{ok=length($2)==64} END{exit ok?0:1}' "$PIN" \
     && grep -q "stage_pinned $app" "$MKI" || grep -q 'for app in feather simplex' "$MKI"; then
    ok "$app is pinned with a sha256 and staged by the ISO build"
  else
    bad "$app pin or staging is missing"
  fi
done
if grep -q 'verify_staged feather' "$LC_APPS" && grep -q 'verify_staged simplex' "$LC_APPS" \
   && grep -q 'sha256sum "$APP_FILE"' "$LC_APPS" && grep -q '/tmp/ombra-apps-fail' "$LC_APPS" \
   && grep -q 'appimage-extract' "$LC_APPS" && grep -q '/var/tmp/simplex.deb' "$LC_APPS"; then
  ok "Feather and SimpleX are hash re-verified in the installer, installed, and a failure parks the install"
else
  bad "the installer's Feather/SimpleX handling is incomplete"
fi
if [ -x "$REPO/desktop/rootfs/usr/local/bin/feather" ] \
   && grep -qx 'Exec=/usr/local/bin/feather' "$REPO/desktop/rootfs/usr/local/share/applications/feather.desktop" \
   && python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert c['useLocalTor'] is True and c['proxy']==1 and c['socks5Host']=='10.55.10.1' and c['disableWebsocket'] is True and c['torPrivacyLevel']==2 and c['firstRun'] is False" "$REPO/desktop/rootfs/etc/skel/.config/feather/settings.json"; then
  ok "Feather launches through its wrapper and is preset to the gateway's Tor with no bundled Tor and no Feather-server traffic"
else
  bad "Feather wrapper, launcher or preset is wrong"
fi
if grep -q 'kleopatra pinentry-qt scdaemon onionshare electrum' "$LC_APPS" && grep -q 'systemctl mask "$u"' "$LC_APPS" && grep -q 'tor@default.service' "$LC_APPS"; then
  ok "Kleopatra, OnionShare and Electrum install from Debian and the desktop's tor service is masked"
else
  bad "Debian application install or tor masking is missing"
fi

# ---- the Tor Browser must actually be INSTALLED (both halves asserted) ----
LC="$REPO/desktop/late-command.sh"
MKI="$REPO/build/make-install-iso.sh"
if grep -q 'stage_pinned torbrowser' "$MKI" \
   && grep -q 'build/pins/torbrowser.txt' "$MKI" \
   && grep -q 'torbrowser.sha256' "$MKI"; then
  ok "the ISO build stages the sha256-pinned Tor Browser tarball into the initrd"
else
  bad "the ISO build does not stage a hash-verified Tor Browser payload"
fi
if grep -q 'tor-browser-linux-aarch64' "$LC" \
   && grep -q 'torbrowser.sha256' "$LC" \
   && grep -q 'TOR_SKIP_LAUNCH=1' "$LC" \
   && grep -q 'start-tor-browser' "$LC" \
   && grep -q '10.55.10.1' "$LC"; then
  ok "late.sh verifies and installs Tor Browser, wrapped for the gateway's Tor (never its own)"
else
  bad "late.sh does not install+verify Tor Browser, or the wrapper is missing the gateway SOCKS/TOR_SKIP_LAUNCH belt"
fi
if grep -q 'hicolor/48x48/apps/tor-browser.png' "$LC"; then
  ok "late.sh installs a Tor Browser app icon (Icon=tor-browser had no provider)"
else
  bad "late.sh installs no Tor Browser icon — the launcher renders generic"
fi

# ---- the control-port filter: gateway exposes a read-only dialect, the
# desktop's browser talks to it, and ONE shared build cookie binds them ----
G2=$(mktemp -d)
( cd "$G2" && tar -xzf "$TMP/x-gateway/ombra/rootfs.tar.gz" ) >/dev/null 2>&1
SECRET_SRC="$(grep -oE '[0-9a-f]{64}' "$REPO/core/src/torctl.rs" | head -1)"
if [ -x "$G2/usr/local/bin/ombra-torctl-filter" ] \
   && grep -q 'ControlPort 127.0.0.1:9051' "$G2/etc/tor/torrc" \
   && grep -q 'CookieAuthentication 1' "$G2/etc/tor/torrc" \
   && grep -q 'dport 9052' "$G2/etc/nftables.conf" \
   && grep -qF '10\.55\.10\.1:9052' "$G2/usr/local/sbin/ombra-systemcheck" \
   && [ -f "$G2/etc/systemd/system/ombra-torctl-filter.service" ] \
   && grep -q 'enable ombra-torctl-filter.service' "$REPO/gateway/late-command.sh"; then
  ok "gateway ships the control-port filter: loopback control + intnet 9052 + unit enabled"
else
  bad "gateway control-port filter incomplete (binary/torrc/nft/unit/systemcheck)"
fi

# ---- gateway identity layer (mirrors the desktop's) ----
GOSREL="$G2/usr/lib/os-release"
if grep -q '^NAME="Ombra"$' "$GOSREL" && grep -q '^PRETTY_NAME="Ombra"$' "$GOSREL" \
   && grep -q '^ID=ombra$' "$GOSREL" && grep -q '^ID_LIKE=debian$' "$GOSREL"; then
  ok "gateway os-release: bare Ombra identity + ID pair"
else
  bad "gateway os-release identity wrong (NAME/PRETTY_NAME/ID/ID_LIKE)"
fi
if grep -E '^(NAME|PRETTY_NAME)=' "$GOSREL" | grep -q '[0-9]'; then
  bad "gateway os-release human-facing name carries a version"
else
  ok "gateway os-release: no version on human surfaces"
fi
if [ -L "$G2/etc/os-release" ] \
   && [ "$(readlink "$G2/etc/os-release")" = "../usr/lib/os-release" ]; then
  ok "gateway etc/os-release keeps stock symlink semantics"
else
  bad "gateway etc/os-release must be the stock symlink to ../usr/lib/os-release"
fi
if grep -qi debian "$G2/etc/issue" "$G2/etc/issue.net" "$G2/etc/motd" "$G2/etc/lsb-release"; then
  bad "gateway banners still mention Debian"
else
  ok "gateway issue/issue.net/motd/lsb-release carry no Debian strings"
fi
GMOTD="$G2/etc/motd"
if [ "$(wc -l < "$GMOTD" | tr -d ' ')" = "2" ] \
   && grep -q '^O M B R A$' "$GMOTD" \
   && grep -q '^everything it does online passes through tor$' "$GMOTD"; then
  ok "gateway motd: wordmark + tor line, exactly two lines"
else
  bad "gateway motd wrong (wordmark + tor line, nothing else)"
fi
if grep -q '^DISTRIB_ID="Ombra"$' "$G2/etc/lsb-release" \
   && grep -q '^DISTRIB_DESCRIPTION="Ombra"$' "$G2/etc/lsb-release"; then
  ok "gateway lsb-release: Ombra identity"
else
  bad "gateway lsb-release wrong"
fi
if [ -e "$G2/etc/debian_version" ]; then
  bad "gateway overlay ships /etc/debian_version (the divert owns removing the stock one)"
else
  ok "gateway overlay carries no debian_version"
fi
if grep -q '^GRUB_DISTRIBUTOR="Ombra"$' "$G2/etc/default/grub.d/99-ombra-brand.cfg" \
   && [ -f "$G2/etc/default/grub.d/50-ombra.cfg" ] \
   && grep -q 'in-target update-grub' "$REPO/gateway/late-command.sh"; then
  ok "gateway grub: Ombra distributor + hidden-menu drop-ins, update-grub wired"
else
  bad "gateway grub branding drop-ins incomplete or update-grub missing"
fi
GLC="$REPO/gateway/late-command.sh"
GDIVERT="$(grep -n 'dpkg-divert --add --rename --divert /usr/lib/os-release.distrib' "$GLC" | head -1 | cut -d: -f1)"
GUNPACK="$(grep -n 'tar -xzf /ombra/rootfs.tar.gz' "$GLC" | head -1 | cut -d: -f1)"
if [ -n "$GDIVERT" ] && [ -n "$GUNPACK" ] && [ "$GDIVERT" -lt "$GUNPACK" ]; then
  ok "gateway late.sh: os-release divert precedes the overlay unpack (base-files can never re-Debian)"
else
  bad "gateway os-release divert missing or ordered after the unpack (--rename would grab our file)"
fi
if grep -q '6f6d6272610000000000000000000002' "$REPO/gateway/late-command.sh"; then
  ok "gateway ships the fixed machine-id (anonymity-set parity with the desktop)"
else
  bad "gateway machine-id not pinned in late-command"
fi
if grep -q 'iifname "ombra-upstream" udp sport 67 udp dport 68' "$G2/etc/nftables.conf" \
   && grep -q 'oifname "ombra-upstream" udp sport 68 udp dport 67' "$G2/etc/nftables.conf"; then
  ok "gateway upstream DHCP client path is explicit (the lease cannot depend on a bypass)"
else
  bad "gateway upstream DHCP rules missing from the shipped ruleset"
fi
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=0 slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on debugfs=off ipv6.disable=1"$' \
     "$G2/etc/default/grub.d/50-ombra.cfg"; then
  ok "gateway kernel cmdline hardened (desktop parity)"
else
  bad "gateway grub drop-in missing the hardening cmdline"
fi
if grep -qE 's\^GRUB_CMDLINE_LINUX_DEFAULT' "$REPO/gateway/late-command.sh"; then
  bad "gateway late.sh still seds the cmdline (the drop-in must own it)"
else
  ok "gateway late.sh leaves the cmdline to the drop-in"
fi
if [ -x "$G2/usr/local/sbin/ombra-leak-probe" ] \
   && grep -q 'NOPASSWD: /usr/local/sbin/ombra-leak-probe' "$G2/etc/sudoers.d/ombra-leak-probe"; then
  ok "gateway ships the leak probe + its narrow NOPASSWD grant"
else
  bad "leak probe or its sudoers grant missing from the gateway overlay"
fi
COOKIE_RAW="$(python3 - "$REPO/desktop/late-command.sh" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
i = s.index("printf '\\141")
j = s.index("'", i + 8)
b = bytes(int(x, 8) for x in re.findall(r'\\(\d{3})', s[i + 8:j]))
print(b.hex() if len(b) == 32 else "")
PYEOF
)"
if [ -n "$SECRET_SRC" ] && [ "$COOKIE_RAW" = "$SECRET_SRC" ] \
   && grep -q 'export TOR_CONTROL_HOST=10.55.10.1' "$REPO/desktop/late-command.sh" \
   && grep -q 'export TOR_CONTROL_PORT=9052' "$REPO/desktop/late-command.sh" \
   && grep -q 'intl.language_notification.shown' "$REPO/desktop/late-command.sh"; then
  ok "desktop browser seeds point at the filter with the pinned shared cookie; language nag pre-shown"
else
  bad "desktop control-port seeds missing or the shared cookie drifted from core/src/torctl.rs"
fi
# the unpack must use /target's GNU tar (in-target): the d-i env's tar may be BusyBox and rejects -J/--strip-components.
if grep -vE '^\s*#' "$LC" | grep -q 'in-target tar -xJf /var/tmp/ombra-tbb.tar.xz'; then
  ok "Tor Browser unpacks via /target's GNU tar (d-i's BusyBox tar cannot)"
else
  bad "Tor Browser unpack runs in the d-i env — BusyBox tar there rejects the flags"
fi
# every failure path of the unpack must write the flag (the only
# masked-reason path shipped a generic message instead of the cause).
if grep -vE '^\s*#' "$LC" | grep -q 'ombra-tbb: tarball would not unpack'; then
  ok "a failed unpack writes the tbb-fail flag (the park names the real reason)"
else
  bad "unpack failure writes no flag — the park reason gets masked again"
fi
# the UTF-8 locale line must land in /etc/locale.gen even when the image lacks it (host-side append);
# without it locale-gen only makes ISO-8859-1 and update-locale refuses.
if grep -vE '^\s*#' "$LC" | grep -q "en_US.UTF-8 UTF-8\\\\n' >> /target/etc/locale.gen"; then
  ok "late.sh guarantees the en_US.UTF-8 line in locale.gen (host-side append)"
else
  bad "locale.gen bootstrap missing — LANG can silently stay ISO-8859-1"
fi
# a missing browser must ABORT: the failure flag is written inside the
# set +e subshell and re-raised outside it (ombra_fatal parks).
TBB_OUTER="$(awk '
  /^\) \|\| echo "WARN\(non-critical/ { after=1; next }
  after { print }
' "$LC")"
if [ -n "$(printf '%s' "$TBB_OUTER" | grep -o 'ombra-tbb-fail')" ] \
   && printf '%s' "$TBB_OUTER" | grep -qE '^\s*ombra_fatal '; then
  ok "a failed Tor Browser install parks the install (flag re-raised outside the set +e subshell)"
else
  bad "Tor Browser failure only warns — a Tor OS could ship with no browser"
fi
if grep -qE '^[[:space:]]*echo ".*" > /tmp/ombra-tbb-fail$' "$LC"; then
  ok "late.sh writes the ombra-tbb-fail flag when the browser will not install"
else
  bad "late.sh detects a Tor Browser install failure but records no flag for the outer abort"
fi
if grep -qE '^if \[ ! -x /target/usr/local/bin/tor-browser \]' "$LC"; then
  ok "late.sh hard-asserts the Tor Browser wrapper + payload exist on the target"
else
  bad "late.sh never asserts Tor Browser is actually installed on the target"
fi

# the user face: the Ombra ring, greeter + skel, byte-identical, real PNG.
FACE_SYS="$T2/usr/share/sddm/faces/ombra.face.icon"
FACE_SKEL="$T2/etc/skel/.face.icon"
if [ -s "$FACE_SYS" ] && [ -s "$FACE_SKEL" ] \
   && cmp -s "$FACE_SYS" "$FACE_SKEL" \
   && [ "$(dd if="$FACE_SYS" bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
  ok "greeter + skel ship the same Ombra-ring face (valid PNG, non-empty)"
else
  bad "the user face (ombra.face.icon / skel .face.icon) is missing, empty, not PNG, or they differ"
fi
LAYOUT="$T2/usr/share/plasma/look-and-feel/com.github.vinceliuice.Colloid-dark/contents/layouts/org.kde.plasma.desktop-layout.js"
# comments stripped so the header's mention of the bad id cannot read
# as the file using it; the private.systemtray id must be ABSENT
LAYOUT_CODE="$(grep -vE '^\s*//' "$LAYOUT")"
if grep -q 'bar.location = "top"' "$LAYOUT" && grep -q 'dock.location = "bottom"' "$LAYOUT" \
   && grep -q 'dock.floating = true' "$LAYOUT" \
   && grep -q 'org.kde.plasma.kickoff' "$LAYOUT" && grep -q 'org.kde.plasma.icontasks' "$LAYOUT" \
   && grep -q 'addWidget("org.kde.plasma.systemtray")' "$LAYOUT" \
   && grep -q 'org.kde.plasma.digitalclock' "$LAYOUT" \
   && ! printf '%s' "$LAYOUT_CODE" | grep -q 'private.systemtray' \
   && grep -q 'ombra-02-4k.png' "$LAYOUT" \
   && ! grep -vE '^\s*(//|/\*|\*)' "$LAYOUT" | grep -qiE 'weather|crypto|stock'; then
  ok "default layout: top info bar (LED/tray/clock) + floating bottom dock (kickoff/icontasks), ombra wallpaper"
else
  bad "default layout script incomplete, wrong, or pins the crashing org.kde.plasma.private.systemtray"
fi

# pinned launcher ids must resolve to a real desktop file or icontasks renders a grey "?" icon;
# the launchers value must be a JS ARRAY (a comma-joined string reaches icontasks as one merged id).
PINNED_IDS="$(printf '%s' "$LAYOUT_CODE" | grep -oE 'applications:[A-Za-z0-9._-]+\.desktop' | sed -e 's/^applications://' -e 's/\.desktop$//' | sort -u)"
if [ -n "$PINNED_IDS" ] && printf '%s' "$LAYOUT_CODE" | grep -q 'writeConfig("launchers", \['; then
  missing=""
  # shellcheck disable=SC2086
  for id in $PINNED_IDS; do
    if [ -f "$T2/usr/share/applications/$id.desktop" ] \
       || [ -f "$T2/usr/local/share/applications/$id.desktop" ]; then
      continue                                    # overlay-provided
    fi
    case "$id" in
      org.kde.dolphin)         pkg=dolphin ;;
      kitty)                  pkg=kitty ;;
      org.keepassxc.KeePassXC) pkg=keepassxc ;;
      systemsettings)         pkg=systemsettings ;;
      *)                      pkg="" ;;
    esac
    if [ -n "$pkg" ] && { grep -qE "(^|[[:space:]])$pkg([[:space:]]| \\\\)" "$REPO/desktop/late-command.sh" \
                       || grep -qE "(^|[[:space:]])$pkg([[:space:]]|$)" "$REPO/desktop/preseed.cfg"; }; then
      continue                                    # installed at install time
    fi
    missing="$missing $id"
  done
  if [ -z "$missing" ]; then
    ok "every pinned dock launcher resolves to a real desktop file (array-form launchers)"
  else
    bad "dock pins launcher ids with no .desktop -> grey \"?\" icons:$missing"
  fi
else
  bad "default layout does not pin icontasks launchers as a JS array"
fi

# panel .opacity assignments are forbidden: 6.3.6's scripting setter composites the panel window
# at 0% (invisible top bar); adaptive is the default anyway
if printf '%s' "$LAYOUT_CODE" | grep -qE '\.opacity[[:space:]]*='; then
  bad "layout script assigns .opacity (6.3.6 setter bug composites the panel at 0%)"
else
  ok "layout script sets no panel opacity (6.3.6 setOpacity enum bug kept out)"
fi

# ---- the Tor-status plasmoid ----
PLSMETA="$T2/usr/share/plasma/plasmoids/org.ombra.status/metadata.json"
PLSQML="$T2/usr/share/plasma/plasmoids/org.ombra.status/contents/ui/main.qml"
PLSCFG="$T2/usr/share/plasma/plasmoids/org.ombra.status/contents/config/main.xml"
if grep -q 'addWidget("org.ombra.status")' "$LAYOUT"; then
  ok "default layout wires the org.ombra.status LED (top bar)"
else
  bad "default layout does not addWidget org.ombra.status"
fi
# plasma 6.3's deferred preload silently skips applets whose KConfigXT
# schema is absent — no log, no error, no LED. This file must ship.
if [ -e "$PLSCFG" ] && grep -q '<kcfgfile name=""/>' "$PLSCFG"; then
  ok "plasmoid ships the KConfigXT schema (plasma 6.3 skips the QML load without it)"
else
  bad "plasmoid missing contents/config/main.xml — plasma 6.3 silently drops the QML load, the LED never renders"
fi

# panel restore never instantiates this applet's QML even with the schema present;
# the session-start ensurer re-adds it through the live path, which always loads
ENSURE="$T2/usr/local/bin/ombra-led-ensure"
ENSDSK="$T2/etc/skel/.config/autostart/org.ombra.status-ensure.desktop"
if [ -x "$ENSURE" ] \
   && grep -q 'addWidget("org.ombra.status")' "$ENSURE" \
   && grep -q 'AppletOrder' "$ENSURE"; then
  ok "session-start ensurer re-adds the LED live and orders it first"
else
  bad "ombra-led-ensure missing/broken — the LED dies at every panel restore"
fi
if grep -q 'Exec=/usr/local/bin/ombra-led-ensure' "$ENSDSK"; then
  ok "ensurer autostarts with the session"
else
  bad "ensurer autostart entry missing — nothing runs it at login"
fi
if python3 - "$PLSMETA" <<'PYEOF' 2>/dev/null; then
import json, sys
meta = json.load(open(sys.argv[1]))
assert meta.get("KPackageStructure") == "Plasma/Applet", meta.get("KPackageStructure")
assert meta["KPlugin"]["Id"] == "org.ombra.status", meta["KPlugin"].get("Id")
assert meta["KPlugin"]["Name"] == "Ombra Tor Status"
assert meta.get("X-Plasma-API-Minimum-Version", "6.0") >= "6.0"
PYEOF
  ok "plasmoid metadata: Plasma 6 Applet package, KPlugin id org.ombra.status"
else
  bad "plasmoid metadata.json missing/wrong (KPackageStructure or KPlugin Id)"
fi
# comments stripped: assigning a non-existent Plasma 6 property is a
# load-time QML error — the LED would never render
PLSQML_CODE="$(grep -vE '^\s*//' "$PLSQML")"
if ! printf '%s' "$PLSQML_CODE" | grep -qE '^[[:space:]]*(hasConfigurationInterface|plasmoidComponent)[[:space:]]*:'; then
  ok "plasmoid assigns no non-existent Plasma 6 properties (the LED loads)"
else
  bad "plasmoid assigns hasConfigurationInterface/plasmoidComponent — a Plasma 6 load error, the LED will not render"
fi

# font.pixelSize is -1 for point-size fonts (the shipped font is one): a dot sized from it renders invisible;
# size from FontMetrics.height with a floor instead
if printf '%s' "$PLSQML_CODE" | grep -q 'font\.pixelSize'; then
  bad "plasmoid sizes from font.pixelSize (-1 on point fonts) — the LED renders invisible"
else
  ok "plasmoid sizes the LED without font.pixelSize (invisible-dot regression kept out)"
fi

MAPPING_OK=1
for pair in 'ok:#56d68a' 'semi:#f2c260' 'fail:#f0716b' 'unknown:#8b8d93'; do
  st="${pair%%:*}"; col="${pair##*:}"
  grep -Eq "\"$st\"[[:space:]]*:[[:space:]]*\"$col\"" "$PLSQML" || MAPPING_OK=0
done
if [ "$MAPPING_OK" = 1 ]; then
  ok "plasmoid maps ok/semi/fail/unknown to the pinned green/yellow/red/grey"
else
  bad "plasmoid state->color mapping incomplete (all four states must map)"
fi
if grep -q 'Ombra: status daemon not answering' "$PLSQML"; then
  ok "plasmoid fail-soft: grey + status-daemon-not-answering fallback"
else
  bad "plasmoid fail-soft tooltip missing"
fi

# clicking the LED opens the connectivity detail — a fullRepresentation
# is what makes the panel wire that click
if grep -q 'fullRepresentation: Component' "$PLSQML"; then
  ok "plasmoid carries the click-to-detail fullRepresentation"
else
  bad "plasmoid has no fullRepresentation — clicking the LED does nothing"
fi
# the widget polls the SAME pinned daemon binary via --once
UNIT_SOCK="$T2/etc/skel/.config/systemd/user/ombra-statusd.service"
DAEMON_BIN="$(sed -n 's/^ExecStart=//p' "$UNIT_SOCK" | head -1)"
# match the BINARY path, not the whole command line
if [ -n "$DAEMON_BIN" ] && grep -q "statusCommand: .*$DAEMON_BIN --once" "$PLSQML" \
   && grep -q 'OMBRA_STATUS_FORCE_CACHE=1' "$PLSQML"; then
  ok "plasmoid polls the unit's own daemon binary via --once ($DAEMON_BIN)"
else
  bad "plasmoid daemon path drifts from ombra-statusd.service ExecStart"
fi
if grep -q 'Indexing-Enabled=false' "$T2/etc/skel/.config/baloofilerc" \
   && grep -q 'StatisticsCollectionMode=NoStatistics' "$T2/etc/skel/.local/state/UserFeedback.org.kde.plasmashell" \
   && grep -q 'LookAndFeelPackage=com.github.vinceliuice.Colloid-dark' "$T2/etc/skel/.config/kdedefaults/kdeglobals" \
   && grep -q 'widgetStyle=kvantum-dark' "$T2/etc/skel/.config/kdedefaults/kdeglobals" \
   && grep -q 'Theme=Kaze-dark' "$T2/etc/skel/.config/kdedefaults/kdeglobals" \
   && grep -q '^font=Noto Sans,10,' "$T2/etc/skel/.config/kdedefaults/kdeglobals" \
   && grep -q 'cursorTheme=phinger-cursors-light' "$T2/etc/skel/.config/kdedefaults/kcminputrc" \
   && ! grep -q 'ScaleFactor' "$T2/etc/skel/.config/kdedefaults/kdeglobals"; then
  ok "skel privacy + theme defaults complete (baloo/feedback/L&F/kvantum/icons/font, no scale keys)"
else
  bad "skel privacy or theme defaults incomplete"
fi
if ! grep -q 'OMBRA_GREETED' "$T2/etc/zsh/zshrc" \
   && grep -q 'manual command' "$T2/etc/zsh/zshrc"; then
  ok "zsh greeter retired: the connectivity panel is a manual command only"
else
  bad "the zsh auto-greet still ships (kitty's systemd app units bypassed its once-guard anyway)"
fi
# icons are the vendored Kaze-dark theme (GPL-3.0, pinned in build/pins/kaze.txt);
# Kaze inherits breeze/gnome/hicolor, all already on a Plasma desktop
if ! grep -qE 'papirus-icon-theme' "$REPO/desktop/preseed.cfg" \
   && [ -e "$T2/usr/share/icons/Kaze-dark/index.theme" ] \
   && [ -e "$T2/usr/share/ombra-assets/Kaze-GPL-3.0" ] \
   && [ ! -e "$T2/usr/share/icons/Tela-circle-dracula" ] \
   && [ ! -e "$T2/usr/share/icons/Tela-circle-dracula-dark" ]; then
  ok "icon theme: vendored Kaze-dark (papirus gone, no Tela tree)"
else
  bad "icon theme drift (papirus still in pkgsel, or Kaze/license missing, or Tela vendored tree back)"
fi
OVR="$T2/usr/local/share/applications"
if grep -q 'Icon=utilities-terminal' "$OVR/kitty.desktop" \
   && grep -q 'StartupWMClass=Tor Browser Alpha' "$OVR/tor-browser.desktop" \
   && grep -q 'Icon=/usr/share/icons/hicolor/48x48/apps/tor-browser.png' "$OVR/tor-browser.desktop" \
   && ! grep -q 'Ombra build' "$OVR/tor-browser.desktop"; then
  ok "launcher overrides: terminal icon, real onion + plain comment + WM_CLASS pin"
else
  bad "launcher overrides drifted (kitty icon, tor-browser comment/icon/StartupWMClass)"
fi
for f in ./etc/lightdm ./etc/systemd/system/lightdm.service.d ./etc/skel/.config/hypr \
         ./etc/skel/.config/waybar ./etc/skel/.config/fuzzel ./etc/skel/.config/mako \
         ./etc/skel/.config/foot ./etc/dconf ./usr/share/gnome-shell \
         ./usr/share/icons/Colloid-dark-cursors ; do
  if [ -e "$T2/$f" ]; then bad "stale session-era overlay still ships $f"; else ok "overlay: $f removed"; fi
done

# ---- Ombra identity layer ----
OSREL="$T2/usr/lib/os-release"
if grep -q '^NAME="Ombra"$' "$OSREL" && grep -q '^PRETTY_NAME="Ombra"$' "$OSREL"; then
  ok "os-release: NAME + PRETTY_NAME are bare Ombra"
else
  bad "os-release NAME/PRETTY_NAME wrong (must be Ombra, no version)"
fi
if grep -E '^(NAME|PRETTY_NAME)=' "$OSREL" | grep -q '[0-9]'; then
  bad "os-release human-facing name carries a version"
else
  ok "os-release: no version on human surfaces"
fi
if grep -q '^VERSION_CODENAME=trixie$' "$OSREL" && grep -q '^DEBIAN_VERSION_FULL=13.7$' "$OSREL"; then
  ok "os-release: trixie codename + machine-facing compat kept (apt stays whole)"
else
  bad "os-release: codename/compat fields missing (would break apt tooling)"
fi
if grep -q '^ID=ombra$' "$OSREL" && grep -q '^ID_LIKE=debian$' "$OSREL"; then
  ok "os-release: ID=ombra + ID_LIKE=debian"
else
  bad "os-release ID pair wrong (ombra + ID_LIKE=debian expected)"
fi
if grep -qE '^(HOME_URL|SUPPORT_URL|BUG_REPORT_URL)=' "$OSREL"; then
  bad "os-release ships external Debian URLs (privacy box points at nothing)"
else
  ok "os-release: no external URLs"
fi
if [ -L "$T2/etc/os-release" ] && [ "$(readlink "$T2/etc/os-release")" = "../usr/lib/os-release" ]; then
  ok "etc/os-release keeps stock symlink semantics (../usr/lib/os-release)"
else
  bad "etc/os-release must be the stock symlink to ../usr/lib/os-release"
fi
if grep -q '^Ombra \\n \\l$' "$T2/etc/issue" && ! grep -qi debian "$T2/etc/issue"; then
  ok "issue: Ombra pre-login line"
else
  bad "issue wrong (Ombra \\n \\l expected, no Debian)"
fi
if [ "$(cat "$T2/etc/issue.net")" = "Ombra" ]; then
  ok "issue.net: bare Ombra (no version, no kernel)"
else
  bad "issue.net must be exactly 'Ombra' (pre-auth banner says nothing)"
fi
MOTD="$T2/etc/motd"
if [ "$(wc -l < "$MOTD" | tr -d ' ')" = "2" ] \
   && grep -q '^O M B R A$' "$MOTD" \
   && grep -q '^everything it does online passes through tor$' "$MOTD" \
   && ! grep -qi debian "$MOTD"; then
  ok "motd: wordmark + tor line, exactly two lines, static"
else
  bad "motd wrong (wordmark + 'everything it does online passes through tor', nothing else)"
fi
if [ -e "$T2/etc/update-motd.d/README" ] && ! find "$T2/etc/update-motd.d" -type f -perm -u+x | grep -q .; then
  ok "update-motd.d: script-free (non-executable README only) — motd stays static"
else
  bad "update-motd.d must ship no executable scripts"
fi
if grep -q '^DISTRIB_ID="Ombra"$' "$T2/etc/lsb-release" \
   && grep -q '^DISTRIB_DESCRIPTION="Ombra"$' "$T2/etc/lsb-release" \
   && grep -q '^DISTRIB_CODENAME=trixie$' "$T2/etc/lsb-release"; then
  ok "lsb-release: Ombra identity, trixie codename kept"
else
  bad "lsb-release wrong"
fi
if grep -q 'dpkg-divert --local --add --rename --divert /etc/debian_version.distrib' "$LC" \
   && [ ! -e "$T2/etc/debian_version" ]; then
  ok "late.sh diverts + removes /etc/debian_version; overlay carries none"
else
  bad "debian_version divert missing or the overlay ships one"
fi
if [ "$(grep -c 'string \*' "$REPO/desktop/preseed.cfg")" -ge 2 ]; then
  ok "accounts born locked (root + user): no public login credential pre-rotation"
else
  bad "preseed still carries a usable login credential"
fi
if [ -f "$T2/etc/systemd/journald.conf.d/10-ombra-volatile.conf" ] \
   && grep -q 'Storage=volatile' "$T2/etc/systemd/journald.conf.d/10-ombra-volatile.conf"; then
  ok "desktop journal is volatile (no usage timing on the LUKS disk)"
else
  bad "desktop journald volatile drop-in missing"
fi
if grep -q '^Timeout=10$' "$T2/etc/skel/.config/kscreenlockerrc" \
   && grep -q '^LockOnResume=true$' "$T2/etc/skel/.config/kscreenlockerrc"; then
  ok "screen lock pinned (10-minute idle, lock on resume)"
else
  bad "screen-lock policy keys missing from kscreenlockerrc"
fi
if grep -q -- '--pbkdf-memory' "$REPO/core/src/welcome.rs" \
   && grep -q '"1048576"' "$REPO/core/src/welcome.rs"; then
  ok "LUKS rotation pins 1 GiB argon2id memory"
else
  bad "welcome.rs PBKDF memory is not 1 GiB"
fi
if grep -q 'release scrub' "$LC" \
   && grep -q 'release scrub' "$REPO/gateway/late-command.sh" \
   && grep -qF 'find /var/log -type f -exec truncate -s 0' "$LC" \
   && grep -qF 'find /var/log -type f -exec truncate -s 0' "$REPO/gateway/late-command.sh"; then
  ok "release scrub ships on both targets (no build residue on distributed disks)"
else
  bad "release scrub missing from a late-command — distributed disks would carry install residue"
fi

# ---- fastfetch (the branded panel) ------------------------------------------
FF="$T2/etc/skel/.config/fastfetch"
if [ -f "$FF/config.jsonc" ] && [ -f "$FF/ring.ans" ]; then
  ok "fastfetch: skel config + ring logo ship"
else
  bad "fastfetch skel (config.jsonc / ring.ans) missing"
fi
if grep -q '"format": "ombra"' "$FF/config.jsonc" \
   && grep -qF 'ring.ans' "$FF/config.jsonc" \
   && grep -q 'ombra-statusd --once' "$FF/config.jsonc"; then
  ok "fastfetch: ombra title, ring logo file, statusd tor-verdict module"
else
  bad "fastfetch config lacks title/ring.ans/statusd module"
fi
# ring.ans must equal core/src/art.rs RING_ART verbatim (escapes
# stripped) with the theme.rs two-tone pair (81 / 73).
awk '/RING_ART: &str = r"/ { sub(/.*r"/, ""); ship=1 }
     ship { if (sub(/";$/, "")) ship=0; print }' "$REPO/core/src/art.rs" > "$TMP/ring-art.txt"
sed $'s/\x1b\\[[0-9;]*m//g' "$FF/ring.ans" > "$TMP/ring-plain.txt"
if cmp -s "$TMP/ring-art.txt" "$TMP/ring-plain.txt"; then
  ok "ring.ans: escape-stripped bytes equal core/src/art.rs RING_ART verbatim"
else
  bad "ring.ans drifted from RING_ART (the official art is the only logo)"
fi
if grep -qF $'\e[38;5;189m' "$FF/ring.ans" && grep -qF $'\e[38;5;103m' "$FF/ring.ans" \
   && ! grep -qF $'\e[38;5;135m' "$FF/ring.ans"; then
  ok "ring.ans: two-tone lavender (189 ring, 103 edge), no gradient"
else
  bad "ring.ans must stay two-tone lavender (189/103)"
fi

# ---- late-command branding wiring (order is load-bearing) ----
LC="$REPO/desktop/late-command.sh"
DIVERT=$(grep -n 'dpkg-divert --add --rename --divert /usr/lib/os-release.distrib' "$LC" | cut -d: -f1)
RMMOTD=$(grep -n 'rm -f /target/etc/update-motd.d/\*' "$LC" | cut -d: -f1)
TARLINE=$(grep -n 'tar -xzf /ombra/rootfs.tar.gz' "$LC" | cut -d: -f1)
if [ -n "$DIVERT" ] && [ -n "$TARLINE" ] && [ "$DIVERT" -lt "$TARLINE" ]; then
  ok "late.sh: os-release dpkg-divert precedes the overlay unpack (base-files can never re-Debian)"
else
  bad "late.sh: os-release divert missing or ordered after the unpack (--rename would grab our file)"
fi
if [ -n "$RMMOTD" ] && [ -n "$TARLINE" ] && [ "$RMMOTD" -lt "$TARLINE" ]; then
  ok "late.sh: update-motd.d scripts removed before the unpack (overlay README survives)"
else
  bad "late.sh: motd script cleanup missing or ordered after the unpack"
fi
if grep -q 'breeze-gtk-theme libpam-systemd fastfetch' "$LC"; then
  ok "late.sh: fastfetch in the session transaction (trixie main, packaged)"
else
  bad "late.sh: fastfetch missing from the session transaction"
fi

# ---- hardening: cryptswap, telemetry, kernel, local firewall ----
LC_CODE="$(grep -vE '^\s*#' "$LC")"
# d-i's fstab aligns columns: the swap delete must match FIELD 3, and a
# plain swap line surviving the conversion is FATAL, never silent
if printf '%s' "$LC_CODE" | grep -qF '$3=="swap" {next}' \
   && printf '%s' "$LC_CODE" | grep -qF 'swap line survived the cryptswap conversion' \
   && ! printf '%s' "$LC_CODE" | grep -qF 'swap[[:space:]]'; then
  ok "cryptswap: fstab swap deletion is field-matched; a surviving plain swap is FATAL"
else
  bad "cryptswap delete not field-matched/FATAL — d-i's column-aligned swap line can silently survive again"
fi
# the usage recorder: plasmashell 6.3 aborts its shell load when kactivitymanagerd is masked, so the daemon
# runs — but its sqlite database lives on a boot-wiped tmpfs; nothing about usage persists
if printf '%s' "$LC_CODE" | grep -qF '/dev/null /target/etc/systemd/user/plasma-kactivitymanagerd.service'; then
  bad "kactivitymanagerd user-unit mask present — plasmashell aborts its shell load on it (black screen)"
elif grep -qF 'kact-wipe.service' "$REPO/desktop/late-command.sh" \
   && [ -f "$REPO/desktop/rootfs/etc/systemd/system/kact-wipe.service" ] \
   && [ -f "$REPO/desktop/rootfs/etc/systemd/system/home-ombra-.local-share-kactivitymanagerd-resources.mount" ]; then
  ok "kactivitymanagerd: daemon runs, recording database on boot-wiped tmpfs (volatile units shipped + enabled)"
else
  bad "kactivities volatile-database units missing — recording would persist to disk again"
fi
# kact-wipe sits before a /home mount: with default dependencies it joins basic.target and closes an ordering cycle that makes systemd delete local-fs.target's start job
if grep -qx 'DefaultDependencies=no' "$REPO/desktop/rootfs/etc/systemd/system/kact-wipe.service" \
   && grep -qx 'After=home.mount systemd-remount-fs.service' "$REPO/desktop/rootfs/etc/systemd/system/kact-wipe.service"; then
  ok "kact-wipe has no default dependencies (no sysinit ordering cycle at boot)"
else
  bad "kact-wipe.service pulls default dependencies — boot ordering cycle through local-fs.target"
fi
# the session GL provider: the session env must not pin LIBGL_ALWAYS_SOFTWARE — the kwin compositor runs on hardware GL
GL_HOOK="$REPO/desktop/rootfs/etc/skel/.config/plasma-workspace/env/zz-software-gl.sh"
if [ -f "$GL_HOOK" ] || grep -rqF 'LIBGL_ALWAYS_SOFTWARE' "$REPO/desktop/rootfs/etc/skel/" 2>/dev/null; then
  bad "forced software-GL hook present — removed with the glass; do not re-add session-wide"
else
  ok "no forced software GL in the session environment"
fi
# glass: kwin blur + translucency on via the kdedefaults layer, Kvantum and the plasma theme
# request blur; panel .opacity stays unassigned (separate guard above)
KWR="$REPO/desktop/rootfs/etc/skel/.config/kdedefaults/kwinrc"
KVC="$REPO/desktop/rootfs/usr/share/Kvantum/ColloidDark/ColloidDark.kvconfig"
PTM="$REPO/desktop/rootfs/usr/share/plasma/desktoptheme/Colloid-dark/metadata.desktop"
if grep -q '^blurEnabled=true' "$KWR" && grep -q '^translucencyEnabled=true' "$KWR" \
   && grep -q '^\[Effect-blur\]' "$KWR" && grep -q '^\[Effect-translucency\]' "$KWR" \
   && grep -q '^translucent_windows=true' "$KVC" && grep -q '^blurring=true' "$KVC" \
   && grep -q '^popup_blurring=true' "$KVC" \
   && sed -n '/^\[ContrastEffect\]/,/^$/p' "$PTM" | grep -q '^enabled=true'; then
  ok "glass: kwin blur+translucency, Kvantum translucent/blurring, plasma contrast effect all on"
else
  bad "glass config incomplete (kwinrc blur/translucency, Kvantum blurring, or theme ContrastEffect)"
fi
STAR="$REPO/desktop/rootfs/etc/skel/.config/starship.toml"
if [ -s "$STAR" ] && grep -q '^format' "$STAR" && grep -q 'ZSH_HIGHLIGHT_STYLES\[command\]' "$REPO/desktop/rootfs/etc/skel/.zshrc"; then
  ok "starship prompt + zsh-syntax-highlighting palette ship in skel"
else
  bad "starship.toml or zsh highlight palette missing from skel"
fi
# drkonqi: NEVER purged — plasma-workspace hard-depends on it (the purge cascade removes the desktop);
# every unit it owns is masked instead
if printf '%s' "$LC_CODE" | grep -qF 'purge -y drkonqi'; then
  bad "drkonqi purge present — the cascade removes plasma-workspace"
elif printf '%s' "$LC_CODE" | grep -qF 'drkonqi-sentry-postman.timer' \
   && printf '%s' "$LC_CODE" | grep -qF 'drkonqi-coredump-launcher@.service'; then
  ok "drkonqi: purge gone, sentry/coredump units masked unconditionally"
else
  bad "drkonqi mask belt missing — the hourly Sentry timer would ship enabled"
fi
# scheduled apt runs are Tor traffic on an idle appliance
if printf '%s' "$LC_CODE" | grep -qF 'apt-daily.timer' \
   && printf '%s' "$LC_CODE" | grep -qF 'apt-daily-upgrade.service'; then
  ok "apt-daily timers + services masked at install"
else
  bad "apt-daily masks missing — updates would call out on a schedule"
fi
# GHNS is a remote fetch-and-parse surface; the directory must not ship
if printf '%s' "$LC_CODE" | grep -qF 'rm -rf /target/usr/share/knsrcfiles'; then
  ok "late.sh removes /usr/share/knsrcfiles (GHNS dead)"
else
  bad "knsrcfiles removal missing from late.sh — remote fetch-and-parse configs would ship"
fi
# telemetry OFF at every path kuserfeedback actually reads: the
# system-wide default under /etc/xdg, plus pre-neutered per-app files
UF_OK=1
for f in "$T2/etc/xdg/KDE/UserFeedback.conf" \
         "$T2/etc/skel/.local/state/UserFeedback.org.kde.plasmashell" \
         "$T2/etc/skel/.config/kde.org/UserFeedback.org.kde.dolphin.conf" \
         "$T2/etc/skel/.config/kde.org/UserFeedback.org.kde.plasmashell.conf"; do
  grep -q 'StatisticsCollectionMode=NoStatistics' "$f" && grep -q 'SurveyInterval=-1' "$f" || UF_OK=0
done
if [ "$UF_OK" = 1 ]; then
  ok "user feedback OFF: system-wide default + neutered per-app skel (plasmashell/dolphin)"
else
  bad "user feedback files incomplete (global /etc/xdg default or per-app skel missing)"
fi
# the grub.d snippet carries the hardening set MINUS init_on_free (its timing perturbation rides a marginal
# vmwgfx display race); the base line rides in late.sh's sed of /etc/default/grub.
GRUB_SNIP="$T2/etc/default/grub.d/50-ombra.cfg"
GRUB_BASE_LINE='GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=0 slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on debugfs=off"'
if grep -qF "$GRUB_BASE_LINE" "$GRUB_SNIP" \
   && ! grep -vE '^\s*#' "$GRUB_SNIP" | grep -qF 'init_on_free'; then
  ok "kernel cmdline: base + hardening set, init_on_free excluded (display race)"
else
  bad "kernel cmdline drifted: want base + five hardening flags, never init_on_free"
fi
# sysctl top-ups, asserted on the shipped file (keys AND values)
SYS_OK=1
for kv in 'vm.mmap_min_addr = 65536' 'kernel.core_pattern = |/bin/false' 'fs.suid_dumpable = 0' \
          'net.ipv4.conf.all.arp_ignore = 2' 'net.ipv4.conf.all.shared_media = 0' \
          'net.ipv4.tcp_timestamps = 0' 'net.ipv4.icmp_echo_ignore_all = 1'; do
  grep -qF "$kv" "$T2/etc/sysctl.d/60-ombra-desktop.conf" || SYS_OK=0
done
# the panic-on-oops posture must never return: kernel defaults survive the oops and journal it
if grep -vE '^\s*#' "$T2/etc/sysctl.d/60-ombra-desktop.conf" | grep -qE 'oops_limit|kernel\.panic'; then
  SYS_OK=0
fi
if [ "$SYS_OK" = 1 ]; then
  ok "sysctl hardening complete (mmap_min_addr/core dumps/panic limits/ARP/timestamps/no ping)"
else
  bad "sysctl hardening set incomplete in 60-ombra-desktop.conf"
fi
# the desktop's own default-drop firewall: ruleset ships, unit enabled,
# package present in pkgsel
NFT_OK=1
for want in 'type filter hook input priority filter; policy drop;' \
            'type filter hook output priority filter; policy drop;' \
            'type filter hook forward priority filter; policy drop;' \
            'ip daddr 10.55.10.1 counter accept'; do
  grep -qF "$want" "$T2/etc/nftables.conf" || NFT_OK=0
done
grep -q 'ip saddr 10.55.10.1 ip protocol icmp icmp type echo-request' "$T2/etc/nftables.conf" || NFT_OK=0
! grep -qE '^[^#]*10\.55\.10\.0/24' "$T2/etc/nftables.conf" || NFT_OK=0
grep -q 'enable nftables.service' "$LC" || NFT_OK=0
echo "$PKGSEL" | grep -qw nftables || NFT_OK=0
if [ "$NFT_OK" = 1 ]; then
  ok "local firewall: default-drop ruleset ships, unit enabled, nftables in pkgsel"
else
  bad "desktop nftables incomplete (ruleset/enable/pkgsel)"
fi
# the RTC ships UTC even when the in-target hwclock write misbehaves:
# the forced stamp lands AFTER the call, and LOCAL is FATAL
if printf '%s' "$LC_CODE" | grep -qF "tail -1 /target/etc/adjtime | grep -qx 'UTC'" \
   && printf '%s' "$LC_CODE" | grep -qF 'adjtime does not say UTC'; then
  ok "adjtime forced to UTC after hwclock, with a FATAL on LOCAL"
else
  bad "adjtime UTC force/assert missing — the RTC can ship with a LOCAL fingerprint again"
fi

echo "== release fixes =="
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
chk "gateway account is born locked (no crypted hash, no sudo group)" \
  "grep -qE '^d-i passwd/user-password-crypted string \\*\$' '$REPO/gateway/preseed.cfg' && ! grep -q '\$6\$' '$REPO/gateway/preseed.cfg'"
chk "no public build password literal anywhere in gateway/ or tests/leaks/" \
  "! grep -rq 'ombra-build' '$REPO/gateway' '$REPO/tests/leaks'"
chk "gateway ships no DHCP-server accept on the private link" \
  "! grep -q 'iifname \"ombra-intnet\" udp dport 67' '$G2/etc/nftables.conf'"
chk "torctl filter runs as its own uid, created at install" \
  "grep -q '^User=ombra-torctl' '$G2/etc/systemd/system/ombra-torctl-filter.service' && grep -q 'adduser.*ombra-torctl' '$REPO/gateway/late-command.sh'"
chk "leak probe never prints the exit IP (no EXIT_IP echo)" \
  "! grep -q 'exit IP through Tor' '$G2/usr/local/sbin/ombra-leak-probe'"
chk "desktop boot units are enable-asserted before the tty1 mask" \
  "grep -q 'graphical.target.wants/ombra-setup-gate.service' '$REPO/desktop/late-command.sh'"
chk "askpass fallback is a supervised child, not an exec of the stock agent" \
  "[ -x '$T2/usr/local/sbin/ombra-askpass-fallback' ] && ! grep -q 'exec systemd-tty-ask-password-agent' '$T2/etc/systemd/system/ombra-askpass-fallback.service'"
chk "Tor Browser wrapper pins SOCKS/control env and no legacy torlauncher prefs" \
  "grep -q 'TOR_SOCKS_HOST' '$REPO/desktop/late-command.sh' && grep -q 'TOR_CONTROL_COOKIE_AUTH_FILE' '$REPO/desktop/late-command.sh' && ! grep -q 'extensions.torlauncher' '$REPO/desktop/late-command.sh'"
chk "desktop package set carries the reencrypt tooling" \
  "grep -q 'cryptsetup-bin' '$REPO/desktop/preseed.cfg' && grep -q 'dmsetup' '$REPO/desktop/preseed.cfg'"
chk "vmx template disables the host-guest channels explicitly" \
  "grep -q 'isolation.tools.copy.disable' '$REPO/build/fusion/gateway-vm-template.vmx' && grep -q 'isolation.tools.dnd.disable' '$REPO/build/fusion/gateway-vm-template.vmx'"
chk "gateway sudoers drop-ins are forced to 0440 (git cannot carry the mode)" \
  "grep -q 'chmod 0440 /target/etc/sudoers.d/ombra-' '$REPO/gateway/late-command.sh'"
chk "gateway installs with 2 GB RAM and ships 512 MB (no swap partition on the 5 GB disk)" \
  "grep -q 'memsize = \"2048\"' '$REPO/build/fusion/create-gateway-vm.sh' && grep -q 'vmx_set memsize 512' '$REPO/build/fusion/post-install-gateway.sh' && ! grep -q 'linux-swap' '$REPO/gateway/preseed.cfg' && grep -q '^d-i partman-basicfilesystems/no_swap boolean false' '$REPO/gateway/preseed.cfg'"
chk "gateway root overlay is remounted writable by a remount-fs override (the stock unit fails on overlayfs)" \
  "grep -q -- '--options-mode ignore -o remount,rw /' '$REPO/gateway/rootfs/etc/systemd/system/systemd-remount-fs.service.d/10-ombra-overlay.conf'"
chk "installer apt retries a flaky mirror instead of parking on the repository dialog" \
  "grep -q 'etc/apt/apt.conf.d/99ombra-retries' '$REPO/build/make-install-iso.sh'"
chk "test-only guest password can never be baked into the plain gateway ISO name" \
  "grep -q 'ombra-install-\$TARGET-test.iso' '$REPO/build/make-install-iso.sh'"

echo "== audit hardening =="
chk "desktop user is not in sudo: default groups pinned, gpasswd + sudo purge in late.sh, FATAL asserts" \
  "grep -qE '^d-i passwd/user-default-groups string audio video\$' '$REPO/desktop/preseed.cfg' && grep -q 'in-target gpasswd -d ombra sudo' '$REPO/desktop/late-command.sh' && grep -q 'ombra is still in the sudo group' '$REPO/desktop/late-command.sh'"
chk "gateway keeps sudo (its NOPASSWD grants need it)" \
  "! grep -q 'purge_present sudo' '$REPO/gateway/late-command.sh' && ! grep -q 'user-default-groups string audio' '$REPO/gateway/preseed.cfg'"
chk "gateway installs the sudo package its NOPASSWD grants and console commands need" \
  "grep -E '^d-i pkgsel/include string' '$REPO/gateway/preseed.cfg' | grep -qE ' sudo( |\$)'"
chk "desktop firewall egress and ping are scoped to the gateway host, not the /24" \
  "grep -q 'ip daddr 10.55.10.1 counter accept' '$T2/etc/nftables.conf' && grep -q 'ip saddr 10.55.10.1 ip protocol icmp' '$T2/etc/nftables.conf' && ! grep -v '^ *#' '$T2/etc/nftables.conf' | grep -q '10.55.10.0/24'"
chk "NetworkManager profiles forced to 0600 in late.sh (git cannot carry the mode)" \
  "grep -q 'chmod 0600 /target/etc/NetworkManager/system-connections/\*.nmconnection' '$REPO/desktop/late-command.sh' && grep -q 'chmod 0755 /target/usr/local/sbin/ombra-askpass-fallback' '$REPO/desktop/late-command.sh'"
chk "leak probe: scratch in a root-owned 0700 dir, only the report in a root-owned 0755 dir, no chown, PATH pinned" \
  "grep -q '^WORK=/run/ombra-leak-work\$' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q 'mkdir -m 0700 \"\$WORK\"' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q 'mkdir -m 0755 \"\$OUT\"' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q '^REPORT=\$OUT/report.txt\$' '$G2/usr/local/sbin/ombra-leak-probe' && ! grep -q 'chown' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q '^PATH=' '$G2/usr/local/sbin/ombra-leak-probe'"
chk "leak probe sudoers grant takes no arguments and resets the environment" \
  "grep -qF 'NOPASSWD: /usr/local/sbin/ombra-leak-probe \"\"' '$G2/etc/sudoers.d/ombra-leak-probe' && grep -q '^Defaults!/usr/local/sbin/ombra-leak-probe env_reset\$' '$G2/etc/sudoers.d/ombra-leak-probe'"
chk "torctl filter unit is network- and proc-confined" \
  "grep -q '^IPAddressDeny=any\$' '$G2/etc/systemd/system/ombra-torctl-filter.service' && grep -q '^IPAddressAllow=127.0.0.1 10.55.10.0/24\$' '$G2/etc/systemd/system/ombra-torctl-filter.service' && grep -q '^ProtectProc=invisible\$' '$G2/etc/systemd/system/ombra-torctl-filter.service' && grep -q '^PrivateDevices=yes\$' '$G2/etc/systemd/system/ombra-torctl-filter.service'"
FW_OK=1
for u in systemd-networkd tor@default dnsmasq; do
  f="$G2/etc/systemd/system/$u.service.d/10-ombra-firewall.conf"
  grep -q '^Requires=nftables.service$' "$f" 2>/dev/null && grep -q '^After=nftables.service$' "$f" 2>/dev/null || FW_OK=0
done
f="$T2/etc/systemd/system/NetworkManager.service.d/10-ombra-firewall.conf"
grep -q '^Requires=nftables.service$' "$f" 2>/dev/null && grep -q '^After=nftables.service$' "$f" 2>/dev/null || FW_OK=0
chk "the firewall is a hard dependency of every network-facing unit (gateway networkd/tor/dnsmasq, desktop NM)" "[ $FW_OK = 1 ]"
chk "export refuses a vmx that references a test ISO or is named TEST" \
  "grep -qF 'test builds are never exported' '$REPO/build/fusion/export-release-image.sh'"
chk "test ISOs produce TEST-named VMs on both targets" \
  "grep -qF 'displayName = \"ombra-desktop-TEST\"' '$REPO/build/fusion/create-desktop-vm.sh' && grep -qF 'displayName = \"ombra-gateway-TEST\"' '$REPO/build/fusion/create-gateway-vm.sh'"
chk "release workflow drops checkout credentials and refuses a test-build environment" \
  "grep -q 'persist-credentials: false' '$REPO/.github/workflows/release.yml' && grep -q 'OMBRA_TEST_GUEST_PASSWORD' '$REPO/.github/workflows/release.yml'"
chk "plain-built preseeds carry the locked hash (*) on both targets" \
  "grep -qE '^d-i passwd/user-password-crypted string \\*\$' '$TMP/x-gateway/preseed.cfg' && grep -qE '^d-i passwd/user-password-crypted string \\*\$' '$TMP/x-desktop/preseed.cfg'"
chk "08ombra neutralises 94save-logs on plain builds only; late.sh scrubs /var/log/installer" \
  "grep -q '94save-logs' '$TMP/x-gateway/usr/lib/finish-install.d/08ombra' && grep -q '94save-logs' '$TMP/x-desktop/usr/lib/finish-install.d/08ombra' && grep -q 'if \[ -z \"\$TEST_PASS\" \]' '$REPO/build/make-install-iso.sh' && grep -q '/var/log/installer' '$REPO/gateway/late-command.sh' && grep -q '/var/log/installer' '$REPO/desktop/late-command.sh'"
chk "desktop timesync owns /run/ombra so its state file is writable under ProtectSystem=strict" \
  "grep -q '^RuntimeDirectory=ombra\$' '$T2/etc/systemd/system/ombra-timesync.service' && grep -q '^RuntimeDirectoryPreserve=yes\$' '$T2/etc/systemd/system/ombra-timesync.service'"

echo "== ova export =="
F="$REPO/build/fusion"
chk "gateway template: ethernet0 vmxnet3, ethernet1 e1000e" \
  "grep -q '^ethernet0.virtualDev = \"vmxnet3\"' '$F/gateway-vm-template.vmx' && grep -q '^ethernet1.virtualDev = \"e1000e\"' '$F/gateway-vm-template.vmx'"
chk "create-gateway-vm --verify checks the NIC2 virtualDev" \
  "grep -q 'NIC2 virtualDev.*e1000e' '$F/create-gateway-vm.sh'"
chk "create-desktop-vm makes a 30GB disk and verifies 30" \
  "grep -q 'vdiskmanager\" -c -s 30GB' '$F/create-desktop-vm.sh' && grep -qE '^ +30\) ok \"disk 30GB\"' '$F/create-desktop-vm.sh' && ! grep -q '32GB' '$F/create-desktop-vm.sh'"
chk "export script uses ovftool extraconfig + compress=9 + SHA256 and asserts the NIC models" \
  "grep -q -- '--exportFlags=extraconfig' '$F/export-release-image.sh' && grep -q -- '--compress=9' '$F/export-release-image.sh' && grep -q -- '--shaAlgorithm=SHA256' '$F/export-release-image.sh' && grep -q 'e1000e' '$F/export-release-image.sh' && grep -q 'vmxnet3' '$F/export-release-image.sh'"
chk "export script no longer asserts MACs or disk mode, and ships no ISOs" \
  "! grep -qE '00:50:56|independent-nonpersistent|ethernet[01]\\.address' '$F/export-release-image.sh' && ! grep -q 'cp .*ISO_SRC' '$F/export-release-image.sh'"
chk "verify-ova.sh exists, is valid bash, and imports with --allowExtraConfig" \
  "[ -f '$F/verify-ova.sh' ] && bash -n '$F/verify-ova.sh' && grep -q -- '--allowExtraConfig' '$F/verify-ova.sh'"

echo "== guest identity =="
GN="$REPO/gateway/rootfs/etc/systemd/network"
chk "gateway .link/.network files match by driver, never by MAC" \
  "grep -qx 'Driver=vmxnet3' '$GN/05-upstream.link' && grep -qx 'Driver=vmxnet3' '$GN/10-nat.network' && grep -qx 'Driver=e1000e' '$GN/06-intnet.link' && grep -qx 'Driver=e1000e' '$GN/20-intnet.network' && ! grep -qi 'MACAddress' '$GN'/*.link '$GN'/*.network"
chk "gateway guest files pin no MAC address anywhere" \
  "! grep -rqE '00:50:56:2a:00:0[0-9a-f]' '$REPO/gateway/rootfs' '$REPO/gateway/preseed.cfg' '$REPO/gateway/late-command.sh'"
chk "desktop nmconnection matches any ethernet device (no MAC or interface-name), static address kept, mode forced 0600" \
  "N='$REPO/desktop/rootfs/etc/NetworkManager/system-connections/ombra-intnet.nmconnection'; ! grep -qE '^(mac-address|interface-name)=' \"\$N\" && grep -qx 'type=ethernet' \"\$N\" && grep -qx 'address1=10.55.10.100/24,10.55.10.1' \"\$N\" && grep -qx 'dns=10.55.10.1;' \"\$N\" && grep -qx 'method=disabled' \"\$N\" && grep -q 'chmod 0600 /target/etc/NetworkManager/system-connections' '$REPO/desktop/late-command.sh'"
chk "gateway is amnesic in-guest: overlayroot installed, conf selects tmpfs" \
  "grep -qE '^d-i pkgsel/include string .*\\boverlayroot\\b' '$REPO/gateway/preseed.cfg' && grep -qx 'overlayroot=\"tmpfs\"' '$REPO/gateway/rootfs/etc/overlayroot.conf'"
chk "gateway late.sh rebuilds the initramfs after the overlay unpack and FATALs without the overlayroot script" \
  "L='$REPO/gateway/late-command.sh'; grep -q '^ombra_fatal()' \"\$L\" && [ \"\$(grep -n 'rootfs.tar.gz -C /target' \"\$L\" | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'in-target update-initramfs -u' \"\$L\" | head -1 | cut -d: -f1)\" ] && grep -q 'init-bottom/overlayroot' \"\$L\" && grep -A1 'lsinitramfs' \"\$L\" | grep -q ombra_fatal"
chk "gateway systemcheck fails when / is not an overlay" \
  "grep -q 'findmnt -no FSTYPE /' '$REPO/gateway/rootfs/usr/local/sbin/ombra-systemcheck' && grep -q '\"overlay\"' '$REPO/gateway/rootfs/usr/local/sbin/ombra-systemcheck'"

echo "== boot modes =="
for M in desktop gateway; do
  R="$REPO/$M/rootfs"; L="$REPO/$M/late-command.sh"
  chk "$M: grub.d generator defines both mode titles and distinct ids" \
    "grep -q 'Ombra — Persistent' '$R/etc/grub.d/09_ombra' && grep -q 'Ombra — Amnesic' '$R/etc/grub.d/09_ombra' && grep -q 'ombra-persistent' '$R/etc/grub.d/09_ombra' && grep -q 'ombra-amnesic' '$R/etc/grub.d/09_ombra'"
  chk "$M: late-command chmods the generator 0755 and disarms the stock generators" \
    "grep -q 'chmod 0755 /target/etc/grub.d/09_ombra' '$L' && grep -q 'chmod 0644 \"/target/etc/grub.d/\$g\"' '$L' && grep -q '10_linux' '$L'"
  chk "$M: theme ships and names the palette" \
    "T='$R/boot/grub/themes/ombra/theme.txt'; grep -q '#0b0c11' \"\$T\" && grep -q '#f4f3ef' \"\$T\" && grep -q '#8b8d93' \"\$T\" && [ -f '$R/boot/grub/themes/ombra/sel_c.png' ] && [ -f '$R/boot/grub/themes/ombra/menu_c.png' ]"
  chk "$M: grub drop-in sets menu style, no recovery/submenu/os-prober, gfxterm modes and theme" \
    "D='$R/etc/default/grub.d/99-ombra-brand.cfg'; grep -qx 'GRUB_TIMEOUT_STYLE=menu' \"\$D\" && grep -qx 'GRUB_DISABLE_RECOVERY=true' \"\$D\" && grep -qx 'GRUB_DISABLE_SUBMENU=y' \"\$D\" && grep -qx 'GRUB_DISABLE_OS_PROBER=true' \"\$D\" && grep -qx 'GRUB_GFXMODE=1280x800,1024x768,auto' \"\$D\" && grep -qx 'GRUB_THEME=/boot/grub/themes/ombra/theme.txt' \"\$D\""
  chk "$M: preseed installs overlayroot and the remount drop-in ships" \
    "grep -qE '^d-i pkgsel/include string .*\\boverlayroot\\b' '$REPO/$M/preseed.cfg' && grep -q -- '--options-mode ignore -o remount,rw /' '$R/etc/systemd/system/systemd-remount-fs.service.d/10-ombra-overlay.conf'"
  chk "$M: late-command FATAL-guards grub.cfg content (both entries, theme, entry count, mode parameter)" \
    "grep -A1 \"grep -q 'Ombra — Persistent'\" '$L' | grep -q ombra_fatal && grep -A1 \"grep -c '^menuentry '\" '$L' | grep -q ombra_fatal && grep -A1 \"themes/ombra/theme.txt' \\\"\\\$GCFG\" '$L' | grep -q ombra_fatal"
done
chk "desktop boot menu never auto-starts (timeout -1)" \
  "grep -qx 'GRUB_TIMEOUT=-1' '$REPO/desktop/rootfs/etc/default/grub.d/99-ombra-brand.cfg'"
chk "gateway boot menu never auto-starts (timeout -1), Amnesic highlighted first" \
  "grep -qx 'GRUB_TIMEOUT=-1' '$REPO/gateway/rootfs/etc/default/grub.d/99-ombra-brand.cfg' && grep -qx 'GRUB_DEFAULT=0' '$REPO/gateway/rootfs/etc/default/grub.d/99-ombra-brand.cfg' && [ \"\$(grep '^entry ' '$REPO/gateway/rootfs/etc/grub.d/09_ombra' | head -1 | grep -c Amnesic)\" = 1 ] && grep -q 'overlayroot=disabled' '$REPO/gateway/rootfs/etc/grub.d/09_ombra' && ! grep -q '__timeout__' '$REPO/gateway/rootfs/boot/grub/themes/ombra/theme.txt'"
chk "desktop highlights Persistent first; Amnesic adds overlayroot=tmpfs" \
  "[ \"\$(grep '^entry ' '$REPO/desktop/rootfs/etc/grub.d/09_ombra' | head -1 | grep -c Persistent)\" = 1 ] && grep -q 'overlayroot=tmpfs' '$REPO/desktop/rootfs/etc/grub.d/09_ombra' && ! grep -q '__timeout__' '$REPO/desktop/rootfs/boot/grub/themes/ombra/theme.txt'"
chk "desktop overlayroot.conf is persistent by default" \
  "grep -qx 'overlayroot=\"\"' '$REPO/desktop/rootfs/etc/overlayroot.conf' && grep -qx 'overlayroot_cfgdisk=\"disabled\"' '$REPO/desktop/rootfs/etc/overlayroot.conf'"
chk "desktop late-command FATALs when the initrd lacks the overlayroot script" \
  "grep -A1 'init-bottom/overlayroot' '$REPO/desktop/late-command.sh' | grep -q ombra_fatal"
chk "cmdline hardening still owned by the 50-ombra drop-ins (no late sed on the gateway)" \
  "grep -q 'ipv6.disable=1' '$REPO/gateway/rootfs/etc/default/grub.d/50-ombra.cfg' && grep -q 'init_on_alloc=1' '$REPO/desktop/rootfs/etc/default/grub.d/50-ombra.cfg'"
chk "grub.d generators parse" \
  "sh -n '$REPO/desktop/rootfs/etc/grub.d/09_ombra' && sh -n '$REPO/gateway/rootfs/etc/grub.d/09_ombra'"

echo "== tor control socket =="
chk "gateway torrc disables the unix control socket" \
  "grep -qx 'ControlSocket 0' '$REPO/gateway/rootfs/etc/tor/torrc'"
chk "no tor drop-in depends on a control socket path" \
  "! grep -rq '/run/tor/control\\b' '$REPO/gateway/rootfs/etc/systemd' 2>/dev/null || ! grep -rE 'ExecStartPost.*run/tor/control' '$REPO/gateway/rootfs/etc/systemd' >/dev/null"

echo "== transfer disks =="
TU="$REPO/desktop/rootfs/etc/systemd/system"
chk "the shared disk mounts by its OMBRA-SHARE label as vfat, synchronously, private, noexec,nosuid,nodev, uid 1000" \
  "grep -qx 'What=/dev/disk/by-label/OMBRA-SHARE' '$TU/mnt-transfer-shared.mount' && grep -qx 'Where=/mnt/transfer/shared' '$TU/mnt-transfer-shared.mount' && grep -qx 'Type=vfat' '$TU/mnt-transfer-shared.mount' && grep -E '^Options=' '$TU/mnt-transfer-shared.mount' | grep -q 'sync,flush' && grep -E '^Options=' '$TU/mnt-transfer-shared.mount' | grep -q 'umask=077' && grep -E '^Options=' '$TU/mnt-transfer-shared.mount' | grep -q 'noexec,nosuid,nodev' && grep -E '^Options=' '$TU/mnt-transfer-shared.mount' | grep -q 'uid=1000'"
chk "the automount names the path of its mount unit and is only offered when the disk exists" \
  "grep -qx 'Where=/mnt/transfer/shared' '$TU/mnt-transfer-shared.automount' && grep -qx 'ConditionPathExists=/dev/disk/by-label/OMBRA-SHARE' '$TU/mnt-transfer-shared.automount'"
chk "the old inbox and outbox units are gone" \
  "! ls '$TU'/mnt-transfer-inbox.* '$TU'/mnt-transfer-outbox.* >/dev/null 2>&1"
chk "late.sh enables the automount and fails the install if it cannot" \
  "grep -q 'systemctl enable mnt-transfer-shared.automount' '$REPO/desktop/late-command.sh' && grep -q 'transfer mounts' '$REPO/desktop/late-command.sh'"
chk "the raw shared disk is hidden from Dolphin" \
  "grep -q 'OMBRA-SHARE' '$REPO/desktop/rootfs/etc/udev/rules.d/91-ombra-hide-transfer-disks.rules' && grep -q 'UDISKS_IGNORE' '$REPO/desktop/rootfs/etc/udev/rules.d/91-ombra-hide-transfer-disks.rules'"
chk "the transfer path does not depend on udisks2: it is in no explicit install list" \
  "! grep -qE '(^|[ ])udisks2([ ]|\$)' '$REPO/desktop/late-command.sh' '$REPO/desktop/preseed.cfg'"
chk "the copy script is executable, parses, targets the shared folder and syncs it" \
  "[ -x '$REPO/desktop/rootfs/usr/local/bin/ombra-send-to-mac' ] && bash -n '$REPO/desktop/rootfs/usr/local/bin/ombra-send-to-mac' && grep -q 'out=/mnt/transfer/shared' '$REPO/desktop/rootfs/usr/local/bin/ombra-send-to-mac' && grep -q 'sync -f' '$REPO/desktop/rootfs/usr/local/bin/ombra-send-to-mac' && grep -q 'mountpoint -q' '$REPO/desktop/rootfs/usr/local/bin/ombra-send-to-mac'"
chk "the Dolphin service menu runs that script on selected files" \
  "grep -qx 'Exec=/usr/local/bin/ombra-send-to-mac %F' '$REPO/desktop/rootfs/usr/share/kio/servicemenus/ombra-send-to-mac.desktop'"
chk "the sidebar has one Mac Shared Folder place and the file is well-formed XML" \
  "python3 -c \"import sys,xml.dom.minidom as m; m.parse(sys.argv[1])\" '$REPO/desktop/rootfs/etc/skel/.local/share/user-places.xbel' && grep -q 'file:///mnt/transfer/shared' '$REPO/desktop/rootfs/etc/skel/.local/share/user-places.xbel' && ! grep -q 'From Mac\|To Mac' '$REPO/desktop/rootfs/etc/skel/.local/share/user-places.xbel'"

chk "leak probe stamps its report and the host harness only trusts a report from its own run" \
  "grep -q 'started-epoch' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q 'started-epoch' '$REPO/tests/leaks/run-gateway-leaks.sh' && bash -n '$REPO/tests/leaks/run-gateway-leaks.sh' && bash -n '$G2/usr/local/sbin/ombra-leak-probe'"

echo "== privacy applications =="
D2="$REPO/desktop/rootfs"
chk "gateway firewall lets only Tor reach the desktop on the onion-service port range, and the desktop accepts it only from the gateway" \
  "grep -q 'meta skuid \"debian-tor\" oifname \"ombra-intnet\" ip daddr 10.55.10.0/24 tcp dport 17600-17659' '$G2/etc/nftables.conf' && grep -q 'ip saddr 10.55.10.1 tcp dport 17600-17659' '$D2/etc/nftables.conf'"
chk "the control-port filter's onion-service ports match both firewalls (17600-17659)" \
  "grep -q 'ONION_PORT_MIN: u16 = 17600' '$REPO/core/src/torctl.rs' && grep -q 'ONION_PORT_MAX: u16 = 17659' '$REPO/core/src/torctl.rs'"
chk "OnionShare listens off-loopback only because the Whonix-style workstation marker exists" \
  "[ -f '$D2/usr/share/anon-ws-base-files/workstation' ]"
chk "OnionShare is preset to the gateway's filtered control port and SOCKS port, with updates off" \
  "python3 -c \"import json,sys; c=json.load(open(sys.argv[1])); assert c['connection_type']=='control_port' and c['control_port_address']=='10.55.10.1' and c['control_port_port']==9052 and c['socks_address']=='10.55.10.1' and c['socks_port']==9050 and c['use_autoupdate'] is False and c['bridges_enabled'] is False\" '$D2/etc/skel/.config/onionshare/onionshare.json'"
chk "Electrum is preset to the gateway's SOCKS port with update checks off" \
  "python3 -c \"import json,sys; c=json.load(open(sys.argv[1])); assert c['proxy'].startswith('socks5:10.55.10.1:9050') and c['check_updates'] is False\" '$D2/etc/skel/.electrum/config'"
chk "dirmngr is Tor-only and the local SOCKS forwarder exists" \
  "grep -qx 'use-tor' '$D2/etc/skel/.gnupg/dirmngr.conf' && grep -qx 'ListenStream=127.0.0.1:9050' '$D2/etc/systemd/system/ombra-socks.socket' && grep -q 'systemd-socket-proxyd 10.55.10.1:9050' '$D2/etc/systemd/system/ombra-socks.service'"

chk "SimpleX launches through the proxychains wrapper pointed at the gateway's Tor, and its launcher entry is replaced to use it" \
  "[ -x '$D2/usr/local/bin/simplex' ] && grep -q 'proxychains4 -q -f /etc/ombra/proxychains.conf /opt/simplex/bin/simplex' '$D2/usr/local/bin/simplex' && grep -qx 'socks5 10.55.10.1 9050' '$D2/etc/ombra/proxychains.conf' && grep -q 'Exec=/usr/local/bin/simplex' '$REPO/desktop/late-command.sh' && grep -q 'proxychains4 ' '$REPO/desktop/late-command.sh'"

echo "== boot ordering =="
chk "accounts-daemon is ordered after logind so its sandbox finds /run/systemd/seats" \
  "grep -qx 'After=systemd-logind.service' '$REPO/desktop/rootfs/etc/systemd/system/accounts-daemon.service.d/ombra-after-logind.conf' && grep -qx 'Wants=systemd-logind.service' '$REPO/desktop/rootfs/etc/systemd/system/accounts-daemon.service.d/ombra-after-logind.conf'"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS test(s)"
  exit 1
fi

echo "ALL PASS"
