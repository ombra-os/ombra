#!/bin/sh
# lands the gateway overlay; delivery is redundant (preseed late_command AND the finish-install hook),
# both guarded by the late-ran stamp. The preseed carries only the bare path /ombra/late.sh (debconf eats \n escapes).

set -eu

# A FATAL must PARK the installer: the 08ombra hook wraps this script in `exit 0`, so a non-zero exit would silently ship.
ombra_fatal() {
    echo "FATAL: $1 — install PARKED, this machine must not be shipped" >&2
    db_set debian-installer/exit/poweroff false >/dev/null 2>&1 || true
    chvt 3 >/dev/null 2>&1 || true
    while :; do
        echo "FATAL: $1 — install parked ($(date +%H:%M:%S)); fix the failure and reinstall" > /dev/console 2>/dev/null || true
        sleep 60
    done
}

if [ -e /target/var/lib/ombra/late-ran ]; then
    echo "ombra late.sh: stamp present, already applied — skipping"
    exit 0
fi

mkdir -p /target/var/log /target/var/lib/ombra
exec >>/target/var/log/ombra-late.log 2>&1
echo "=== ombra late.sh $(date -u +%FT%TZ) ==="

phase() {
    printf '%s %s\n' "$(date +%T)" "$1"
    [ -c /dev/ttyAMA0 ] && printf '%s ombra-late %s\n' "$(date +%T)" "$1" > /dev/ttyAMA0 2>/dev/null
    return 0
}

phase "start"
# CD source off before any apt (the cdrom method blocks on the disc)
sed -i 's|^deb cdrom:|# deb cdrom:|' /target/etc/apt/sources.list
# no timeout on dpkg configure: a killed configure is corruption, not a stall guard
in-target dpkg --configure -a

# hostname repair pass (the preseed pins the same value)
echo ombra-gateway > /target/etc/hostname
sed -i '/^127\.0\.1\.1/d' /target/etc/hosts
printf '127.0.1.1\tombra-gateway.local\tombra-gateway\n' >> /target/etc/hosts

# fixed machine-id: one anonymity set shared by every install
printf '6f6d6272610000000000000000000002\n' > /target/etc/machine-id
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id

# identity: base-files owns /usr/lib/os-release and would re-Debian it on every upgrade; divert it.
# --rename must run BEFORE the overlay unpack below.
in-target dpkg-divert --add --rename --divert /usr/lib/os-release.distrib /usr/lib/os-release \
    || echo "WARN: os-release divert failed (a base-files upgrade may re-Debian the identity)"
# debian_version is a user-openable Debian version string: divert it away
in-target dpkg-divert --add --rename --divert /etc/debian_version.distrib /etc/debian_version \
    || echo "WARN: debian_version divert failed (a base-files upgrade may restore it)"
rm -f /target/etc/debian_version.distrib
# static motd: remove Debian's dynamic motd generators
rm -f /target/etc/update-motd.d/*

phase "overlay-unpack"
# overlay + build SSH key from the second initrd, zero network; d-i's tar is BUSYBOX — keep this line plain
tar -xzf /ombra/rootfs.tar.gz -C /target

# no ssh on the gateway: build/test access is vmrun guest operations

# user-setup made /home/ombra before this ran: seed the dotfiles by hand
for f in /target/etc/skel/.zshrc; do
    [ -f "$f" ] || continue
    cp "$f" "/target/home/ombra/${f##*/}"
done
chown -R 1000:1000 /target/home/ombra
in-target chsh -s /usr/bin/zsh ombra

# d-i does not enable overlay-provided services; networkd replaces the ifupdown stanzas
in-target systemctl enable ombra-firstboot.service
in-target systemctl enable systemd-networkd.service
in-target systemctl enable dnsmasq.service
in-target systemctl enable nftables.service
in-target systemctl enable ombra-timesync.timer
chmod 0755 /target/usr/local/sbin/ombra-update
in-target systemctl enable ombra-update-check.timer ombra-update-commit.timer
in-target systemctl enable ombra-torctl-filter.service

# ombra carries no group memberships beyond its own; the control-port side door needs one (systemcheck asserts it)
in-target gpasswd -d ombra debian-tor 2>/dev/null || true
in-target gpasswd -d ombra sudo 2>/dev/null || true

# the control-port filter runs as its own uid: no nftables upstream accept matches it, so a filter bug has loopback only
in-target sh -c 'id -u ombra-torctl >/dev/null 2>&1 || adduser --system --group --no-create-home --home /nonexistent --shell /usr/sbin/nologin ombra-torctl'

chmod 0440 /target/etc/sudoers.d/ombra-*

# the overlay's serial-getty/vgauth/cron masks (symlinks to /dev/null) landed with the tar extract; no host-guest channel beyond vmrun.
# freeze the static Tor-only resolver (networkd/resolved/upgrades must never rewrite it); in-target chroots, hence the guest-relative path.
in-target chattr +i /etc/resolv.conf

