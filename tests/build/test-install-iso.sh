#!/bin/bash
# tests/build/test-install-iso.sh — offline test for the installer ISO builder (gateway, desktop, single)
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

echo "== build all three targets (gateway, desktop, single) =="
for t in gateway desktop single; do
  if bash "$REPO/build/make-install-iso.sh" "$t" > "$TMP/build-$t.log" 2>&1; then
    ok "$t ISO built"
  else
    bad "$t build failed:"; sed 's/^/       /' "$TMP/build-$t.log" | tail -5; exit 1
  fi
done

echo "== ISO volume id =="
for t in gateway desktop single; do
  ISO="$REPO/build/disks/ombra-install-$t.iso"
  got="$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p')"
  [ "$got" = "Ombra-$t-arm64" ] \
    && ok "$t volume id: $got" \
    || bad "$t volume id is '${got:-none}', want Ombra-$t-arm64 (Debian's PVD leaked through)"
done

echo "== one ISO, no second-disc/HTTP artifacts =="
for t in gateway desktop single; do
  [ -f "$REPO/build/disks/ombra-install-$t.iso" ] && ok "ombra-install-$t.iso" || bad "ombra-install-$t.iso missing"
done
[ -e "$REPO/build/disks/preseed-gateway.iso" ] && bad "second-disc artifact preseed-gateway.iso exists" || ok "no second-disc artifacts"
[ -e "$REPO/build/serve" ] && bad "build/serve (HTTP preseed staging) exists" || ok "no HTTP-preseed artifacts"

echo "== payload segment per target (wrong-payload guard) =="
for t in gateway desktop single; do
  ISO="$REPO/build/disks/ombra-install-$t.iso"
  xorriso -osirrox on -indev "$ISO" -extract /install.a64/initrd.gz "$TMP/$t.gz" >/dev/null 2>&1
  CGZ=$(( $(stat -f %z "$TMP/$t.gz") - STOCK ))
  [ "$CGZ" -gt 1000 ] || { bad "$t: initrd not extended (+${CGZ}B)"; continue; }
  tail -c "$CGZ" "$TMP/$t.gz" > "$TMP/$t.seg"
  mkdir -p "$TMP/x-$t"
  ( cd "$TMP/x-$t" && gzip -dc "$TMP/$t.seg" | cpio -id --quiet ) >/dev/null 2>&1
  # single: desktop/preseed.cfg through make-install-iso.sh's single_preseed (checked line by line in the single section)
  [ "$t" = single ] && continue
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
# a late.sh failure must never reach the power-off: the hook parks with a loud console line.
grep -q 'install parked; DO NOT ship' "$TMP/x-gateway/usr/lib/finish-install.d/08ombra" \
  && grep -q 'exit/poweroff false' "$TMP/x-gateway/usr/lib/finish-install.d/08ombra" \
  && ok "08ombra parks the install on the console if late.sh fails" \
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
         ./etc/systemd/system/ombra-kwin-compositing.service \
         ./usr/local/sbin/ombra-kwin-compositing \
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
         ./usr/share/sddm/themes/Colloid-dark/background.jpg \
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
   && grep -q 'ombra-ink-4k.jpg' "$LAYOUT" \
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
   && grep -q 'StartupWMClass=Tor Browser' "$OVR/tor-browser.desktop" \
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
GRUB_BASE_LINE='GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=0 slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 randomize_kstack_offset=on debugfs=off ipv6.disable=1"'
if grep -qF "$GRUB_BASE_LINE" "$GRUB_SNIP" \
   && ! grep -vE '^\s*#' "$GRUB_SNIP" | grep -qF 'init_on_free'; then
  ok "kernel cmdline: base + hardening set + ipv6.disable=1 (both editions), init_on_free excluded (display race)"
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
  "grep -qF 'test builds are never exported' '$REPO/build/fusion/export-bundle.sh' && grep -qF 'test builds are never exported' '$REPO/build/utm/export-bundle.sh'"
chk "test ISOs produce TEST-named VMs on every target (desktop and single through \$VM_NAME-TEST)" \
  "grep -qF 'displayName = \\\"\$VM_NAME-TEST\\\"' '$REPO/build/fusion/create-desktop-vm.sh' && grep -q '^  two-vm) VM_NAME=ombra-desktop;' '$REPO/build/fusion/create-desktop-vm.sh' && grep -q '^  single) VM_NAME=ombra-single;' '$REPO/build/fusion/create-desktop-vm.sh' && grep -qF 'displayName = \"ombra-gateway-TEST\"' '$REPO/build/fusion/create-gateway-vm.sh'"
chk "plain-built preseeds carry the locked hash (*) on both targets" \
  "grep -qE '^d-i passwd/user-password-crypted string \\*\$' '$TMP/x-gateway/preseed.cfg' && grep -qE '^d-i passwd/user-password-crypted string \\*\$' '$TMP/x-desktop/preseed.cfg'"
chk "08ombra neutralises 94save-logs on plain builds only; late.sh scrubs /var/log/installer" \
  "grep -q '94save-logs' '$TMP/x-gateway/usr/lib/finish-install.d/08ombra' && grep -q '94save-logs' '$TMP/x-desktop/usr/lib/finish-install.d/08ombra' && grep -q 'if \[ -z \"\$TEST_PASS\" \]' '$REPO/build/make-install-iso.sh' && grep -q '/var/log/installer' '$REPO/gateway/late-command.sh' && grep -q '/var/log/installer' '$REPO/desktop/late-command.sh'"
chk "desktop timesync owns /run/ombra so its state file is writable under ProtectSystem=strict" \
  "grep -q '^RuntimeDirectory=ombra\$' '$T2/etc/systemd/system/ombra-timesync.service' && grep -q '^RuntimeDirectoryPreserve=yes\$' '$T2/etc/systemd/system/ombra-timesync.service'"

echo "== bundle export =="
F="$REPO/build/fusion"
chk "gateway template: ethernet0 vmxnet3, ethernet1 e1000e" \
  "grep -q '^ethernet0.virtualDev = \"vmxnet3\"' '$F/gateway-vm-template.vmx' && grep -q '^ethernet1.virtualDev = \"e1000e\"' '$F/gateway-vm-template.vmx'"
chk "create-gateway-vm --verify checks the NIC2 virtualDev" \
  "grep -q 'NIC2 virtualDev.*e1000e' '$F/create-gateway-vm.sh'"
chk "create-desktop-vm makes a 30GB disk and verifies 30" \
  "grep -q 'vdiskmanager\" -c -s 30GB' '$F/create-desktop-vm.sh' && grep -qE '^ +30\) ok \"disk 30GB\"' '$F/create-desktop-vm.sh' && ! grep -q '32GB' '$F/create-desktop-vm.sh'"
chk "export strips build identity, unpins MACs, ships an empty CD and asserts the NIC count" \
  "grep -q 'generatedAddress' '$F/export-bundle.sh' && grep -q 'addressType.*generated\\|vmx_put \"\$key\" generated' '$F/export-bundle.sh' && grep -q 'sata0:0.deviceType cdrom-raw' '$F/export-bundle.sh' && grep -q 'want_nics' '$F/export-bundle.sh'"
chk "verify-bundle checks isolation key VALUES, not just presence" \
  "grep -q 'is TRUE' '$F/verify-bundle.sh' && grep -q 'setGUIOptions.enable is FALSE' '$F/verify-bundle.sh' && ! grep -q 'present\" .\[ -n' '$F/verify-bundle.sh'"
chk "the OVA path is gone (OVF cannot carry an ARM guest type)" \
  "[ ! -e '$F/export-release-image.sh' ] && [ ! -e '$F/verify-ova.sh' ]"

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
chk "desktop highlights Persistent first; Amnesic adds overlayroot=tmpfs:recurse=1 (the separate /home LV is overlaid too)" \
  "[ \"\$(grep '^entry ' '$REPO/desktop/rootfs/etc/grub.d/09_ombra' | head -1 | grep -c Persistent)\" = 1 ] && grep -q 'ombra-amnesic overlayroot=tmpfs:recurse=1\$' '$REPO/desktop/rootfs/etc/grub.d/09_ombra' && grep -q \"grep -q 'overlayroot=tmpfs:recurse=1' \\\"\\\$GCFG\\\"\" '$REPO/desktop/late-command.sh' && ! grep -q '__timeout__' '$REPO/desktop/rootfs/boot/grub/themes/ombra/theme.txt'"
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

