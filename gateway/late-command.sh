#!/bin/sh
# lands the gateway overlay; d-i runs it from the finish-install hook 08ombra (build/make-install-iso.sh),
# guarded by the late-ran stamp.

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
# an error that set -e turns into an exit parks too: without this the hook's `exit 0` powers off a broken install
trap 'rc=$?; [ "$rc" -eq 0 ] || ombra_fatal "late.sh stopped on an unhandled error (exit $rc); see /var/log/ombra-late.log"' EXIT
echo "=== ombra late.sh $(date -u +%FT%TZ) ==="

phase() {
    printf '%s %s\n' "$(date +%T)" "$1"
    [ -c /dev/ttyAMA0 ] && printf '%s ombra-late %s\n' "$(date +%T)" "$1" > /dev/ttyAMA0 2>/dev/null
    return 0
}


# ---- build-network residue -------------------------------------------------------------------------------------------
# The installer ran on the hypervisor's NAT: its resolv.conf, DHCP lease and syslog held that network's addresses, and
# files rewritten or deleted during the install leave copies in FREE blocks (measured on 1.2 builds: a deleted
# resolv.conf on both machines). Every block
# holding an address in one of the installer's /24 networks is found: a FREE block is zeroed (a handful of 4 KiB blocks,
# so the archives do not grow) and a re-scan must find none left. A LIVE file under /etc, /var, /root or /home holding
# one parks a release install (RESIDUE_STRICT=1); upstream data that contains such a dotted quad by chance is reported.
residue_ere() { # the installer's /24 networks, as one extended regex of whole dotted quads ("" = none)
    { awk '/^nameserver/ {print $2}' /etc/resolv.conf
      ip -4 addr 2>/dev/null | awk '$1 == "inet" {split($2, a, "/"); print a[1]}'
      ip -4 route 2>/dev/null | awk '$1 == "default" {print $3}'; } \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | grep -vE '^(127|0)\.' \
        | awk -F. '{print $1 "\\." $2 "\\." $3 "\\."}' | sort -u | awk 'BEGIN {ORS = ""} {print (NR > 1 ? "|" : "") $0}'
}
residue_hits() { # <dev> -> byte offsets of whole dotted quads in the networks
    chroot /target sh -c 'LC_ALL=C grep -aboE "(^|[^0-9.])($1)[0-9]{1,3}([^0-9]|\$)" "$2" 2>/dev/null | cut -d: -f1' \
        sh "$RESIDUE_ERE" "$1"
}
residue_wipe() { # <device> <label> <ext4|raw>
    dev="$1"
    [ -b "/target$dev" ] || mount -o bind /dev /target/dev 2>/dev/null || true
    [ -b "/target$dev" ] || ombra_fatal "residue: $dev is not visible inside /target"
    bs=4096
    [ "$3" = raw ] || bs="$(chroot /target dumpe2fs -h "$dev" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /, "", $2); print $2}')"
    [ -n "$bs" ] || ombra_fatal "residue: no block size for $dev"
    sync
    zeroed=0
    for pass in wipe verify; do
        left=0
        for off in $(residue_hits "$dev"); do
            for blk in $((off / bs)) $(((off + 20) / bs)); do
                free=1
                [ "$3" = raw ] || chroot /target debugfs -R "testb $blk" "$dev" 2>/dev/null | grep -q 'not in use' || free=0
                if [ "$free" = 1 ]; then
                    if [ "$pass" = wipe ]; then
                        dd if=/dev/zero of="$dev" bs="$bs" seek="$blk" count=1 conv=notrunc 2>/dev/null \
                            || ombra_fatal "residue: could not zero free block $blk on $dev"
                        zeroed=$((zeroed + 1))
                    else left=$((left + 1)); fi
                elif [ "$pass" = wipe ]; then
                    ino="$(chroot /target debugfs -R "icheck $blk" "$dev" 2>/dev/null | awk 'NR > 1 {print $2; exit}')"
                    path="$(chroot /target debugfs -R "ncheck $ino" "$dev" 2>/dev/null | awk 'NR > 1 {print $2; exit}')"
                    echo "residue: a build-network address in a live file on $2: ${path:-inode $ino}"
                    case "$2:$path" in
                        /:/etc/*|/:/var/*|/:/root/*|/:/home/*|/home:*)
                            [ "${RESIDUE_STRICT:-0}" = 1 ] && ombra_fatal "residue: a build-network address is in $2 $path" ;;
                    esac
                fi
            done
        done
        sync
        [ "$pass" = wipe ] || [ "$left" = 0 ] || ombra_fatal "residue: $left free block(s) on $dev still hold a build-network address"
    done
    echo "residue: $2 ($dev) clean, $zeroed block(s) zeroed"
}
residue_mounted() { awk -v m="$1" '$2 == m && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts; }

phase "start"
# CD source off before any apt (the cdrom method blocks on the disc)
sed -i 's|^deb cdrom:|# deb cdrom:|' /target/etc/apt/sources.list
# no timeout on dpkg configure: a killed configure is corruption, not a stall guard
in-target dpkg --configure -a

phase "apt-sources"
# Security and point-release updates are configured here, not by d-i: d-i reports a failed fetch of either with an
# error template, which no preseed can answer, so one mirror hiccup there stalls an unattended install for good.
# Here the fetch is retried, any failed index is an error (--error-on=any), and a mirror that stays down parks.
SL=/target/etc/apt/sources.list
grep -q '^deb .*trixie-security' "$SL" || printf 'deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware\n' >> "$SL"
grep -q '^deb .*trixie-updates' "$SL" || printf 'deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware\n' >> "$SL"
# The installer's clock can be hours off: Fusion fills the RTC with the host's LOCAL time and d-i's NTP step does not
# always land. apt then rejects a Release file published since as "not valid yet", which looks like a dead mirror.
# Take the time from the mirror host's TLS-authenticated Date header before any signature date is judged.
clock_from_mirror() {
    hdr="$(chroot /target curl -q -sS -I --max-time 20 https://deb.debian.org/ 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)"
    [ -n "$hdr" ] || { echo "clock: no Date header from the mirror host (clock left at $(date -u +%FT%TZ))"; return 1; }
    want="$(chroot /target date -u -d "$hdr" +%s 2>/dev/null)" || want=""
    case "$want" in ''|*[!0-9]*) echo "clock: unreadable Date header '$hdr'"; return 1 ;; esac
    have="$(date -u +%s)"
    skew=$((want - have)); [ "$skew" -ge 0 ] || skew=$((0 - skew))
    if [ "$skew" -gt 60 ]; then
        echo "clock: installer clock was $(date -u +%FT%TZ), the mirror host says $hdr: stepping it"
        chroot /target date -u -s "@$want" >/dev/null 2>&1 || { echo "clock: could not set the clock"; return 1; }
    fi
    return 0
}
clock_from_mirror || true
n=0
until in-target apt-get update --error-on=any -o Acquire::Retries=3 >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -ge 6 ]; then
        # in-target's output goes to syslog: show apt's own reason here before parking
        chroot /target apt-get update --error-on=any 2>&1 | tail -n 12 || true
        ombra_fatal "apt-get update failed 6 times (mirror unreachable or clock wrong; apt's reason is in /var/log/ombra-late.log)"
    fi
    clock_from_mirror || true
    sleep 20
done
in-target apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io dist-upgrade >/dev/null 2>&1 \
    || ombra_fatal "applying Debian's security and point-release updates failed"

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
# one edition: two VMs. The updater reads this file (a missing one means the same)
printf 'two-vm\n' > /target/etc/ombra/edition

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
chmod 0755 /target/usr/local/sbin/ombra-tor-tripwire /target/usr/local/sbin/ombra-tor-freshness
in-target systemctl enable ombra-tor-freshness.timer
chmod 0755 /target/usr/local/sbin/ombra-update
in-target systemctl enable ombra-update-check.timer ombra-update-commit.timer
in-target systemctl enable ombra-torctl-filter.service

# ombra carries no group memberships beyond its own; the control-port side door needs one (systemcheck asserts it)
in-target gpasswd -d ombra debian-tor 2>/dev/null || true
in-target gpasswd -d ombra sudo 2>/dev/null || true

# the control-port filter runs as its own uid: no nftables upstream accept matches it, so a filter bug has loopback only
in-target sh -c 'id -u ombra-torctl >/dev/null 2>&1 || adduser --system --group --no-create-home --home /nonexistent --shell /usr/sbin/nologin ombra-torctl'

chmod 0440 /target/etc/sudoers.d/ombra-*
# a drop-in that does not parse breaks every sudo grant the console relies on
in-target visudo -c >/dev/null || ombra_fatal "sudoers drop-ins do not parse"

# the overlay's serial-getty/cron masks (symlinks to /dev/null) landed with the tar extract; no host-guest channel beyond vmrun.
# freeze the static Tor-only resolver (networkd/resolved/upgrades must never rewrite it); in-target chroots, hence the guest-relative path.
in-target chattr +i /etc/resolv.conf

# the gateway installs no tasksel task: every tool its scripts and console rely on must be here, or nothing ships
for t in bash od timeout su ss journalctl findmnt mountpoint diff curl nft ip setpriv unshare ps dig sudo zsh tor tor-resolve dnsmasq qemu-ga apt-get apparmor_parser; do
    chroot /target sh -c "command -v $t" >/dev/null 2>&1 \
        || ombra_fatal "the gateway lacks '$t', which its own scripts need"
done

# Tor's unit requires its AppArmor profile (30-ombra-apparmor.conf): without the profile file or the service that loads
# it at boot, Tor would never start and the gateway would have no network
[ -f /target/etc/apparmor.d/system_tor ] || ombra_fatal "Tor's AppArmor profile (/etc/apparmor.d/system_tor) is missing"
[ -L /target/etc/systemd/system/sysinit.target.wants/apparmor.service ] \
    || ombra_fatal "apparmor.service is not enabled: Tor's required profile would not be loaded at boot"

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

# QEMU/UTM guest half of host-guest isolation: the agent may only answer the allowlist shipped in qemu-ga.conf, and every name on it must be a command this agent really has
GA_CONF=/target/etc/qemu/qemu-ga.conf
[ -x /target/usr/sbin/qemu-ga ] || ombra_fatal "qemu-guest-agent is not installed"
grep -q '^allow-rpcs=' "$GA_CONF" || ombra_fatal "qemu-ga.conf has no allow-rpcs line — the agent would answer every command"
# a TEST build (never exported) adds a marker and a wider allowlist so the host can inspect the guest, the way vmrun does for Fusion
if [ ! -e /ombra/test-build ]; then
    ! grep -q -E '^(block-rpcs|allow-rpcs)=.*(guest-exec|guest-file|guest-set-|guest-ssh|guest-fs)' "$GA_CONF" \
        || ombra_fatal "qemu-ga.conf allows command execution, file access or a state change"
fi
# chroot, not in-target: in-target sends its output to the syslog, so a command substitution around it would capture nothing
GA_KNOWN="$(chroot /target qemu-ga --allow-rpcs=help 2>&1 | tr ' ,\t' '\n\n\n')"
[ -n "$GA_KNOWN" ] || ombra_fatal "qemu-ga --allow-rpcs=help printed nothing — the allowlist cannot be checked"
for rpc in $(sed -n 's/^allow-rpcs=//p' "$GA_CONF" | tr ',' ' '); do
    printf '%s\n' "$GA_KNOWN" | grep -qFx "$rpc" \
        || ombra_fatal "qemu-ga.conf allows '$rpc', which this agent does not have"
done

# the machine ships UTC (no timezone fingerprint); runtime time is
# owned by ombra-timesync over Tor
ln -sf /usr/share/zoneinfo/UTC /target/etc/localtime
printf 'UTC\n' > /target/etc/timezone
printf '0.0 0 0.0\n0\nUTC\n' > /target/etc/adjtime
in-target hwclock --systohc --utc >/dev/null 2>&1 || true

phase "initramfs"
# overlayroot's boot script must be inside the built initrd, or the amnesic root silently never engages
in-target update-initramfs -u -k all >/dev/null 2>&1 \
    || ombra_fatal "update-initramfs failed — the amnesic root cannot be verified, so it cannot ship"
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q "init-bottom/overlayroot"'; then
    ombra_fatal "the rebuilt initrd has no overlayroot script — the gateway would persist its writes"
fi
grep -qx 'overlayroot="tmpfs"' /target/etc/overlayroot.conf \
    || ombra_fatal "overlayroot.conf does not select tmpfs — the gateway would persist its writes"

# the exact Debian package versions in this image, for audit: the suite is live trixie at build time, not a snapshot
mkdir -p /target/usr/share/ombra
awk '/^Package: /{p=$2} /^Architecture: /{a=$2} /^Version: /{v=$2} /^Status: .* installed$/{i=1} /^$/{if(i)print p" "v" "a; p=v=a="";i=0} END{if(i)print p" "v" "a}' /target/var/lib/dpkg/status | sort > /target/usr/share/ombra/packages.txt \
    && [ -s /target/usr/share/ombra/packages.txt ] \
    || ombra_fatal "could not record the package manifest"

phase "scrub"
# release scrub: the shipped disk carries no build residue (best-effort by design)
in-target sh -c 'rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/backups/*.gz /var/crash/* /tmp/* /var/tmp/* /var/log/installer 2>/dev/null || true; apt-get clean >/dev/null 2>&1 || true; find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true; rm -f /root/.*history /home/*/.*history /root/.viminfo /home/*/.viminfo 2>/dev/null || true' || true


phase "residue"
RESIDUE_STRICT=1
RESIDUE_ERE="$(residue_ere)"
[ -n "$RESIDUE_ERE" ] || ombra_fatal "residue: could not read the installer's own network addresses"
for m in "" /boot /home; do
    d="$(residue_mounted "/target$m")"; [ -n "$d" ] || continue
    [ "$(awk -v m="/target$m" '$2 == m {print $3; exit}' /proc/mounts)" = ext4 ] || continue
    residue_wipe "$d" "${m:-/}" ext4
done

# LAST: the success stamp — its absence means the overlay never fully landed
touch /target/var/lib/ombra/late-ran
phase "complete"
echo "=== ombra late.sh COMPLETE ==="