phase "update-grub"
# the kernel cmdline is the overlay drop-in's (50-ombra.cfg): update-grub must run after the tar extract
# boot-mode menu: the 09_ombra generator is the only source of entries; the stock generators stay disarmed
chmod 0755 /target/etc/grub.d/09_ombra \
    || ombra_fatal "boot-mode generator missing from the target overlay"
for g in 10_linux 20_linux_xen 30_os-prober 30_uefi-firmware; do
    [ ! -e "/target/etc/grub.d/$g" ] || chmod 0644 "/target/etc/grub.d/$g"
done
GT=/target/boot/grub/themes/ombra
mkdir -p /target/boot/grub/fonts
cp /target/usr/share/grub/unicode.pf2 /target/boot/grub/fonts/unicode.pf2 \
    || ombra_fatal "unicode.pf2 missing — the graphical boot menu would have no base font"
in-target grub-mkfont -s 18 -r 0x20-0x7e,0xa0-0x17f,0x2010-0x2026 -o /boot/grub/themes/ombra/ombra-16.pf2 \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
    || ombra_fatal "grub-mkfont failed for the menu font"
in-target grub-mkfont -s 26 -r 0x20-0x7e -o /boot/grub/themes/ombra/ombra-title.pf2 \
    /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf \
    || ombra_fatal "grub-mkfont failed for the title font"
pf2_name() { dd if="/target$1" bs=96 count=1 2>/dev/null | tr -c 'A-Za-z0-9 ._-' '|' | sed 's/.*NAME|*//; s/|.*//'; }
f16="$(pf2_name /boot/grub/themes/ombra/ombra-16.pf2)"
ftitle="$(pf2_name /boot/grub/themes/ombra/ombra-title.pf2)"
[ -n "$f16" ] && [ -n "$ftitle" ] || ombra_fatal "could not read the menu font name — the theme would fall back to the default font"
sed -i "s/@FONT16@/$f16/g; s/@FONTTITLE@/$ftitle/g" "$GT/theme.txt"
in-target update-grub \
    || ombra_fatal "update-grub failed — the machine would boot the wrong config"
GCFG=/target/boot/grub/grub.cfg
grep -q 'Ombra — Persistent' "$GCFG" && grep -q 'Ombra — Amnesic' "$GCFG" \
    || ombra_fatal "grub.cfg lacks the Persistent/Amnesic entries — the boot-mode menu would not ship"
[ "$(grep -c '^menuentry ' "$GCFG")" = 2 ] \
    || ombra_fatal "grub.cfg carries entries beyond the two boot modes"
grep -q 'themes/ombra/theme.txt' "$GCFG" \
    || ombra_fatal "grub.cfg does not load the Ombra theme"
grep -q 'overlayroot=disabled' "$GCFG" \
    || ombra_fatal "grub.cfg lacks the overlayroot=disabled kernel parameter"
grep -q 'ipv6.disable=1' "$GCFG" \
    || ombra_fatal "grub.cfg entries lost the hardened kernel cmdline"
touch /target/home/ombra/.hushlogin && chroot /target chown 1000:1000 /home/ombra/.hushlogin

phase "hardening"
# post-install hardening: no netcat/telnet, no timesyncd (never reaches NTP through the fail-closed firewall), no unattended-upgrade timers (immutable image)
in-target timeout 300 apt-get -y purge netcat-traditional inetutils-telnet || true
in-target systemctl disable systemd-timesyncd.service apt-daily.timer apt-daily-upgrade.timer || true
# wait-online costs 3.7s/boot and wedges boot with no carrier; nothing needs it
in-target systemctl mask systemd-networkd-wait-online.service

# the machine ships UTC (no timezone fingerprint); runtime time is
# owned by ombra-timesync over Tor
ln -sf /usr/share/zoneinfo/UTC /target/etc/localtime
printf 'UTC\n' > /target/etc/timezone
printf '0.0 0 0.0\n0\nUTC\n' > /target/etc/adjtime
in-target hwclock --systohc --utc >/dev/null 2>&1 || true

phase "initramfs"
# overlayroot's boot script must be inside the built initrd, or the amnesic root silently never engages
in-target update-initramfs -u >/dev/null 2>&1 \
    || ombra_fatal "update-initramfs failed — the amnesic root cannot be verified, so it cannot ship"
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q "init-bottom/overlayroot"'; then
    ombra_fatal "the rebuilt initrd has no overlayroot script — the gateway would persist its writes"
fi
grep -qx 'overlayroot="tmpfs"' /target/etc/overlayroot.conf \
    || ombra_fatal "overlayroot.conf does not select tmpfs — the gateway would persist its writes"

phase "scrub"
# release scrub: the shipped disk carries no build residue (best-effort by design)
in-target sh -c 'rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/backups/*.gz /var/crash/* /tmp/* /var/tmp/* /var/log/installer 2>/dev/null || true; apt-get clean >/dev/null 2>&1 || true; find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true; rm -f /root/.*history /home/*/.*history /root/.viminfo /home/*/.viminfo 2>/dev/null || true' || true

# LAST: the success stamp — its absence means the overlay never fully landed
touch /target/var/lib/ombra/late-ran
phase "complete"
echo "=== ombra late.sh COMPLETE ==="