echo "== qemu guest tools (UTM) =="
chk "both images install the QEMU guest agent, and the desktop installs spice-vdagent for display auto-fit" \
  "grep -q ' qemu-guest-agent ' '$REPO/gateway/preseed.cfg' && grep -q ' qemu-guest-agent spice-vdagent ' '$REPO/desktop/preseed.cfg'"
chk "both overlays ship the same agent allowlist: ping, sync, sync-delimited and info, nothing that runs commands, touches files or sets state" \
  "cmp -s '$REPO/gateway/rootfs/etc/qemu/qemu-ga.conf' '$REPO/desktop/rootfs/etc/qemu/qemu-ga.conf' && grep -qx 'allow-rpcs=guest-sync,guest-sync-delimited,guest-ping,guest-info' '$REPO/desktop/rootfs/etc/qemu/qemu-ga.conf' && ! grep -q -E '^[^#]*(block-rpcs|guest-exec|guest-file|guest-set-|guest-ssh|guest-fs|guest-shutdown)' '$REPO/desktop/rootfs/etc/qemu/qemu-ga.conf'"
# the compositor policy: run the real script with a stubbed systemd-detect-virt against a scratch config path
KW="$TMP/kwin-policy"; mkdir -p "$KW/bin"
sed "s#/etc/xdg/kwinrc#$KW/kwinrc#" "$REPO/desktop/rootfs/usr/local/sbin/ombra-kwin-compositing" > "$KW/run.sh"
for v in qemu vmware none; do printf '#!/bin/sh\necho %s\n' "$v" > "$KW/bin/systemd-detect-virt-$v"; done
kw_run() { printf '#!/bin/sh\necho %s\n' "$1" > "$KW/bin/systemd-detect-virt"; chmod +x "$KW/bin/systemd-detect-virt"; PATH="$KW/bin:$PATH" sh "$KW/run.sh"; }
chk "KWin compositing is switched off on a QEMU guest (software GL stalls on screen growth)" \
  "kw_run qemu && grep -qx 'Enabled=false' '$KW/kwinrc' && grep -qx '\\[Compositing\\]' '$KW/kwinrc'"
chk "KWin compositing is left as shipped on VMware, and a stale QEMU policy is removed there" \
  "kw_run vmware && [ ! -e '$KW/kwinrc' ]"
chk "the compositing policy unit runs before the display manager, is enabled by late-command and its helper is made executable" \
  "grep -q '^Before=sddm.service' '$REPO/desktop/rootfs/etc/systemd/system/ombra-kwin-compositing.service' && grep -q 'systemctl enable ombra-kwin-compositing.service' '$REPO/desktop/late-command.sh' && grep -q 'sbin/ombra-kwin-compositing' '$REPO/desktop/late-command.sh' && [ -x '$REPO/desktop/rootfs/usr/local/sbin/ombra-kwin-compositing' ]"
chk "both late-command scripts check every allowed command against the agent and refuse command execution, file access or state changes" \
  "for f in gateway desktop; do grep -q 'qemu-ga --allow-rpcs=help' '$REPO'/\$f/late-command.sh && grep -q 'allows command execution, file access or a state change' '$REPO'/\$f/late-command.sh && grep -q 'which this agent does not have' '$REPO'/\$f/late-command.sh || exit 1; done"
chk "the allowlist check captures the agent's help through chroot, never through in-target (in-target sends its output to the syslog, so a capture of it is always empty and parks the install)" \
  "for f in gateway desktop; do grep -q 'GA_KNOWN=\"\$(chroot /target qemu-ga --allow-rpcs=help' '$REPO'/\$f/late-command.sh && ! grep -q '\$(in-target qemu-ga' '$REPO'/\$f/late-command.sh && grep -q 'printed nothing' '$REPO'/\$f/late-command.sh || exit 1; done"
chk "the desktop initrd carries the virtio_gpu driver (hook ships executable) and the build refuses to ship without it, so the unlock screen is visible under QEMU/UTM" \
  "[ -x '$REPO/desktop/rootfs/usr/share/initramfs-tools/hooks/ombra-gpu' ] && grep -qx 'manual_add_modules virtio_gpu' '$REPO/desktop/rootfs/usr/share/initramfs-tools/hooks/ombra-gpu' && grep -q 'virtio\[-_\]gpu\[.\]ko' '$REPO/desktop/late-command.sh' && grep -q 'the rebuilt initrd has no virtio_gpu driver' '$REPO/desktop/late-command.sh'"
chk "only TEST builds get the wider agent allowlist and the test-build marker; the release path removes the empty override" \
  "grep -q 'if \\[ -n \"\$TEST_PASS\" \\]; then' '$REPO/build/make-install-iso.sh' && grep -q ': > \"\$STAGE/initrd/ombra/test-build\"' '$REPO/build/make-install-iso.sh' && grep -q 'guest-exec,guest-exec-status' '$REPO/build/make-install-iso.sh'"

chk "the release ISOs carry the strict agent allowlist and no test-build marker" \
  "! grep -rq 'guest-exec' '$G2/etc/qemu' '$T2/etc/qemu' && [ ! -e '$TMP/x-gateway/ombra/test-build' ] && [ ! -e '$TMP/x-desktop/ombra/test-build' ] && grep -qx 'allow-rpcs=guest-sync,guest-sync-delimited,guest-ping,guest-info' '$G2/etc/qemu/qemu-ga.conf' '$T2/etc/qemu/qemu-ga.conf'"

echo "== boot ordering =="
chk "accounts-daemon is ordered after logind so its sandbox finds /run/systemd/seats" \
  "grep -qx 'After=systemd-logind.service' '$REPO/desktop/rootfs/etc/systemd/system/accounts-daemon.service.d/ombra-after-logind.conf' && grep -qx 'Wants=systemd-logind.service' '$REPO/desktop/rootfs/etc/systemd/system/accounts-daemon.service.d/ombra-after-logind.conf'"

echo "== review fixes (2026-11) =="
chk "both installers park on ANY unhandled error (EXIT trap), and the finish hook never powers off a failed run" \
  "for f in gateway desktop; do grep -q \"trap 'rc=\\\$?; \\[ \\\"\\\$rc\\\" -eq 0 \\] || ombra_fatal\" '$REPO'/\$f/late-command.sh || exit 1; done && grep -q 'debian-installer/exit/poweroff false' '$TMP/x-gateway/usr/lib/finish-install.d/08ombra'"
chk "the gateway console may run the update and health commands through sudo, and nothing broader" \
  "grep -q 'NOPASSWD: /usr/local/sbin/ombra-update apply, /usr/local/sbin/ombra-update rollback' '$G2/etc/sudoers.d/ombra-update' && grep -qF 'NOPASSWD: /usr/local/sbin/ombra-systemcheck \"\"' '$G2/etc/sudoers.d/ombra-systemcheck' && ! grep -rqE 'NOPASSWD: *ALL|\(ALL' '$G2/etc/sudoers.d'"
chk "the updater detects Amnesic by the root mount (the gateway's Amnesic boot has no kernel parameter) and apply refuses an expired index" \
  "grep -q 'findmnt -n -o FSTYPE /' '$REPO/update/rootfs/usr/local/sbin/ombra-update' && grep -q 'index_expired || die' '$REPO/update/rootfs/usr/local/sbin/ombra-update'"
chk "Tor Browser has its own SOCKS port with per-site isolation, opened in the gateway firewall and both listener whitelists" \
  "grep -q '^SocksPort 10.55.10.1:9150 ExtendedErrors KeepAliveIsolateSOCKSAuth\$' '$G2/etc/tor/torrc' && grep -q 'tcp dport 9150' '$G2/etc/nftables.conf' && grep -q '9150' '$G2/usr/local/sbin/ombra-systemcheck' && grep -q '10.55.10.1:9150' '$G2/usr/local/sbin/ombra-leak-probe' && grep -q 'socks_port\", 9150' '$REPO/desktop/late-command.sh' && grep -q 'TOR_SOCKS_PORT=9150' '$REPO/desktop/late-command.sh'"
chk "time sync runs a one-source quick check every 5 min and keeps the 2-of-3 vote for any step" \
  "for r in gateway desktop; do grep -qx 'OnUnitInactiveSec=5min' '$REPO'/\$r/rootfs/etc/systemd/system/ombra-timesync.timer && grep -q 'quick check' '$REPO'/\$r/rootfs/usr/local/sbin/ombra-timesync && grep -q 'best_c' '$REPO'/\$r/rootfs/usr/local/sbin/ombra-timesync || exit 1; done"
chk "the gateway installs no tasksel task, names every tool its scripts need, and parks if one is missing" \
  "grep -qx 'tasksel tasksel/first multiselect' '$REPO/gateway/preseed.cfg' && grep -E '^d-i pkgsel/include' '$REPO/gateway/preseed.cfg' | grep -q bind9-dnsutils && ! grep -E '^d-i pkgsel/include' '$REPO/gateway/preseed.cfg' | grep -qwE 'eza|bat|ripgrep|fzf|zoxide' && grep -q \"lacks '\\\$t'\" '$REPO/gateway/late-command.sh' && ! grep -q eza '$G2/etc/skel/.zshrc'"
chk "d-i never fetches the security/updates suites (its failure prompt cannot be preseeded); late-command adds them, retries strictly and parks if the mirror stays down" \
  "for f in gateway desktop; do grep -qx 'apt-setup apt-setup/services-select multiselect' '$REPO'/\$f/preseed.cfg && ! grep -q 'service-failed' '$REPO'/\$f/preseed.cfg && grep -q 'apt-get update --error-on=any' '$REPO'/\$f/late-command.sh && grep -q 'apt-get update failed 6 times' '$REPO'/\$f/late-command.sh && grep -q '^clock_from_mirror || true' '$REPO'/\$f/late-command.sh && grep -q 'update-initramfs -u -k all' '$REPO'/\$f/late-command.sh || exit 1; done"
chk "the installer CD is switched off as an apt source before the first strict apt-get update (both images)" \
  "for f in gateway desktop; do awk '/deb cdrom:\\|# deb cdrom:/ && !c {c=NR} /apt-get update --error-on=any/ && !u {u=NR} END {exit !(c && u && c < u)}' '$REPO'/\$f/late-command.sh || exit 1; done"
chk "both images record their Debian package manifest" \
  "for f in gateway desktop; do grep -q 'usr/share/ombra/packages.txt' '$REPO'/\$f/late-command.sh || exit 1; done"
chk "update stagers exist, are executable and post through the post.d runner" \
  "[ -x '$REPO/scripts/update/stage-torbrowser.sh' ] && [ -x '$REPO/scripts/update/stage-debs.sh' ] && [ -x '$REPO/scripts/update/post-runner.sh' ] && sh -n '$REPO/scripts/update/post-runner.sh'"
chk "the desktop uses the Ombra ink wallpaper on desktop and lock screen, and the login screen has its own background" \
  "[ -s '$T2/usr/share/backgrounds/ombra/ombra-ink-4k.jpg' ] && grep -q 'ombra-ink-4k.jpg' '$T2/etc/skel/.config/kscreenlockerrc' && grep -qx 'background=background.jpg' '$T2/usr/share/sddm/themes/Colloid-dark/theme.conf' && [ -s '$T2/usr/share/sddm/themes/Colloid-dark/background.jpg' ]"
chk "the login screen offers no Sleep and no Other user, and its field placeholder is visible" \
  "! grep -q 'sddm.suspend()' '$T2/usr/share/sddm/themes/Colloid-dark/Main.qml' && ! grep -q '\"Other…\"' '$T2/usr/share/sddm/themes/Colloid-dark/Main.qml' && grep -q 'placeholderTextColor: \"#8b8d93\"' '$T2/usr/share/sddm/themes/Colloid-dark/Input.qml'"
chk "window buttons rest as quiet slate dots and take the palette colours only on hover" \
  "for b in close minimize maximize; do grep -q '3a3e52' '$T2'/usr/share/aurorae/themes/Colloid-dark/\$b.svg || exit 1; done && ! grep -q 'fd5f51\|fdbe04\|38c76a' '$T2'/usr/share/aurorae/themes/Colloid-dark/*.svg"
chk "the colour scheme carries no stock orange or grey leftovers" \
  "! grep -q '246,116,0\|222,222,222' '$T2/usr/share/color-schemes/ColloidDark.colors'"

echo "== single edition (one VM, gateway container inside) =="
XS="$TMP/x-single"
SO="$TMP/single-overlay"; GC="$TMP/gateway-container"; mkdir -p "$SO" "$GC"
( cd "$SO" && tar -xzf "$XS/ombra/single-rootfs.tar.gz" ) >/dev/null 2>&1
( cd "$GC" && tar -xzf "$XS/ombra/gateway-container.tar.gz" ) >/dev/null 2>&1
chk "the single ISO carries the edition marker, the three extra tarballs and the desktop payload (late.sh, overlay, pinned apps)" \
  "[ -e '$XS/ombra/edition-single' ] && [ -s '$XS/ombra/gateway-rootfs.tar.gz' ] && [ -s '$XS/ombra/gateway-container.tar.gz' ] && [ -s '$XS/ombra/single-rootfs.tar.gz' ] && cmp -s '$XS/ombra/late.sh' '$REPO/desktop/late-command.sh' && [ -s '$XS/ombra/rootfs.tar.gz' ] && ls '$XS'/ombra/vendor/tor-browser-linux-aarch64-*.tar.xz '$XS/ombra/vendor/feather.sha256' '$XS/ombra/vendor/simplex.sha256' >/dev/null 2>&1"
chk "the desktop and gateway ISOs carry no single marker and none of the single tarballs" \
  "( for t in gateway desktop; do for m in edition-single gateway-rootfs.tar.gz gateway-container.tar.gz single-rootfs.tar.gz; do [ ! -e '$TMP'/x-\$t/ombra/\$m ] || exit 1; done; done )"
# member listing without the date: the staged extra files (update key) are written at each build
tvlist() { awk '{ $6 = $7 = $8 = ""; print }' | sort; }
chk "the single ISO's desktop overlay is the desktop ISO's (same members, modes, sizes and link targets)" \
  "[ \"\$(tar -tvzf '$XS/ombra/rootfs.tar.gz' | tvlist)\" = \"\$(tar -tvzf '$TMP/x-desktop/ombra/rootfs.tar.gz' | tvlist)\" ]"
chk "the single ISO's gateway overlay is packed exactly as the gateway ISO packs it" \
  "[ \"\$(tar -tvzf '$XS/ombra/gateway-rootfs.tar.gz' | tvlist)\" = \"\$(tar -tvzf '$TMP/x-gateway/ombra/rootfs.tar.gz' | tvlist)\" ]"
chk "the gateway binaries drift guard covers the single target too" \
  "grep -q 'single) DRIFT_TREES=\"desktop gateway\"' '$MKI'"
SO_FILES="$(cd "$SO" && find . -type f | sort | tr '\n' ' ')"
chk "the single host overlay ships exactly its eight files" \
  "[ '$SO_FILES' = './etc/NetworkManager/conf.d/20-ombra-single.conf ./etc/NetworkManager/system-connections/ombra-intnet.nmconnection ./etc/nftables.conf ./etc/systemd/network/05-ombra-nic.link ./etc/systemd/system/ombra-gateway.service ./etc/udev/rules.d/86-ombra-gw.rules ./etc/udev/rules.d/90-ombra-hide-system-disk.rules ./usr/local/sbin/ombra-gateway-run ' ]"
for f in ./etc/systemd/system/ombra-gateway.service ./usr/local/sbin/ombra-gateway-run ./etc/systemd/network/05-ombra-nic.link \
         ./etc/udev/rules.d/86-ombra-gw.rules ./etc/NetworkManager/conf.d/20-ombra-single.conf; do
  chk "the two-VM desktop overlay does not carry the single edition's $f" "[ ! -e '$T2/$f' ]"
done
GU="$SO/etc/systemd/system/ombra-gateway.service"
chk "ombra-gateway.service: our own notify unit, run script, Requires+After the ombra-nic device, never Before=NetworkManager" \
  "grep -qx 'ExecStart=/usr/local/sbin/ombra-gateway-run' '$GU' && grep -qxF 'Requires=sys-subsystem-net-devices-ombra\\x2dnic.device' '$GU' && grep -qxF 'After=sys-subsystem-net-devices-ombra\\x2dnic.device' '$GU' && ! grep -q '^Before=.*NetworkManager' '$GU' && grep -qx 'Type=notify' '$GU' && grep -qx 'NotifyAccess=all' '$GU' && grep -qx 'KillMode=mixed' '$GU' && grep -qx 'Delegate=yes' '$GU' && grep -qx 'MemoryMax=768M' '$GU' && grep -qx 'TasksMax=512' '$GU' &&  grep -qx 'RequiresMountsFor=/var/lib/ombra' '$GU' && grep -qx 'Slice=machine.slice' '$GU' && grep -qx 'WantedBy=multi-user.target' '$GU' && grep -q '^After=.*nftables.service' '$GU'"
GR="$SO/usr/local/sbin/ombra-gateway-run"
chk "ombra-gateway-run: executable, parses, boots the hashed image read-only with a RAM overlay, own user namespace, private network and the two interfaces" \
  "[ -x '$GR' ] && sh -n '$GR' && grep -qF -- '--image=\"\$IMG\" --read-only --volatile=overlay -U' '$GR' && grep -qF -- '--private-network --network-interface=ombra-nic:ombra-upstream --network-veth-extra=ombra-gw:ombra-intnet' '$GR' && grep -qF -- '--resolv-conf=off --timezone=off --link-journal=no' '$GR' && grep -qF 'sha256sum \"\$IMG\"' '$GR' && grep -q 'does not match the hash recorded at install' '$GR' && grep -qx 'SUM=/usr/share/ombra/gateway.img.sha256' '$GR'"
chk "ombra-gateway-run: the idmapped Tor-state bind exists only inside the non-overlay-root branch (Persistent), under the root-only state dir" \
  "grep -qx 'TOR_STATE=/var/lib/ombra/gateway-state/tor' '$GR' && awk '/^[[:space:]]*#/ {next} index(\$0, \"findmnt -n -o FSTYPE /)\\\" != overlay ]; then\") {inb=1; next} inb && \$0 == \"fi\" {inb=0} index(\$0, \"idmap\") {if (inb) i++; else o++} END {exit !(i==1 && o==0)}' '$GR'"
SN="$SO/etc/NetworkManager/system-connections/ombra-intnet.nmconnection"
chk "the single intnet profile is bound to the veth by name with the two-VM addressing" \
  "grep -qx 'interface-name=ombra-gw' '$SN' && grep -qx 'address1=10.55.10.100/24,10.55.10.1' '$SN' && grep -qx 'dns=10.55.10.1;' '$SN' && grep -qx 'method=disabled' '$SN'"
chk "the VM's NIC is renamed by driver and left unmanaged by NM; the veth is managed" \
  "grep -qx 'Driver=vmxnet3 e1000e virtio_net' '$SO/etc/systemd/network/05-ombra-nic.link' && grep -qx 'Name=ombra-nic' '$SO/etc/systemd/network/05-ombra-nic.link' && grep -qx 'unmanaged-devices=interface-name:ombra-nic' '$SO/etc/NetworkManager/conf.d/20-ombra-single.conf' && grep -qF 'KERNEL==\"ombra-gw\", ENV{NM_UNMANAGED}=\"0\"' '$SO/etc/udev/rules.d/86-ombra-gw.rules'"
GCN="$REPO/gateway/container/etc/systemd/network"
chk "gateway/container network files match by name (never by driver), DHCP upstream, static intnet that comes up without carrier" \
  "grep -qx 'Name=ombra-upstream' '$GCN/10-upstream.network' && grep -qx 'DHCP=yes' '$GCN/10-upstream.network' && grep -qx 'SendHostname=no' '$GCN/10-upstream.network' && grep -qx 'UseDNS=false' '$GCN/10-upstream.network' && grep -qx 'UseNTP=false' '$GCN/10-upstream.network' && grep -qx 'Name=ombra-intnet' '$GCN/20-intnet.network' && grep -qx 'Address=10.55.10.1/24' '$GCN/20-intnet.network' && grep -qx 'ConfigureWithoutCarrier=yes' '$GCN/20-intnet.network' && ! grep -q '^Driver=' '$GCN'/*.network && ! grep -q '#' '$GCN'/*.network && [ \"\$(grep -c '^LinkLocalAddressing=no\$' '$GCN'/*.network | grep -c ':1\$')\" = 2 ]"
chk "the container overlay tarball carries exactly the two network files (its README stays in the repo)" \
  "[ \"\$(cd '$GC' && find . -type f | sort | tr '\n' ' ')\" = './etc/systemd/network/10-upstream.network ./etc/systemd/network/20-intnet.network ' ]"
SINGLE_SEC="$(awk '/^if \[ -e \/ombra\/edition-single \]; then$/ {s=1} s {print} s && /^else$/ {exit}' "$LC")"
SINGLE_TAIL="$(printf '%s\n' "$SINGLE_SEC" | grep -v '^else$' | grep -v '^[[:space:]]*$' | tail -2)"
chk "late-command's single section is guarded by the marker and ends in the wants-symlink assertion" \
  "[ -n \"\$SINGLE_SEC\" ] && printf '%s\n' \"\$SINGLE_TAIL\" | head -1 | grep -qF '[ -L /target/etc/systemd/system/multi-user.target.wants/ombra-gateway.service ]' && printf '%s\n' \"\$SINGLE_TAIL\" | tail -1 | grep -q 'ombra_fatal'"
chk "the single section's work never leaks outside the marker guard" \
  "[ \"\$(grep -c 'single-rootfs.tar.gz\\|gateway-container.tar.gz\\|mmdebstrap --mode\\|ombra-gateway.service' '$LC')\" = \"\$(printf '%s\n' \"\$SINGLE_SEC\" | grep -c 'single-rootfs.tar.gz\\|gateway-container.tar.gz\\|mmdebstrap --mode\\|ombra-gateway.service')\" ]"
chk "the single section builds a minbase container from the three trixie suites, without a proxy, and parks on failure" \
  "printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'exec mmdebstrap --mode=root --variant=minbase' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'trixie-security' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'trixie-updates' && ! printf '%s\n' \"\$SINGLE_SEC\" | grep -v '^[[:space:]]*#' | grep -qi 'proxy' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'mmdebstrap could not build'"
chk "the single section builds the ext4 image as the prototype did, hashes it and drops the tree" \
  "printf '%s\n' \"\$SINGLE_SEC\" | grep -qF 'mke2fs -q -t ext4 -L ombra-gw -m 0 -E root_owner=0:0 -d \"\$GW_TREE\" \"\$GW_IMG\"' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'usr/share/ombra/gateway.img.sha256' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'under 100 MB' && printf '%s\n' \"\$SINGLE_SEC\" | grep -q 'rm -rf \"\$GWT\"'"
chk "the single section masks remount-fs and the consoles, enables the gateway units, and checks nftables.conf and torrc against the gateway overlay" \
  "( for w in systemd-remount-fs.service console-getty.service systemd-logind.service ombra-torctl-filter.service 'etc/nftables.conf etc/tor/torrc' 'visudo -c' gateway-packages.txt 'GW_STATE=/var/lib/ombra/gateway-state' 'chmod 2700'; do printf '%s\n' \"\$SINGLE_SEC\" | grep -qF \"\$w\" || exit 1; done )"
chk "two-VM builds record their edition (desktop else-branch, gateway after the overlay unpack)" \
  "grep -A1 '^else\$' '$LC' | grep -q \"printf 'two-vm\" && grep -q \"printf 'two-vm\\\\\\\\n' > /target/etc/ombra/edition\" '$REPO/gateway/late-command.sh'"
chk "the desktop sysctl IPv6 keys tolerate ipv6.disable=1 (the '-' prefix, as on the gateway)" \
  "grep -qx -- '-net.ipv6.conf.all.disable_ipv6 = 1' '$REPO/desktop/rootfs/etc/sysctl.d/60-ombra-desktop.conf' && ! grep -q '^net.ipv6' '$REPO/desktop/rootfs/etc/sysctl.d/60-ombra-desktop.conf'"
chk "the single edition ships only as its ISO: no exporter or verifier takes it; the test-VM scripts still make it (one NAT NIC)" \
  "for f in fusion/export-bundle.sh fusion/verify-bundle.sh utm/export-bundle.sh utm/verify-bundle.sh; do ! grep -q 'desktop|gateway|single' '$REPO/build/'\$f && ! grep -q '^ *\\*single\\*)' '$REPO/build/'\$f && ! grep -q 'target == \"single\"' '$REPO/build/'\$f || exit 1; done && grep -q 'case \"\$TARGET\" in desktop|gateway) ;;' '$REPO/build/fusion/export-bundle.sh' && grep -q 'vmx_set ethernet0.connectionType nat' '$REPO/build/fusion/post-install-desktop.sh' && grep -q '^  single) VM_NAME=ombra-single;' '$REPO/build/fusion/create-desktop-vm.sh' && grep -q '^  single) VM_NAME=ombra-single ;;' '$REPO/build/fusion/post-install-desktop.sh'"

echo "== /home on its own logical volume =="
RECIPE_CHECK='
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^d-i partman-auto/expert_recipe string(.*?)\n\n", text, re.S | re.M)
recipe = re.sub(r"\\\n", " ", m.group(1))
blocks = [b.split() for b in recipe.split(" . ")]
lvs = {}
for b in blocks:
    j = " ".join(b)
    n = re.search(r"lv_name\{ (\w+) \}", j)
    if n:
        nums = [x for x in b if re.fullmatch(r"-?\d+", x)]
        lvs[n.group(1)] = (int(nums[-3]), int(nums[-2]), int(nums[-1]), j)
assert set(lvs) == {"root", "home", "swap"}, lvs.keys()
r, h, s = lvs["root"], lvs["home"], lvs["swap"]
assert r[0] == r[2] and 10000 <= r[0] <= 14000 and "mountpoint{ / }" in r[3], r
assert s[0] == s[2] == 4096 and "method{ swap }" in s[3], s
assert h[2] == -1 and h[1] > h[0] and "mountpoint{ /home }" in h[3] and "filesystem{ ext4 }" in h[3], h
g = re.search(r"^d-i partman-auto-lvm/guided_size string (\d+)%$", text, re.M)
pct = int(g.group(1))
vg = 30 * 1024**3 / 1e6 - 512 - 1024 - 32
used = vg * pct / 100
assert used - r[0] - s[0] >= 6000, "home would get under 6 GB"
assert (vg - used) * 1e6 >= 3 * 1024**3, "under 3 GiB left for the update snapshot"
print("root %d MB fixed, swap %d MB, home ~%d MB, %.1f GB free in vg0" % (r[0], s[0], used - r[0] - s[0], (vg - used) / 1000))
'
if python3 -c "$RECIPE_CHECK" "$REPO/desktop/preseed.cfg"; then
  ok "partman recipe: fixed root, swap as before, /home LV takes the rest, 3 GiB still free for the root snapshot"
else
  bad "partman recipe: /home is not its own LV, root is not fixed, or the snapshot space is gone"
fi
chk "late-command parks unless /home is a separate mount in the target fstab and mounted in the installer" \
  "grep -qF '!/^#/ && \$2==\"/home\" {f=1}' '$LC' && grep -q '/home is not a separate mount' '$LC' && grep -qF '\$2==\"/target/home\"' '$LC'"
chk "kact-wipe waits for the /home mount (RequiresMountsFor), keeping its no-default-dependencies ordering" \
  "grep -qx 'RequiresMountsFor=/home/ombra' '$REPO/desktop/rootfs/etc/systemd/system/kact-wipe.service' && grep -qx 'After=home.mount systemd-remount-fs.service' '$REPO/desktop/rootfs/etc/systemd/system/kact-wipe.service'"

echo "== single edition: the end user's installer ISO =="
SP="$TMP/x-single/preseed.cfg"
DP="$REPO/desktop/preseed.cfg"
# the only keys the single preseed may drop from or change against desktop/preseed.cfg, and the only ones it adds
SINGLE_PRESEED_CHECK='
import re, sys
exempt = {"partman-crypto/passphrase", "partman-crypto/passphrase-again", "passwd/user-password-crypted",
          "partman-auto/disk", "partman-crypto/weak_passphrase", "debian-installer/exit/poweroff"}
added = {"partman/early_command", "cdrom-detect/eject"}
def lines(path, drop):
    out = []
    for l in open(path).read().split("\n"):
        if l.startswith("#"):
            continue
        f = l.split()
        if len(f) >= 2 and f[1] in drop and not l.startswith((" ", "\t")):
            continue
        out.append(l)
    while out and out[-1] == "":
        out.pop()
    return out
d = lines(sys.argv[1], exempt)
s = lines(sys.argv[2], exempt | added)
assert d == s, "\n".join(x for x in set(d) ^ set(s))[:2000]
'
chk "every desktop preseed line that is not exempt is in the single preseed unchanged, in order (no drift)" \
  "python3 -c '$SINGLE_PRESEED_CHECK' '$DP' '$SP'"
chk "the single preseed asks the disk passphrase and the account password (their keys are absent) and pins no disk" \
  "! grep -qE '^[^#]*(partman-crypto/passphrase|passwd/user-password-crypted|partman-auto/disk)' '$SP'"
chk "the single preseed carries no secret: no build passphrase, no password hash, no test value" \
  "! grep -q 'ombra-disk' '$SP' && ! grep -q 'ombra-test-disk' '$SP' && ! grep -qE '\\\$(1|5|6|y|2[aby])\\\$' '$SP' && [ ! -e '$TMP/x-single/ombra/test-build' ]"
chk "the single preseed keeps the user name fixed, root login off, root locked and the account out of sudo (default groups)" \
  "grep -qx 'd-i passwd/username string ombra' '$SP' && grep -qx 'd-i passwd/user-fullname string ombra' '$SP' && grep -qx 'd-i passwd/root-login boolean false' '$SP' && grep -qx 'd-i passwd/root-password-crypted string \\*' '$SP' && grep -qx 'd-i passwd/user-default-groups string audio video' '$SP'"
chk "the single preseed re-asks a passphrase under 8 characters (the unlock screen's minimum), uses a 512-bit key and keeps the US keyboard" \
  "grep -qx 'd-i partman-crypto/weak_passphrase boolean false' '$SP' && ! grep -q 'partman-crypto/keysize' '$SP' && grep -qx 'd-i keyboard-configuration/xkb-keymap select us' '$SP' && grep -qx 'd-i debian-installer/keymap select us' '$SP'"
chk "the single preseed picks the disk in partman's early command, ejects the CD, leaves netcfg's profile out and REBOOTS" \
  "grep -qx 'd-i partman/early_command string sh /ombra/early.sh' '$SP' && grep -qx 'd-i cdrom-detect/eject boolean true' '$SP' && grep -qx 'd-i netcfg/target_network_config select loopback' '$SP' && grep -qx 'd-i debian-installer/exit/poweroff boolean false' '$SP' && grep -qx 'd-i finish-install/reboot_in_progress note' '$SP'"
chk "the two-VM desktop still powers off (the build host post-processes it)" \
  "grep -qx 'd-i debian-installer/exit/poweroff boolean true' '$TMP/x-desktop/preseed.cfg'"
if python3 -c "$RECIPE_CHECK" "$SP" >/dev/null 2>&1; then ok "the single preseed carries the same LUKS + LVM recipe (root, swap, home, snapshot space)"; else bad "the single preseed's partman recipe is broken"; fi
chk "the single ISO carries the early check (executable) and its dialog template; the two-VM ISOs carry neither" \
  "[ -x '$TMP/x-single/ombra/early.sh' ] && cmp -s '$TMP/x-single/ombra/early.sh' '$REPO/build/single-iso/early.sh' && cmp -s '$TMP/x-single/var/lib/dpkg/info/ombra-single.templates' '$REPO/build/single-iso/ombra-single.templates' && for t in gateway desktop; do [ ! -e '$TMP'/x-\$t/ombra/early.sh ] && [ ! -e '$TMP'/x-\$t/var/lib/dpkg/info/ombra-single.templates ] || exit 1; done"
chk "the early check and the release script parse (sh, dash, bash)" \
  "sh -n '$REPO/build/single-iso/early.sh' && dash -n '$REPO/build/single-iso/early.sh' && bash -n '$REPO/build/release-single-iso.sh'"
chk "the dialog template is an error at critical priority use, with the reason substituted" \
  "grep -qx 'Template: ombra/vm-too-small' '$REPO/build/single-iso/ombra-single.templates' && grep -qx 'Type: error' '$REPO/build/single-iso/ombra-single.templates' && grep -q '\${REASON}' '$REPO/build/single-iso/ombra-single.templates' && grep -q 'db_input critical ombra/vm-too-small' '$REPO/build/single-iso/early.sh'"

# the early check, run for real against stubs: debconf, list-devices, mount, /proc/meminfo and /sys/block
EA="$TMP/early"; mkdir -p "$EA/bin"
cat > "$EA/confmodule" <<'STUB'
db_fset() { :; }
db_subst() { printf '%s\n' "$3" > "$EA/reason"; }
db_input() { return 0; }
db_go() { exit 9; }
db_set() { printf '%s=%s\n' "$1" "$2" > "$EA/set"; }
STUB
printf '#!/bin/sh\nexit 0\n' > "$EA/bin/chvt"
sed -e "s#/usr/share/debconf/confmodule#$EA/confmodule#" -e "s#/proc/meminfo#$EA/meminfo#" -e "s#/sys/block/#$EA/sys/#" \
  "$REPO/build/single-iso/early.sh" > "$EA/early.sh"
early_run() { # <MemTotal kB> <disks> <cdrom source or -> <sectors per disk ...>: the exit code; $EA/set and $EA/reason
  local mem="$1" disks="$2" cd="$3"; shift 3
  rm -rf "$EA/sys" "$EA/set" "$EA/reason"; mkdir -p "$EA/sys"
  printf 'MemTotal:       %s kB\nMemFree:        1000 kB\n' "$mem" > "$EA/meminfo"
  printf '#!/bin/sh\nfor d in %s; do echo "$d"; done\n' "$disks" > "$EA/bin/list-devices"
  if [ "$cd" = - ]; then printf '#!/bin/sh\necho "proc on /proc type proc (rw)"\n' > "$EA/bin/mount"
  else printf '#!/bin/sh\necho "%s on /cdrom type iso9660 (ro)"\n' "$cd" > "$EA/bin/mount"; fi
  chmod +x "$EA/bin/"*
  for d in $disks; do mkdir -p "$EA/sys/${d#/dev/}"; printf '%s\n' "$1" > "$EA/sys/${d#/dev/}/size"; shift; done
  EA="$EA" PATH="$EA/bin:$PATH" sh "$EA/early.sh" >/dev/null 2>&1
}
early_run 6000000 "/dev/nvme0n1" - 62914560; rc=$?
chk "early check: a 30 GB NVMe disk and 6 GB pass, and the disk is handed to partman" "[ $rc = 0 ] && grep -qx 'partman-auto/disk=/dev/nvme0n1' '$EA/set'"
early_run 2900000 "/dev/vda /dev/vdb" /dev/vda 1400000 62914560; rc=$?
chk "early check: the install medium attached as a virtio disk is skipped (UTM), and a 3 GB VM passes" "[ $rc = 0 ] && grep -qx 'partman-auto/disk=/dev/vdb' '$EA/set'"
early_run 6000000 "/dev/vda" - 41943040; rc=$?
chk "early check: a 21 GB disk stops the install with the reason, before partman" "[ $rc = 9 ] && [ ! -e '$EA/set' ] && grep -q 'needs at least 24 GB' '$EA/reason'"
early_run 1950000 "/dev/vda" - 62914560; rc=$?
chk "early check: a 2 GB VM stops the install with the reason" "[ $rc = 9 ] && [ ! -e '$EA/set' ] && grep -q 'needs at least 3 GB' '$EA/reason'"
early_run 6000000 "/dev/sr0" /dev/sr0 1400000; rc=$?
chk "early check: no disk besides the install medium stops the install" "[ $rc = 9 ] && grep -q 'found no disk' '$EA/reason'"

xorriso -osirrox on -indev "$REPO/build/disks/ombra-install-single.iso" -extract /boot/grub/grub.cfg "$TMP/gs.cfg" >/dev/null 2>&1
xorriso -osirrox on -indev "$REPO/build/disks/ombra-install-desktop.iso" -extract /boot/grub/grub.cfg "$TMP/gd.cfg" >/dev/null 2>&1
chk "the single ISO boots its own entry: 'Install Ombra (single VM)', a short timeout, the two-VM kernel line, nothing to type" \
  "cmp -s '$TMP/gs.cfg' '$REPO/build/installer-grub-single.cfg' && grep -q 'menuentry \"Install Ombra (single VM)\"' '$TMP/gs.cfg' && grep -qx 'set timeout=3' '$TMP/gs.cfg' && [ \"\$(grep '^ *linux ' '$TMP/gs.cfg')\" = \"\$(grep '^ *linux ' '$REPO/build/installer-grub.cfg')\" ] && grep -q 'auto=true priority=critical' '$TMP/gs.cfg'"
chk "the gateway and desktop ISOs keep the unattended entry" \
  "cmp -s '$TMP/gd.cfg' '$REPO/build/installer-grub.cfg' && cmp -s '$TMP/g.cfg' '$REPO/build/installer-grub.cfg'"
xorriso -osirrox on -indev "$REPO/build/disks/ombra-install-single.iso" -extract /README.txt "$TMP/readme-single.txt" >/dev/null 2>&1
xorriso -osirrox on -indev "$REPO/build/disks/ombra-install-desktop.iso" -extract /README.txt "$TMP/readme-desktop.txt" >/dev/null 2>&1
chk "the single ISO's root README.txt is Ombra's (requirements and the three steps); the desktop ISO keeps Debian's" \
  "cmp -s '$TMP/readme-single.txt' '$REPO/build/single-iso/README.txt' && grep -q 'THREE STEPS' '$TMP/readme-single.txt' && grep -q 'Apple Silicon' '$TMP/readme-single.txt' && grep -q 'NAT' '$TMP/readme-single.txt' && ! grep -q 'THREE STEPS' '$TMP/readme-desktop.txt'"

# a TEST single ISO (never distributed) stays unattended; built into a scratch directory, never over build/disks
TI="$TMP/testiso"; mkdir -p "$TI"
disks_state() { ls -l "$REPO/build/disks/" 2>/dev/null; }
DISKS_BEFORE="$(disks_state)"
if OMBRA_ISO_OUT="$TI" OMBRA_TEST_GUEST_PASSWORD=test-guest-pw bash "$REPO/build/make-install-iso.sh" single > "$TMP/build-single-test.log" 2>&1; then
  ok "TEST single ISO built (into a scratch directory)"
  xorriso -osirrox on -indev "$TI/ombra-install-single-test.iso" -extract /install.a64/initrd.gz "$TMP/st.gz" >/dev/null 2>&1
  CGZ=$(( $(stat -f %z "$TMP/st.gz") - STOCK )); tail -c "$CGZ" "$TMP/st.gz" > "$TMP/st.seg"; mkdir -p "$TMP/x-st"
  ( cd "$TMP/x-st" && gzip -dc "$TMP/st.seg" | cpio -id --quiet ) >/dev/null 2>&1
  TP="$TMP/x-st/preseed.cfg"
  chk "TEST single: disk passphrase preseeded twice from the default ombra-test-disk, the account hash set, unattended" \
    "grep -qx 'd-i partman-crypto/passphrase password ombra-test-disk' '$TP' && grep -qx 'd-i partman-crypto/passphrase-again password ombra-test-disk' '$TP' && grep -qE '^d-i passwd/user-password-crypted string \\\$6\\\$' '$TP' && ! grep -q 'ombra-disk\$' '$TP'"
  chk "TEST single: powers off at the end, carries the test marker and the wider agent allowlist" \
    "grep -qx 'd-i debian-installer/exit/poweroff boolean true' '$TP' && [ -e '$TMP/x-st/ombra/test-build' ] && [ -e '$TMP/x-st/ombra/edition-single' ]"
  chk "TEST single: every other line equals the end-user single preseed" \
    "[ \"\$(grep -vE '^d-i (partman-crypto/passphrase|partman-crypto/passphrase-again|passwd/user-password-crypted|passwd/root-login|passwd/root-password-crypted|debian-installer/exit/poweroff) ' '$TP')\" = \"\$(grep -vE '^d-i (passwd/root-login|passwd/root-password-crypted|debian-installer/exit/poweroff) ' '$SP')\" ]"
  chk "the TEST build wrote nothing into build/disks (OMBRA_ISO_OUT)" "[ \"\$(disks_state)\" = \"\$DISKS_BEFORE\" ]"
else
  bad "TEST single ISO build failed:"; sed 's/^/       /' "$TMP/build-single-test.log" | tail -5
fi
for p in ombra-disk short1 'has space'; do
  if OMBRA_ISO_OUT="$TI/refused" OMBRA_TEST_DISK_PASSPHRASE="$p" OMBRA_TEST_GUEST_PASSWORD=x bash "$REPO/build/make-install-iso.sh" single > "$TMP/refuse.log" 2>&1; then
    bad "a TEST single build accepted the disk passphrase '$p'"
  else
    grep -q 'OMBRA_TEST_DISK_PASSPHRASE' "$TMP/refuse.log" && ok "a TEST single build refuses the disk passphrase '$p'" || bad "a TEST single build failed on '$p' for another reason"
  fi
done

SN2="$REPO/desktop/single/etc/nftables.conf"
chk "single firewall: the desktop ruleset with only the three gateway rules bound to ombra-gw (comments aside)" \
  "[ \"\$(grep -v '^ *#' '$REPO/desktop/rootfs/etc/nftables.conf')\" = \"\$(grep -v '^ *#' '$SN2' | sed -E 's/^( *)(oifname|iifname) \"ombra-gw\" /\\1/')\" ] && [ \"\$(grep -c '^    oifname \"ombra-gw\" ip daddr 10.55.10.1 counter accept\$' '$SN2')\" = 1 ] && [ \"\$(grep -c '^    iifname \"ombra-gw\" ip saddr 10.55.10.1 ' '$SN2')\" = 2 ] && [ \"\$(grep -v '^ *#' '$SN2' | grep -c '\"ombra-gw\"')\" = 3 ]"
chk "single firewall: the ISO's host overlay carries it, and late-command checks it landed" \
  "cmp -s '$SO/etc/nftables.conf' '$SN2' && grep -qF 'ifname \"ombra-gw\" ip [sd]addr 10.55.10.1 ' '$LC'"
chk "the system disk is hidden from the file manager whether it is NVMe (Fusion) or virtio (UTM)" \
  "grep -qx 'KERNEL==\"vd\[a-z\]\*\", ENV{UDISKS_IGNORE}=\"1\"' '$SO/etc/udev/rules.d/90-ombra-hide-system-disk.rules' && grep -qx 'KERNEL==\"nvme\[0-9\]\*\", ENV{UDISKS_IGNORE}=\"1\"' '$SO/etc/udev/rules.d/90-ombra-hide-system-disk.rules'"

GR2="$REPO/desktop/single/usr/local/sbin/ombra-gateway-run"
chk "ombra-gateway-run: no-new-privileges and the capability drop are separate argument lines, each commented" \
  "grep -qx 'set -- \"\$@\" --no-new-privileges=yes' '$GR2' && grep -qx 'set -- \"\$@\" --drop-capability=CAP_SYS_PTRACE,CAP_SYS_BOOT,CAP_AUDIT_CONTROL,CAP_AUDIT_WRITE,CAP_MKNOD,CAP_SYS_TTY_CONFIG,CAP_LINUX_IMMUTABLE,CAP_IPC_OWNER' '$GR2' && grep -B1 -- '--no-new-privileges=yes' '$GR2' | head -1 | grep -q '^#' && grep -q 'CAP_SYS_NICE and CAP_SYS_RESOURCE stay' '$GR2' && grep -q '\"\$@\" --machine=ombra-gateway' '$GR2'"
chk "ombra-gateway-run: the capability drop never names a capability systemd or networkd needs" \
  "! grep -- '--drop-capability' '$GR2' | grep -qE 'CAP_(SYS_ADMIN|NET_ADMIN|NET_BIND_SERVICE|NET_RAW|SETUID|SETGID|SETPCAP|CHOWN|DAC_OVERRIDE|DAC_READ_SEARCH|FOWNER|KILL|SYS_CHROOT|SYS_NICE|SYS_RESOURCE)'"
chk "ombra-gateway.service: no device policy (measured: any DevicePolicy makes nspawn fail to shift the image's uids), memory and task limits" \
  "! grep -qE '^(DevicePolicy|DeviceAllow)=' '$SO/etc/systemd/system/ombra-gateway.service' && grep -q 'Failed to adjust' '$SO/etc/systemd/system/ombra-gateway.service' && grep -qx 'MemoryMax=768M' '$SO/etc/systemd/system/ombra-gateway.service' && grep -qx 'TasksMax=512' '$SO/etc/systemd/system/ombra-gateway.service'"

echo "== single edition: late-command for a disk sealed from the start =="
chk "late-command keys the single steps on the edition marker" \
  "grep -qx '\\[ ! -e /ombra/edition-single \\] || SINGLE=1' '$LC'"
LUKS_AWK="$(grep -F 'END {exit !(v == 2' "$LC" | sed -E "s/^ *awk '//; s/' \/target\/var\/tmp\/ombra-luksdump.txt.*\$//")"
luks_fixture() { # <version> <segment cipher> <key bits> <pbkdf> <keyslots>
  printf 'LUKS header information\nVersion:       \t%s\nEpoch:         \t3\nUUID:          \t1234\n\nData segments:\n  0: crypt\n\toffset: 16777216 [bytes]\n\tlength: (whole device)\n\tcipher: %s\n\tsector: 512 [bytes]\n\nKeyslots:\n' "$1" "$2"
  i=0; while [ "$i" -lt "$5" ]; do
    printf '  %s: luks2\n\tKey:        %s bits\n\tPriority:   normal\n\tCipher:     aes-xts-plain64\n\tCipher key: 512 bits\n\tPBKDF:      %s\n\tTime cost:  4\n\tMemory:     1048576\n\tThreads:    4\n\tSalt:       aa bb\n\t            cc dd\n\tAF stripes: 4000\n\tAF hash:    sha256\n\tDigest ID:  0\n' "$i" "$3" "$4"
    i=$((i + 1))
  done
  printf 'Tokens:\nDigests:\n  0: pbkdf2\n\tHash:       sha256\n\tIterations: 129774\n\tSalt:       ee ff\n\tDigest:     00 11\n'
}
luks_ok() { luks_fixture "$@" > "$TMP/dump.txt"; awk "$LUKS_AWK" "$TMP/dump.txt"; }
chk "LUKS check: accepts LUKS2, aes-xts-plain64, one argon2id keyslot with a 512-bit key" "[ -n \"\$LUKS_AWK\" ] && luks_ok 2 aes-xts-plain64 512 argon2id 1"
chk "LUKS check: refuses a 256-bit key (d-i's default)" "! luks_ok 2 aes-xts-plain64 256 argon2id 1"
chk "LUKS check: refuses pbkdf2, LUKS1, another cipher, a second keyslot" \
  "! luks_ok 2 aes-xts-plain64 512 pbkdf2 1 && ! luks_ok 1 aes-xts-plain64 512 argon2id 1 && ! luks_ok 2 aes-cbc-essiv:sha256 512 argon2id 1 && ! luks_ok 2 aes-xts-plain64 512 argon2id 2"
chk "late-command parks unless cryptsetup says exit 2 (no key matches) for the public build passphrase, with and without a newline" \
  "grep -qF 'printf \"ombra-disk\$2\" | cryptsetup open --test-passphrase --key-file - \"\$1\"' '$LC' && grep -qF '[ \"\$rc\" = 2 ] || ombra_fatal' '$LC' && grep -q 'the disk passphrase is Ombra.s public build passphrase' '$LC'"
PG_AWK="$(grep -F 'priv_groups="$(awk -F:' "$LC" | sed -e "s/^ *priv_groups=\"\$(awk -F: '//" -e "s#' /target/etc/group)\"\$##")"
printf 'root:x:0:\nsudo:x:27:\naudio:x:29:ombra\nusers:x:100:ombra\nvideo:x:44:ombra\n' > "$TMP/group-ok"
printf 'root:x:0:\nsudo:x:27:bob,ombra\naudio:x:29:ombra\n' > "$TMP/group-sudo"
printf 'adm:x:4:ombra\n' > "$TMP/group-adm"
chk "account check: audio, video and users pass; sudo and adm are caught" \
  "[ -n \"\$PG_AWK\" ] && [ -z \"\$(awk -F: \"\$PG_AWK\" '$TMP/group-ok')\" ] && [ \"\$(awk -F: \"\$PG_AWK\" '$TMP/group-sudo')\" = sudo ] && [ \"\$(awk -F: \"\$PG_AWK\" '$TMP/group-adm')\" = adm ]"
chk "late-command (single) parks unless the account has a real hash, root is locked (release builds) and no privileged group" \
  "grep -q 'the account ombra has no password hash, or is locked' '$LC' && grep -q 'root has a usable password' '$LC' && grep -q 'ombra is in a privileged group' '$LC'"
chk "single: the first-use unit is removed and masked, the setup gate and the SDDM gate stay; two-VM enables all four as before" \
  "grep -q 'in-target systemctl mask ombra-welcome.service' '$LC' && grep -q 'ombra-welcome.service is not masked' '$LC' && grep -q '^in-target systemctl enable ombra-setup-gate.service ombra-askpass.service ombra-askpass-fallback.service' '$LC' && grep -q '^in-target systemctl enable ombra-setup-gate.service ombra-welcome.service ombra-askpass.service ombra-askpass-fallback.service' '$LC' && grep -q 'sddm first-use gate drop-in missing' '$LC'"
chk "single: the guest closes VMware shared folders (client deleted, dpkg-excluded) and the UTM clipboard (session agent never executable)" \
  "grep -qF 'path-exclude=/usr/*bin/vmhgfs-fuse' '$LC' && grep -q 'the VMware shared-folder client is still present' '$LC' && grep -qF 'dpkg-statoverride --update --add root root 0644 /usr/bin/spice-vdagent' '$LC' && grep -q 'spice-vdagent is still executable' '$LC'"
chk "both editions ship /etc/resolv.conf naming only the gateway (not the installer's NAT resolver)" \
  "grep -qF \"printf 'nameserver 10.55.10.1\\\\n' > /target/etc/resolv.conf\" '$LC' && grep -q 'the installer.s NAT resolver would ship' '$LC'"
chk "single: the gateway image and its hash are made immutable at the end, and checked" \
  "grep -qF 'chroot /target chattr +i /var/lib/ombra/gateway.img /usr/share/ombra/gateway.img.sha256' '$LC' && grep -q 'is not immutable' '$LC' && [ \"\$(grep -n 'chattr +i /var/lib/ombra/gateway.img' '$LC' | cut -d: -f1)\" -lt \"\$(grep -n '^touch /target/var/lib/ombra/late-ran' '$LC' | cut -d: -f1)\" ]"
for f in "$LC" "$REPO/desktop/single/usr/local/sbin/ombra-gateway-run" "$REPO/build/single-iso/early.sh"; do
  chk "dash -n $(basename "$f")" "dash -n '$f'"
done

echo "== single edition: release tooling =="
chk "scripts/build.sh --edition single stops after the ISO and says where it is (no VM is created)" \
  "grep -q '^finish_single()' '$REPO/scripts/build.sh' && ! grep -q 'build_single_vm' '$REPO/scripts/build.sh' && grep -q 'build/disks/ombra-install-single.iso' '$REPO/scripts/build.sh' && bash -n '$REPO/scripts/build.sh'"
chk "the VM exporters keep the single ISO's line when they rewrite SHA256SUMS.txt" \
  "grep -q 'ombra-\\*.vmwarevm.zip ombra-\\*.utm.zip ombra-\\*.iso' '$REPO/build/fusion/export-bundle.sh' && grep -q 'ombra-\\*.vmwarevm.zip ombra-\\*.utm.zip ombra-\\*.iso' '$REPO/build/utm/export-bundle.sh'"
# release-single-iso.sh against fixture ISOs (a real single ISO is never published by the tests)
RS="$TMP/release"; mkdir -p "$RS"
fake_iso() { # <out.iso> <volid> <extra member or -> <preseed line or ->
  local d="$RS/tree-$RANDOM"; mkdir -p "$d/root/install.a64" "$d/cpio/ombra"
  : > "$d/cpio/ombra/edition-single"
  printf 'd-i passwd/username string ombra\n' > "$d/cpio/preseed.cfg"
  [ "$3" = - ] || : > "$d/cpio/$3"
  [ "$4" = - ] || printf '%s\n' "$4" >> "$d/cpio/preseed.cfg"
  printf 'stock' | gzip > "$d/root/install.a64/initrd.gz"
  ( cd "$d/cpio" && find . | cpio -o -H newc --quiet | gzip ) >> "$d/root/install.a64/initrd.gz"
  xorriso -outdev "$1" -volid "$2" -map "$d/root" / >/dev/null 2>&1
}
rs_run() { OMBRA_RELEASE_DIR="$RS/out" OMBRA_VERSION=9.8.7 bash "$REPO/build/release-single-iso.sh" "$1" > "$RS/log" 2>&1; }
mkdir -p "$RS/out"; printf '%s  ombra-desktop-arm64-v9.8.7.utm.zip\n' "$(printf x | shasum -a 256 | cut -d' ' -f1)" > "$RS/out/SHA256SUMS.txt"
fake_iso "$RS/good.iso" Ombra-single-arm64 - -
chk "release script: a clean single ISO is copied as ombra-single-arm64-v<version>.iso and summed in the exporters' format" \
  "rs_run '$RS/good.iso' && cmp -s '$RS/good.iso' '$RS/out/ombra-single-arm64-v9.8.7.iso' && grep -qE '^[0-9a-f]{64}  ombra-single-arm64-v9.8.7.iso\$' '$RS/out/SHA256SUMS.txt' && grep -q 'ombra-desktop-arm64-v9.8.7.utm.zip' '$RS/out/SHA256SUMS.txt' && (cd '$RS/out' && shasum -a 256 -c SHA256SUMS.txt 2>/dev/null | grep -q 'ombra-single-arm64-v9.8.7.iso: OK')"
chk "release script: a second run replaces its line instead of adding one" \
  "rs_run '$RS/good.iso' && [ \"\$(grep -c 'ombra-single-arm64-v9.8.7.iso' '$RS/out/SHA256SUMS.txt')\" = 1 ] && [ \"\$(wc -l < '$RS/out/SHA256SUMS.txt' | tr -d ' ')\" = 2 ]"
fake_iso "$RS/marker.iso" Ombra-single-arm64 ombra/test-build -
chk "release script: a script that only mentions the marker path (as early.sh does) is not the marker" \
  "d=\$(mktemp -d) && mkdir -p \$d/root/install.a64 \$d/cpio/ombra && : > \$d/cpio/ombra/edition-single && printf 'd-i passwd/username string ombra\\n' > \$d/cpio/preseed.cfg && printf 'if [ ! -e /ombra/test-build ]; then\\n  : > /ombra/test-build\\nfi\\n' > \$d/cpio/ombra/early.sh && printf stock | gzip > \$d/root/install.a64/initrd.gz && (cd \$d/cpio && find . | cpio -o -H newc --quiet | gzip) >> \$d/root/install.a64/initrd.gz && xorriso -outdev '$RS/mention.iso' -volid Ombra-single-arm64 -map \$d/root / >/dev/null 2>&1 && rs_run '$RS/mention.iso'"
fake_iso "$RS/pass.iso" Ombra-single-arm64 - 'd-i partman-crypto/passphrase password ombra-test-disk'
fake_iso "$RS/hash.iso" Ombra-single-arm64 - 'd-i passwd/user-password-crypted string $6$abc$def'
fake_iso "$RS/desktop.iso" Ombra-desktop-arm64 - -
cp "$RS/good.iso" "$RS/ombra-install-single-test.iso"
chk "release script: refuses a TEST name, the test marker, a preseeded passphrase, a password hash and another edition's ISO" \
  "! rs_run '$RS/ombra-install-single-test.iso' && ! rs_run '$RS/marker.iso' && grep -q 'test-build marker' '$RS/log' && ! rs_run '$RS/pass.iso' && ! rs_run '$RS/hash.iso' && grep -q 'passphrase or a password hash' '$RS/log' && ! rs_run '$RS/desktop.iso' && grep -q 'not the single edition' '$RS/log'"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS test(s)"
  exit 1
fi

echo "ALL PASS"
