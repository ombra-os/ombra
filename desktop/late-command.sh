#!/bin/sh
# desktop/late-command.sh — run by d-i's finish-install hook 08ombra (build/make-install-iso.sh) as
# /ombra/late.sh. /target is the installed system; /ombra/* is the initrd carrier.

set -eu

# A FATAL must PARK the installer: the 08ombra hook wraps this script in `exit 0`, so a non-zero exit would silently ship.
# chvt 3 puts the reason on the syslog VT (d-i's frontend repaints over tty1).
ombra_fatal() {
    echo "FATAL: $1 — install PARKED, this machine must not be shipped" >&2
    db_set debian-installer/exit/poweroff false >/dev/null 2>&1 || true
    chvt 3 >/dev/null 2>&1 || true
    while :; do
        echo "FATAL: $1 — install parked ($(date +%H:%M:%S)); fix the failure and reinstall" > /dev/console 2>/dev/null || true
        sleep 60
    done
}

# stamp guard: several steps below APPEND to config files; a re-run is a no-op
if [ -e /target/var/lib/ombra/late-ran ]; then
    echo "ombra late.sh: stamp present, already applied — skipping"
    exit 0
fi

# everything below logs to the target disk; CRITICAL steps abort, the rest fail soft as re-appliable post-install
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

soft() { "$@" || echo "WARN(non-critical, re-applied post-install): $* failed"; }

# single edition (marker from build/make-install-iso.sh single): the end user installs from the ISO and chose the disk
# passphrase and the account password in the installer; there is no build passphrase and no first-use screen
SINGLE=""
[ ! -e /ombra/edition-single ] || SINGLE=1


# ---- build-network residue -------------------------------------------------------------------------------------------
# The installer ran on the hypervisor's NAT: its resolv.conf, DHCP lease and syslog held that network's addresses, and
# files rewritten or deleted during the install leave copies in FREE blocks (measured on 1.2 builds: a deleted
# resolv.conf on both machines; on a single VM install also the deleted installer syslog with its lease). Every block
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
in-target dpkg --configure -a \
    || ombra_fatal "dpkg --configure -a failed — the target is in an inconsistent package state"

# --- LUKS container: recorded, never assumed -------------------------------
# no cryptsetup in the d-i environment (assertions run at first use); the container is DISCOVERED from blkid, never hardcoded.
luks_part="$(blkid 2>/dev/null | awk -F: '/crypto_LUKS/{print $1; exit}')"
if [ -n "$luks_part" ]; then
    echo "LUKS container present: $luks_part (argon2id verified at first use)"
else
    echo "WARN: blkid sees no crypto_LUKS container — firstuse will complain loudly"
fi

# single: the container was formatted with the user's own passphrase and is never re-keyed, so it must already be what
# first use would have made it: LUKS2, one argon2id keyslot, aes-xts-plain64 with a 512-bit key (the preseed asks d-i
# for 512; its own default is 256). The public build passphrase must not open it (the user may have typed it).
# the target's cryptsetup through in-target (/proc, /sys and /run set up); output through a file, never a capture of in-target
if [ -n "$SINGLE" ]; then
    # the installer's blkid first (as above), then the target's
    [ -n "$luks_part" ] || luks_part="$(chroot /target blkid 2>/dev/null | awk -F: '/crypto_LUKS/{print $1; exit}')"
    [ -n "$luks_part" ] || ombra_fatal "no LUKS container on the target disk — the single edition must be encrypted"
    chroot /target test -b "$luks_part" || ombra_fatal "the LUKS container $luks_part is not a block device inside /target"
    rm -f /target/var/tmp/ombra-luksdump.txt
    in-target sh -c 'cryptsetup luksDump "$1" > /var/tmp/ombra-luksdump.txt 2>&1' sh "$luks_part" \
        || ombra_fatal "cryptsetup luksDump failed on $luks_part"
    # the parameters, for the install log (no salts, no digests)
    echo "LUKS parameters of $luks_part:"
    awk '/^[^ \t]/ {sec=$0} $1=="Version:" || $1=="cipher:" || $1=="Key:" || $1=="PBKDF:" || $1=="Time" || $1=="Memory:" || $1=="Threads:" || (sec ~ /^Keyslots:/ && $2=="luks2") {print "  " $0}' /target/var/tmp/ombra-luksdump.txt
    # single-line awk (the walker in tests/build flags multi-line quoted regions)
    awk '/^[^ \t]/ {sec=$0} $1=="Version:" {v=$2} sec ~ /^Data segments:/ && $1=="cipher:" {n++; if ($2 != "aes-xts-plain64") bad=1} sec ~ /^Keyslots:/ && $2=="luks2" {s++} sec ~ /^Keyslots:/ && $1=="Key:" {k++; if ($2 != "512") bad=1} sec ~ /^Keyslots:/ && $1=="PBKDF:" {p++; if ($2 != "argon2id") bad=1} END {exit !(v == 2 && n == 1 && s == 1 && k == 1 && p == 1 && !bad)}' /target/var/tmp/ombra-luksdump.txt \
        || ombra_fatal "the LUKS container is not LUKS2 with one argon2id keyslot and aes-xts-plain64 with a 512-bit key (see the parameters in /var/log/ombra-late.log)"
    rm -f /target/var/tmp/ombra-luksdump.txt
    # cryptsetup exit 2 = no key matches; 0 = it opens (park); anything else = no verdict (park). Both byte forms.
    for nl in "" "\n"; do
        rc=0
        in-target sh -c 'printf "ombra-disk$2" | cryptsetup open --test-passphrase --key-file - "$1"' sh "$luks_part" "$nl" || rc=$?
        [ "$rc" != 0 ] || ombra_fatal "the disk passphrase is Ombra's public build passphrase — reinstall and choose your own"
        [ "$rc" = 2 ] || ombra_fatal "cryptsetup could not test the public build passphrase against $luks_part (exit $rc)"
    done
    echo "LUKS: the public build passphrase does not open $luks_part (cryptsetup exit 2)"
fi

phase "dpkg-configure-done"
# --- Per-boot random-key swap ("cryptswap") --------------------------------
# dm-crypt layer over the swap LV, keyed from /dev/urandom at every activation; the LV is DISCOVERED from fstab.
swap_spec="$(awk '!/^#/ && $3=="swap" {print $1; exit}' /target/etc/fstab)"
# installer env first, then chroot; never a capture around in-target (it sends its output to the syslog, so the capture is always empty)
swap_lv="$(findfs "$swap_spec" 2>/dev/null || chroot /target findfs "$swap_spec" 2>/dev/null || true)"
if [ -z "$swap_lv" ]; then
    case "$swap_spec" in
        UUID=*|LABEL=*) swap_lv="" ;;
        *) swap_lv="$swap_spec" ;;
    esac
fi
if [ -z "$swap_lv" ]; then
    ombra_fatal "could not resolve the swap LV from fstab ($swap_spec)"
fi
# guarded: a stamp-less re-run must not append twice; the swap line is deleted by FIELD (d-i aligns fstab columns)
awk '!/^#/ && $3=="swap" {next} {print}' /target/etc/fstab > /target/etc/fstab.ombra \
    && mv /target/etc/fstab.ombra /target/etc/fstab
awk '!/^#/ && $3=="swap" {exit 1}' /target/etc/fstab \
    || ombra_fatal "a plain fstab swap line survived the cryptswap conversion — swap would ship unencrypted"

# /home is its own LV (preseed recipe): an update rollback merges root's snapshot and must never revert the user's files
awk '!/^#/ && $2=="/home" {f=1} END {exit f?0:1}' /target/etc/fstab \
    || ombra_fatal "/home is not a separate mount in the target's fstab — an update rollback would revert the user's files"
awk '$2=="/target/home" {f=1} END {exit f?0:1}' /proc/mounts \
    || ombra_fatal "/target/home is not mounted in the installer — the home logical volume was not created"

# RESUME=none: the initramfs must not activate the old swap before cryptsetup
printf 'RESUME=none\n' > /target/etc/initramfs-tools/conf.d/resume
grep -q '^/dev/mapper/cryptswap' /target/etc/fstab || \
    printf '/dev/mapper/cryptswap\tnone\tswap\tsw\t0\t0\n' >> /target/etc/fstab
grep -q '^cryptswap' /target/etc/crypttab || printf 'cryptswap\t%s\t/dev/urandom\tcipher=aes-xts-plain64,size=512,swap\n' "$swap_lv" \
    >> /target/etc/crypttab


purge_present() {
    present="$(awk -v want="$*" 'BEGIN{n=split(want,w," ")} /^Package: /{pkg=substr($0,10)} /^Status: .* installed$/{for(i=1;i<=n;i++){r="^" w[i] "$"; gsub(/\*/,".*",r); if(pkg ~ r) print pkg}}' /target/var/lib/dpkg/status)"
    [ -z "$present" ] || in-target apt-get purge -y $present >/dev/null 2>&1 || true
}

# initramfs rebuilds are deferred to one explicit run after the last package change
cp /target/etc/initramfs-tools/update-initramfs.conf /target/etc/initramfs-tools/update-initramfs.conf.ombra-orig
printf 'update_initramfs=no\n' > /target/etc/initramfs-tools/update-initramfs.conf

phase "apt-sources"
# Security and point-release updates are configured here, not by d-i: d-i reports a failed fetch of either with an
# error template, which no preseed can answer, so one mirror hiccup there stalls an unattended install for good.
# Here the fetch is retried, any failed index is an error (--error-on=any), and a mirror that stays down parks.
SL=/target/etc/apt/sources.list
# CD source off before any apt: with --error-on=any its missing Release file fails every update
sed -i 's|^deb cdrom:|# deb cdrom:|' "$SL"
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

phase "cryptswap-done"
# every remaining section: FAIL-SOFT (re-appliable post-install)
(
set +e
# --- hostname: repair both files
echo ombra > /target/etc/hostname
sed -i '/^127\.0\.1\.1/d' /target/etc/hosts
printf '127.0.1.1\tombra.local\tombra\n' >> /target/etc/hosts

# --- os-release: base-files owns /usr/lib/os-release and would re-Debian it on every upgrade; divert it (--rename BEFORE the overlay unpack).
in-target dpkg-divert --add --rename --divert /usr/lib/os-release.distrib /usr/lib/os-release \
    || echo "WARN: os-release divert failed (a base-files upgrade may re-Debian the identity)"
# base-files' /etc/debian_version stamp: same divert, then the .distrib copy goes
in-target dpkg-divert --local --add --rename --divert /etc/debian_version.distrib /etc/debian_version \
    || echo "WARN: debian_version divert failed (a base-files upgrade may restore the Debian version stamp)"
rm -f /target/etc/debian_version.distrib
# static motd: remove Debian's dynamic motd generators
rm -f /target/etc/update-motd.d/*

# overlay from the second initrd, zero network; ownership was packed at creation (d-i's BusyBox tar has no --no-same-owner)
phase "overlay-unpack"
tar -xzf /ombra/rootfs.tar.gz -C /target

# git cannot carry these modes; NetworkManager ignores a profile that is not 0600
chmod 0600 /target/etc/NetworkManager/system-connections/*.nmconnection \
    || ombra_fatal "NetworkManager profile mode not set — the intnet link would never come up"
chmod 0755 /target/usr/local/sbin/ombra-askpass-fallback /target/usr/local/sbin/ombra-timesync /target/usr/local/sbin/ombra-kwin-compositing \
    || ombra_fatal "overlay sbin helpers not executable on the target"

# no ssh on the desktop: build/test access is vmrun guest operations

# nothing on the desktop needs root-by-password: no sudo group membership
in-target gpasswd -d ombra sudo >/dev/null 2>&1 || true

# --- login shell ---
in-target chsh -s /usr/bin/zsh ombra

# --- seed /home/ombra AFTER the unpack (useradd ran before the overlay landed)
in-target cp -a /etc/skel/. /home/ombra/
in-target chown -R ombra:ombra /home/ombra

# no autologin group: sddm's seat is a normal interactive login

# --- telemetry / phone-home: nothing may call out ---------------------------
# purge first, then mask what is left as a unit; `systemctl --root` is the only correct form in d-i (no systemd runs in /target)
purge_present avahi-daemon cups cups-browsed bluetooth bluez ModemManager geoclue geoclue-2.0 localsearch packagekit systemd-timesyncd
for u in avahi-daemon cups cups-browsed bluetooth ModemManager geoclue-2.0 localsearch packagekit systemd-timesyncd; do
    in-target systemctl mask "$u.service" 2>/dev/null || true
done
# scheduled apt runs are Tor traffic on an idle appliance; updates are run by hand
for u in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service; do
    in-target systemctl mask "$u" 2>/dev/null || true
done

# NM stays (owns the intnet NIC) with its HTTP connectivity probe off
mkdir -p /target/etc/NetworkManager/conf.d
cat > /target/etc/NetworkManager/conf.d/20-ombra-no-probes.conf <<'NMEOF'
[connectivity]
enabled=false
uri=
interval=0
NMEOF

# guest half of host-guest isolation: the clipboard/drag-drop and hgfs plugins never load; resolutionSet (display auto-fit) stays
# dpkg never unpacks them again (a reinstall or upgrade of open-vm-tools would restore them otherwise); dpkg's fnmatch lets * span the multiarch dir
mkdir -p /target/etc/dpkg/dpkg.cfg.d
printf 'path-exclude=/usr/lib/*open-vm-tools/plugins/*/libdndcp.so\npath-exclude=/usr/lib/*open-vm-tools/plugins/*/libhgfsServer.so\n' \
    > /target/etc/dpkg/dpkg.cfg.d/ombra-no-host-channels
# chroot (the target's GNU find; BusyBox find may lack -path/-delete), never a capture around in-target: its output goes to the syslog
chroot /target find /usr/lib -path '*open-vm-tools/plugins/*' \( -name libdndcp.so -o -name libhgfsServer.so \) -delete
vmt_left="$(chroot /target find /usr/lib -path '*open-vm-tools/plugins/*' \( -name libdndcp.so -o -name libhgfsServer.so \) 2>&1)" \
    || ombra_fatal "could not search the target for open-vm-tools host-channel plugins"
if [ -n "$vmt_left" ]; then
    ombra_fatal "open-vm-tools clipboard/dnd/hgfs plugins still present — host-guest channel would stay open"
fi

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
[ -x /target/usr/bin/spice-vdagent ] && [ -x /target/usr/sbin/spice-vdagentd ] \
    || ombra_fatal "spice-vdagent is not installed — the QEMU display would not follow the window size"

# single: the user makes the VM by hand, so none of Ombra's vmx/plist isolation settings are there; the guest closes the
# channels itself, whatever the host offers
if [ -n "$SINGLE" ]; then
    # VMware shared folders: without the FUSE client nothing in the guest can mount the host's shares (dpkg never restores it)
    printf 'path-exclude=/usr/*bin/vmhgfs-fuse\npath-exclude=/usr/*bin/mount.vmhgfs\n' >> /target/etc/dpkg/dpkg.cfg.d/ombra-no-host-channels
    chroot /target find /usr/bin /usr/sbin \( -name vmhgfs-fuse -o -name mount.vmhgfs \) -delete
    hgfs_left="$(chroot /target find /usr/bin /usr/sbin \( -name vmhgfs-fuse -o -name mount.vmhgfs \) 2>&1)" \
        || ombra_fatal "could not search the target for the VMware shared-folder client"
    [ -z "$hgfs_left" ] || ombra_fatal "the VMware shared-folder client is still present — the host's shares could be mounted"
    # UTM clipboard and file transfer live in the session agent (spice-vdagent, started by the desktop session); no
    # option of it turns the clipboard off, so it never runs: a statoverride keeps it non-executable across upgrades.
    # the daemon (spice-vdagentd) stays, alone it carries no clipboard. Cost: under UTM the display no longer follows the window.
    in-target sh -c 'dpkg-statoverride --list /usr/bin/spice-vdagent >/dev/null 2>&1 || dpkg-statoverride --update --add root root 0644 /usr/bin/spice-vdagent' \
        || ombra_fatal "dpkg-statoverride failed for /usr/bin/spice-vdagent"
    grep -qxE 'root root 0?644 /usr/bin/spice-vdagent' /target/var/lib/dpkg/statoverride \
        || ombra_fatal "/usr/bin/spice-vdagent has no 0644 statoverride — a spice-vdagent upgrade would re-arm the clipboard"
    chmod 0644 /target/usr/bin/spice-vdagent
    [ ! -x /target/usr/bin/spice-vdagent ] || ombra_fatal "spice-vdagent is still executable — the UTM clipboard would follow the host's setting"
fi

# --- fixed machine-id: one anonymity set shared by every install
printf '6f6d6272610000000000000000000001\n' > /target/etc/machine-id
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id

# Tor-only time sync through the gateway (units ship in the overlay)
in-target systemctl enable ombra-timesync.timer >/dev/null 2>&1 || true
# KWin compositor policy: off on QEMU guests only (a unit, because the image cannot know which hypervisor it will boot under)
in-target systemctl enable ombra-kwin-compositing.service >/dev/null 2>&1 \
    || ombra_fatal "systemctl enable failed for ombra-kwin-compositing"
chmod 0755 /target/usr/local/sbin/ombra-update /target/usr/local/bin/ombra-update-notify /target/usr/local/bin/ombra-update-gui
in-target systemctl enable ombra-update-check.timer ombra-update-commit.timer >/dev/null 2>&1 || true
# the enable's status is not trusted: an image without these links never checks for updates
for u in ombra-update-check.timer ombra-update-commit.timer; do
    [ -L "/target/etc/systemd/system/timers.target.wants/$u" ] \
        || ombra_fatal "$u is not enabled — the desktop would ship without update checks"
done
# the desktop's own default-drop firewall (ruleset ships in the overlay)
in-target systemctl enable nftables.service >/dev/null 2>&1 || true
# transfer-session disks: fixed mounts, no desktop automount stack (units ship in the overlay)
in-target systemctl enable mnt-transfer-shared.automount >/dev/null 2>&1 \
    || ombra_fatal "systemctl enable failed for the transfer mounts"

# no further enables here: packages enable their own units (an early enable would no-op)

phase "session-apt-begin"
# ---- desktop session layer: KDE Plasma on X11 ------------------------------
# ONE apt transaction, INSTALL-RECOMMENDS OFF: metapackage recommends would drag in an app suite; everything wanted is named explicitly.
sed -i 's|^deb cdrom:|# deb cdrom:|' /target/etc/apt/sources.list
# NO timeout on this transaction: a killed dpkg ships half a session (sddm up, plasma missing).
in-target apt-get install -y -o Acquire::Retries=3 -o APT::Install-Recommends=false \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io \
    kde-plasma-desktop sddm kwin-x11 kitty qt-style-kvantum \
    plasma-nm plasma-pa systemsettings kio-extras kscreen kmenuedit \
    breeze-gtk-theme libpam-systemd fastfetch \
    >/dev/null 2>&1 || touch /tmp/ombra-session-failed

phase "session-apt-done"
# session-stack privacy belt (soft, idempotent): banned classes must not linger even if a recommends change pulls them in later
purge_present plasma-discover kdeconnect kdeconnect-kde baloo-kf6 zutty
for u in plasma-discover.service kdeconnectd.service; do
    in-target systemctl mask "$u" 2>/dev/null || true
done

# masking kactivitymanagerd aborts plasmashell 6.3's shell load, so the privacy mechanism is volatile instead:
# the daemon runs, its database lives on a boot-wiped tmpfs — nothing about usage ever persists
in-target systemctl enable kact-wipe.service \
    home-ombra-.local-share-kactivitymanagerd-resources.mount >/dev/null 2>&1 \
    || echo "WARN(non-critical, re-applied post-install): kactivities volatile units not enabled"
# plasma-workspace HARD depends on drkonqi (a purge cascades away the desktop): mask every unit it owns, never remove the package
for u in drkonqi-sentry-postman.timer drkonqi-sentry-postman.service drkonqi-sentry-postman.path drkonqi-coredump-cleanup.timer drkonqi-coredump-launcher.socket drkonqi-coredump-launcher@.service; do
    ln -sf /dev/null "/target/etc/systemd/user/$u"
done
# GHNS ("Get New Stuff") is a remote fetch-and-parse surface
rm -rf /target/usr/share/knsrcfiles

# the greeter defaults to the FIRST session file it finds; divert (not rm) the Wayland session so upgrades cannot restore it
in-target dpkg-divert --add --rename --divert \
    /usr/share/wayland-sessions/plasma.desktop.ombra-x11 \
    /usr/share/wayland-sessions/plasma.desktop \
    || echo "WARN: wayland session divert failed (the greeter may default to Plasma (Wayland))"

# ---- locale: en_US.UTF-8 explicitly ----------------------------------------
# d-i writes only "en_US ISO-8859-1" into /etc/locale.gen; without a UTF-8 line locale-gen never makes en_US.UTF-8.
# Paths are HOST-side here: in-target resolves inside the chroot, where /target/... does not exist.
grep -q '^en_US.UTF-8 UTF-8' /target/etc/locale.gen 2>/dev/null \
    || printf 'en_US.UTF-8 UTF-8\n' >> /target/etc/locale.gen
in-target locale-gen en_US.UTF-8 >/dev/null 2>&1 \
    || echo "WARN: en_US.UTF-8 generation failed (Qt will keep falling back to C.UTF-8)"
in-target update-locale LANG=en_US.UTF-8 LANGUAGE= LC_ALL= >/dev/null 2>&1 \
    || echo "WARN: update-locale failed (LANG will stay ISO-8859-1)"

phase "tor-browser-begin"
# ---- Tor Browser: mandatory payload ----------------------------------------
# Staged by build/make-install-iso.sh from the sha256-pinned tarball, re-verified here.
# Runs INSIDE the soft subshell where `exit` is swallowed: a failure writes a flag file for the fatal section below.
rm -f /tmp/ombra-tbb-fail
if [ ! -e /target/opt/tor-browser/Browser/firefox ]; then
    tbb_tar="/ombra/vendor/$(ls /ombra/vendor 2>/dev/null | grep '^tor-browser-linux-aarch64-.*\.tar\.xz$' | head -1)"
    if [ -n "${tbb_tar##*/}" ] && [ -f "$tbb_tar" ]; then
        tbb_want="$(awk -F= '$1=="sha256"{print $2}' /ombra/vendor/torbrowser.sha256 2>/dev/null || true)"
        tbb_got="$(sha256sum "$tbb_tar" 2>/dev/null | awk '{print $1}')"
        # fail closed: an empty pin (torbrowser.sha256 missing or unreadable) is a failed check, never a skipped one
        if [ -z "$tbb_want" ] || [ "$tbb_got" != "$tbb_want" ]; then
            echo "FATAL: staged Tor Browser tarball sha256 check failed (got '$tbb_got', pin '${tbb_want:-none: torbrowser.sha256 missing or empty}') — refusing to install an unauditable browser" >&2
            echo "ombra-tbb: sha256 mismatch or no pin" > /tmp/ombra-tbb-fail
        else
        echo "installing Tor Browser from the pinned tarball ($(basename "$tbb_tar"))"
        mkdir -p /target/opt/tor-browser /target/var/tmp
        cp "$tbb_tar" /target/var/tmp/ombra-tbb.tar.xz
        # unpack with /target's GNU tar — the d-i env's tar may be BusyBox (no -J / --strip-components support)
        # --no-same-owner: everything lands root-owned whatever uid the tarball carries; only Data/ is handed to the user below
        in-target tar -xJf /var/tmp/ombra-tbb.tar.xz -C /opt/tor-browser --strip-components=1 --no-same-owner \
            || { echo "FATAL: Tor Browser tarball would not unpack (target GNU tar)" >&2; \
                 echo "ombra-tbb: tarball would not unpack" > /tmp/ombra-tbb-fail; exit 1; }
        rm -f /target/var/tmp/ombra-tbb.tar.xz
        # the bundle is 0700 root-only; in /opt the desktop user needs read+traverse+execute
        in-target chmod -R a+rX /opt/tor-browser \
            || { echo "ombra-tbb: chmod failed" > /tmp/ombra-tbb-fail; exit 1; }

        # the browser NEVER runs its own Tor — the gateway is the only Tor (user.js survives first-run profile setup)
        mkdir -p "/target/opt/tor-browser/Browser/TorBrowser/Data/Browser/profile.default" /target/opt/tor-browser/Browser/distribution
        cat > "/target/opt/tor-browser/Browser/TorBrowser/Data/Browser/profile.default/user.js" <<'JS'
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "10.55.10.1");
user_pref("network.proxy.socks_port", 9150);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "");
user_pref("torbrowser.settings.quickstart.enabled", true);
user_pref("app.update.auto", false);
user_pref("app.update.enabled", false);
user_pref("app.update.service.enabled", false);
user_pref("app.update.staging.enabled", false);
user_pref("app.update.silent", false);
user_pref("extensions.update.enabled", false);
user_pref("intl.language_notification.shown", true);
user_pref("intl.locale.requested", "en-US");
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "/home/ombra/Downloads");
user_pref("browser.download.useDownloadDir", true);
user_pref("widget.use-xdg-desktop-portal.file-picker", 0);
user_pref("widget.use-xdg-desktop-portal.mime-handler", 0);
user_pref("widget.use-xdg-desktop-portal.open-uri", 0);
JS
        if [ ! -e /target/opt/tor-browser/Browser/distribution/policies.json ]; then
            cat > /target/opt/tor-browser/Browser/distribution/policies.json <<'JS'
{"policies": {"DisableAppUpdate": true}}
JS
        fi

        # control cookie: 32 RAW bytes (the browser hex-encodes the file for AUTHENTICATE); equals core/src/torctl.rs CLIENT_COOKIE_HEX
        mkdir -p "/target/opt/tor-browser/Browser/TorBrowser/Data/Tor"
        printf '\141\207\011\277\276\362\170\224\146\051\262\332\070\301\342\001\303\173\355\373\320\255\153\055\275\304\334\156\123\326\012\350' \
            > "/target/opt/tor-browser/Browser/TorBrowser/Data/Tor/control_auth_cookie"
        [ "$(wc -c < /target/opt/tor-browser/Browser/TorBrowser/Data/Tor/control_auth_cookie)" -eq 32 ] \
            || { echo "ombra-tbb: control cookie is not 32 bytes" > /tmp/ombra-tbb-fail; exit 1; }

        # an unwritable profile lock reports "already running" and the browser never starts
        in-target chown -R ombra:ombra /opt/tor-browser/Browser/TorBrowser/Data \
            || { echo "ombra-tbb: profile chown failed" > /tmp/ombra-tbb-fail; exit 1; }

        cat > /target/usr/local/bin/tor-browser <<'SH'
#!/bin/sh
export TOR_SKIP_LAUNCH=1
export TOR_NO_DISPLAY_NETWORK_SETTINGS=1
export TOR_SOCKS_HOST=10.55.10.1
export TOR_SOCKS_PORT=9150
export TOR_CONTROL_HOST=10.55.10.1
export TOR_CONTROL_PORT=9052
export TOR_CONTROL_COOKIE_AUTH_FILE=/opt/tor-browser/Browser/TorBrowser/Data/Tor/control_auth_cookie
exec /opt/tor-browser/Browser/./start-tor-browser --detach "$@"
SH
        chmod 0755 /target/usr/local/bin/tor-browser

        # the overlay .desktop asks for Icon=tor-browser
        if [ -f /target/opt/tor-browser/Browser/browser/chrome/icons/default/default48.png ]; then
            mkdir -p /target/usr/share/icons/hicolor/48x48/apps
            cp /target/opt/tor-browser/Browser/browser/chrome/icons/default/default48.png \
               /target/usr/share/icons/hicolor/48x48/apps/tor-browser.png \
            || echo "WARN: could not install the Tor Browser icon"
        fi
        in-target update-desktop-database >/dev/null 2>&1 || true
        in-target update-icon-cache >/dev/null 2>&1 || true
        fi
        if [ ! -x /target/usr/local/bin/tor-browser ] || [ ! -e /target/opt/tor-browser/Browser/firefox ]; then
            echo "FATAL: Tor Browser did not install (tarball unpack or wrapper failed)" >&2
            echo "ombra-tbb: install incomplete" > /tmp/ombra-tbb-fail
        fi
    else
        echo "FATAL: Tor Browser tarball not found in /ombra/vendor — the desktop would ship a dead browser launcher" >&2
        echo "ombra-tbb: payload missing from the ISO" > /tmp/ombra-tbb-fail
    fi
fi

phase "apps-begin"
# ---- privacy applications ----------------------------------------------------
# Runs INSIDE the soft subshell: a failure writes a flag file for the fatal section below.
rm -f /tmp/ombra-apps-fail

# Debian packages, one transaction, recommends off: Kleopatra (OpenPGP), OnionShare (through the gateway's onion-service
# broker), Electrum (bitcoin); squashfs-tools stays for tooling that unpacks AppImages
in-target apt-get install -y -o Acquire::Retries=3 -o APT::Install-Recommends=false \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io \
    kleopatra pinentry-qt scdaemon onionshare electrum squashfs-tools proxychains4 \
    >/dev/null 2>&1 \
    || echo "ombra-apps: the Debian application packages did not install" > /tmp/ombra-apps-fail
# onionshare-cli depends on the tor package: the desktop must never run a Tor of its own, the gateway is the only Tor
for u in tor.service tor@default.service tor@.service; do
    in-target systemctl mask "$u" 2>/dev/null || true
done
in-target systemctl enable ombra-socks.socket >/dev/null 2>&1 \
    || echo "ombra-apps: could not enable the local SOCKS forwarder" > /tmp/ombra-apps-fail
# the GnuPG and Electrum homes are 0700 / private; git cannot carry modes on directories
in-target chmod 0700 /etc/skel/.gnupg /home/ombra/.gnupg 2>/dev/null || true
in-target chown -R ombra:ombra /home/ombra/.gnupg /home/ombra/.electrum /home/ombra/.config/onionshare /home/ombra/.config/feather 2>/dev/null || true

# pinned upstream builds: staged from build/vendor, sha256 re-verified here before anything runs
verify_staged() {  # $1 app -> sets APP_FILE (full path) or returns 1
    app_pin="/ombra/vendor/$1.sha256"
    app_name="$(awk -F= '$1=="file"{print $2}' "$app_pin" 2>/dev/null || true)"
    app_want="$(awk -F= '$1=="sha256"{print $2}' "$app_pin" 2>/dev/null || true)"
    APP_FILE="/ombra/vendor/$app_name"
    [ -n "$app_name" ] && [ -f "$APP_FILE" ] || { echo "ombra-apps: $1 payload missing from the ISO" > /tmp/ombra-apps-fail; return 1; }
    app_got="$(sha256sum "$APP_FILE" 2>/dev/null | awk '{print $1}')"
    [ -n "$app_want" ] && [ "$app_got" = "$app_want" ] \
        || { echo "ombra-apps: $1 sha256 mismatch ($app_got != $app_want)" > /tmp/ombra-apps-fail; return 1; }
    return 0
}

# Feather: unpack the AppImage into /opt/feather (no FUSE on the desktop, nothing mounts at run time)
if verify_staged feather; then
    mkdir -p /target/opt/feather /target/var/tmp
    cp "$APP_FILE" /target/var/tmp/feather.AppImage
    chmod 0755 /target/var/tmp/feather.AppImage
    in-target sh -c 'cd /var/tmp && ./feather.AppImage --appimage-extract >/dev/null 2>&1 && cp -a squashfs-root/. /opt/feather/ && rm -rf squashfs-root feather.AppImage' \
        || echo "ombra-apps: Feather would not unpack" > /tmp/ombra-apps-fail
    in-target chmod -R a+rX /opt/feather 2>/dev/null || true
    [ -x /target/opt/feather/usr/bin/feather ] || echo "ombra-apps: Feather is not installed" > /tmp/ombra-apps-fail
fi

# SimpleX: upstream .deb (bundles its own Java runtime); apt resolves its library dependencies
if verify_staged simplex; then
    cp "$APP_FILE" /target/var/tmp/simplex.deb
    in-target apt-get install -y -o Acquire::Retries=3 -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io /var/tmp/simplex.deb \
        >/dev/null 2>&1 \
        || echo "ombra-apps: SimpleX did not install" > /tmp/ombra-apps-fail
    rm -f /target/var/tmp/simplex.deb
    [ -x /target/opt/simplex/bin/simplex ] || echo "ombra-apps: SimpleX is not installed" > /tmp/ombra-apps-fail
    # the package ships a bare launcher entry (Name=simplex, Categories=Unknown) that runs the binary directly:
    # replace it with one that goes through the proxychains wrapper (every connection through the gateway's Tor)
    cat > /target/usr/local/share/applications/simplex-simplex.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=SimpleX Chat
Comment=Private messenger with no accounts or phone numbers, routed through Tor
Exec=/usr/local/bin/simplex
Icon=/opt/simplex/lib/simplex.png
Terminal=false
Categories=Network;InstantMessaging;
Keywords=chat;messenger;simplex
DESK
fi
in-target update-desktop-database >/dev/null 2>&1 || true

) || echo "WARN(non-critical, re-applied post-install): soft section had failures"

# the session stack IS the desktop: a failed transaction must park the
# install (apt exit 0 already guarantees every package configured)
if [ -e /tmp/ombra-session-failed ]; then
    rm -f /tmp/ombra-session-failed
    ombra_fatal "the session-stack apt transaction failed — the desktop would ship unable to log in"
fi

if awk -F: '$1=="sudo"{n=split($4,m,","); for(i=1;i<=n;i++) if(m[i]=="ombra") f=1} END{exit f?0:1}' /target/etc/group; then
    ombra_fatal "ombra is still in the sudo group"
fi

# single: the account was made by the installer with the user's password (no first-use chpasswd will follow): it must
# carry a real hash and not be locked; root stays locked (a TEST build sets a root password for vmrun); no privileged group
if [ -n "$SINGLE" ]; then
    case "$(awk -F: '$1=="ombra" {print $2}' /target/etc/shadow)" in
        '$'?*'$'*) ;;
        *) ombra_fatal "the account ombra has no password hash, or is locked — the installer's password did not land" ;;
    esac
    if [ ! -e /ombra/test-build ]; then
        case "$(awk -F: '$1=="root" {print $2}' /target/etc/shadow)" in
            '!'*|'*'*) ;;
            *) ombra_fatal "root has a usable password — root login must stay disabled" ;;
        esac
    fi
    priv_groups="$(awk -F: '$1 ~ /^(root|sudo|admin|adm|wheel|staff|disk|kmem|shadow|systemd-journal|lxd|docker|libvirt)$/ {n=split($4,m,","); for(i=1;i<=n;i++) if(m[i]=="ombra") print $1}' /target/etc/group)"
    [ -z "$priv_groups" ] || ombra_fatal "ombra is in a privileged group: $(echo $priv_groups)"
    echo "account ombra: password set, groups: $(chroot /target id -nG ombra 2>/dev/null || echo unknown)"
fi

# the privacy applications ship with the image: never release a desktop that is missing one
if [ -e /tmp/ombra-apps-fail ]; then
    apps_reason="$(cat /tmp/ombra-apps-fail)"
    rm -f /tmp/ombra-apps-fail
    ombra_fatal "$apps_reason — the privacy applications are part of the image; not shipping without them"
fi

# Tor Browser is not re-appliable: abort outside the soft subshell if
# the flag was set, and never ship without the browser
if [ -e /tmp/ombra-tbb-fail ]; then
    tbb_reason="$(cat /tmp/ombra-tbb-fail)"
    rm -f /tmp/ombra-tbb-fail
    ombra_fatal "$tbb_reason — Tor Browser is mandatory; not shipping a desktop without it"
fi
if [ ! -x /target/usr/local/bin/tor-browser ] \
   || [ ! -e /target/opt/tor-browser/Browser/firefox ]; then
    ombra_fatal "Tor Browser is not installed on the target (/opt/tor-browser or its wrapper is missing)"
fi

phase "soft-section-done"

# ==== single edition: the gateway as a container inside this VM ==================================================
# Only when the ISO carries the marker (build/make-install-iso.sh single); a two-VM build runs none of this and gets none
# of its files. The container boots from a READ-ONLY ext4 image with a RAM overlay and its own user namespace (a directory
# tree with -U fails on an Amnesic overlay root; squashfs is on the module blacklist), owns the VM's only NIC, and reaches
# this desktop over a veth pair that keeps the two-VM addresses. Every failure parks: an image without a working gateway never ships.
if [ -e /ombra/edition-single ]; then
    phase "single-begin"
    mkdir -p /target/etc/ombra /target/usr/share/ombra /target/var/lib/ombra /target/var/tmp
    printf 'single\n' > /target/etc/ombra/edition || ombra_fatal "could not record the edition"
    for f in gateway-rootfs.tar.gz gateway-container.tar.gz single-rootfs.tar.gz; do
        [ -s "/ombra/$f" ] || ombra_fatal "/ombra/$f is missing from the single-edition ISO"
    done
    GW_TREE=/var/lib/ombra/gateway-tree
    GWT="/target$GW_TREE"
    GW_IMG=/var/lib/ombra/gateway.img
    GW_STATE=/var/lib/ombra/gateway-state
    # a mount left under the tree (mmdebstrap binds /dev and /proc while it works) would let rm -rf reach the installer's own
    gw_tree_unmounted() {
        awk -v p="$GWT" 'index($2, p) == 1 {f=1} END {exit f?1:0}' /proc/mounts \
            || ombra_fatal "something is still mounted under $GWT"
    }

    # the container runtime and the tools that build its image (recommends off: no nss module, no fakechroot)
    in-target apt-get install -y -o Acquire::Retries=3 -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-unsafe-io \
        systemd-container mmdebstrap e2fsprogs >/dev/null 2>&1 \
        || ombra_fatal "systemd-container, mmdebstrap or e2fsprogs did not install — the gateway container cannot be built"
    for t in systemd-nspawn mmdebstrap mke2fs; do
        chroot /target sh -c "command -v $t" >/dev/null 2>&1 || ombra_fatal "the target lacks '$t' after the install"
    done

    phase "single-mmdebstrap"
    # the container tree: minbase trixie, the gateway's runtime packages, over the installer's plain NAT (no proxy)
    gw_tree_unmounted
    rm -rf "$GWT"
    cat > /target/var/tmp/ombra-gw-mmdebstrap.sh <<'MMDEB'
#!/bin/bash
# mmdebstrap hands apt a descriptor number for its hook ("cat >&N"), run by dash, which cannot parse N above 9. The
# installer's chroot inherits enough open descriptors to push N to 11: close every one above stderr first.
for f in /proc/$$/fd/*; do n=${f##*/}; case "$n" in 0|1|2) ;; *[!0-9]*) ;; *) eval "exec $n>&-" 2>/dev/null ;; esac; done
S="main contrib non-free-firmware"
exec mmdebstrap --mode=root --variant=minbase \
    --include=systemd,systemd-sysv,dbus,tor,dnsmasq,nftables,curl,ca-certificates,iproute2,procps,bind9-dnsutils,util-linux,sudo,openssl,less,adduser,passwd,login,libcap2-bin,zsh,e2fsprogs \
    trixie /var/lib/ombra/gateway-tree \
    "deb http://deb.debian.org/debian trixie $S" \
    "deb http://deb.debian.org/debian-security trixie-security $S" \
    "deb http://deb.debian.org/debian trixie-updates $S"
MMDEB
    # in-target sets up /proc, /sys and /dev in the chroot; its own output goes to the syslog, so the build logs to a file
    if ! in-target sh -c 'bash /var/tmp/ombra-gw-mmdebstrap.sh > /var/log/ombra-gateway-build.log 2>&1 </dev/null'; then
        tail -n 20 /target/var/log/ombra-gateway-build.log 2>/dev/null || true
        ombra_fatal "mmdebstrap could not build the gateway container tree (its log is in /var/log/ombra-gateway-build.log)"
    fi
    rm -f /target/var/tmp/ombra-gw-mmdebstrap.sh
    gw_tree_unmounted
    # plain files only: the tree's absolute symlinks (sbin/init) would resolve in the installer, not in the tree
    [ -f "$GWT/usr/bin/tor" ] && [ -f "$GWT/usr/lib/systemd/systemd" ] || ombra_fatal "the gateway container tree has no tor or no systemd"

    phase "single-overlay"
    # identity as the gateway VM's late-command shapes it (no divert: the image is read-only and never upgraded)
    rm -f "$GWT"/etc/update-motd.d/* "$GWT/etc/debian_version"
    # the target's GNU tar, not the installer's BusyBox one: any absolute symlink in the tree resolves inside /target
    cp /ombra/gateway-rootfs.tar.gz /ombra/gateway-container.tar.gz /target/var/tmp/ \
        || ombra_fatal "could not stage the gateway overlays"
    chroot /target tar --warning=no-unknown-keyword -xzf /var/tmp/gateway-rootfs.tar.gz -C "$GW_TREE" \
        || ombra_fatal "the gateway overlay would not unpack into the container tree"
    # container shape: no boot loader, no VM channel, no console; the desktop owns the clock and the updates
    rm -rf "$GWT/boot" "$GWT/etc/default/grub.d" "$GWT/etc/grub.d" "$GWT/etc/qemu" "$GWT/etc/overlayroot.conf"
    rm -f "$GWT"/etc/systemd/network/*.link "$GWT"/etc/systemd/network/*.network \
        "$GWT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    rm -f "$GWT/usr/local/sbin/ombra-update" "$GWT/etc/sudoers.d/ombra-update" "$GWT/etc/ombra/update.conf" \
        "$GWT"/etc/systemd/system/ombra-update-check.* "$GWT"/etc/systemd/system/ombra-update-commit.*
    # the interfaces nspawn names: ombra-upstream (the VM's NIC, DHCP) and ombra-intnet (the veth, 10.55.10.1)
    chroot /target tar --warning=no-unknown-keyword -xzf /var/tmp/gateway-container.tar.gz -C "$GW_TREE" \
        || ombra_fatal "the container network overlay would not unpack"
    rm -f /target/var/tmp/gateway-rootfs.tar.gz /target/var/tmp/gateway-container.tar.gz
    for f in 10-upstream.network 20-intnet.network; do
        [ -f "$GWT/etc/systemd/network/$f" ] || ombra_fatal "the container lacks etc/systemd/network/$f"
    done
    if ls "$GWT"/etc/systemd/network/*.link >/dev/null 2>&1 \
       || grep -l '^Driver=' "$GWT"/etc/systemd/network/*.network >/dev/null 2>&1; then
        ombra_fatal "a driver-matched .link or .network file survived in the container"
    fi
    echo ombra-gateway > "$GWT/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tombra-gateway.local\tombra-gateway\n' > "$GWT/etc/hosts"
    printf '6f6d6272610000000000000000000002\n' > "$GWT/etc/machine-id"
    mkdir -p "$GWT/var/lib/dbus" && ln -sf /etc/machine-id "$GWT/var/lib/dbus/machine-id"
    printf 'single\n' > "$GWT/etc/ombra/edition"

    # the sudoers grants name ombra; the control-port filter runs as its own uid
    chroot "$GWT" sh -c 'id -u ombra >/dev/null 2>&1 || useradd -u 1000 -m -s /usr/sbin/nologin ombra; id -u ombra-torctl >/dev/null 2>&1 || adduser --system --group --no-create-home --home /nonexistent --shell /usr/sbin/nologin ombra-torctl' \
        || ombra_fatal "could not create the container's users"
    [ "$(chroot "$GWT" id -u ombra)" = 1000 ] || ombra_fatal "the container's ombra user is not uid 1000"
    chroot "$GWT" id -u ombra-torctl >/dev/null 2>&1 || ombra_fatal "the container has no ombra-torctl user"
    chmod 0440 "$GWT"/etc/sudoers.d/ombra-* || ombra_fatal "could not set the container's sudoers modes"
    chroot "$GWT" visudo -c >/dev/null || ombra_fatal "the container's sudoers drop-ins do not parse"

    # units: systemctl --root edits the tree offline; a unit file shipped in /etc is removed first, or mask refuses it
    chroot /target systemctl --root="$GW_TREE" enable systemd-networkd.service dnsmasq.service nftables.service ombra-torctl-filter.service >/dev/null 2>&1 \
        || ombra_fatal "could not enable the container's network units"
    for u in systemd-networkd.service dnsmasq.service nftables.service ombra-torctl-filter.service tor.service; do
        [ "$(chroot /target systemctl --root="$GW_TREE" is-enabled "$u" 2>/dev/null)" = enabled ] \
            || ombra_fatal "$u is not enabled in the gateway container"
    done
    for u in ombra-timesync.timer ombra-timesync.service ombra-firstboot.service ombra-update-check.timer ombra-update-commit.timer \
             systemd-networkd-wait-online.service console-getty.service getty@tty1.service systemd-logind.service \
             systemd-remount-fs.service apt-daily.timer apt-daily-upgrade.timer e2scrub_all.timer fstrim.timer; do
        rm -f "$GWT/etc/systemd/system/$u"
        chroot /target systemctl --root="$GW_TREE" mask "$u" >/dev/null 2>&1 || true
        [ "$(readlink "$GWT/etc/systemd/system/$u")" = /dev/null ] || ombra_fatal "$u is not masked in the gateway container"
    done

    # the scrub the gateway VM's release gets, applied to the tree
    rm -rf "$GWT"/var/lib/apt/lists/* "$GWT"/var/cache/apt/*.bin "$GWT"/var/cache/apt/archives/*.deb "$GWT"/var/backups/*.gz \
        "$GWT"/var/crash/* "$GWT"/tmp/* "$GWT"/var/tmp/* "$GWT/var/lib/systemd/random-seed" "$GWT"/root/.*history 2>/dev/null || true
    chroot /target find "$GW_TREE/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true

    # the tools the gateway's own scripts and the leak probe need
    for t in tor dnsmasq nft curl ip setpriv ss dig journalctl; do
        chroot "$GWT" sh -c "command -v $t" >/dev/null 2>&1 || ombra_fatal "the gateway container lacks '$t'"
    done
    # firewall and Tor config byte-identical to the gateway VM's (rules cannot be loaded here: nft -c needs the running kernel)
    mkdir -p /target/var/tmp/ombra-gw-ref
    cp /ombra/gateway-rootfs.tar.gz /target/var/tmp/ombra-gw-ref.tar.gz
    chroot /target tar --warning=no-unknown-keyword -xzf /var/tmp/ombra-gw-ref.tar.gz -C /var/tmp/ombra-gw-ref ./etc/nftables.conf ./etc/tor/torrc \
        || ombra_fatal "could not read the reference firewall and torrc from the gateway overlay"
    for f in etc/nftables.conf etc/tor/torrc; do
        gw_want="$(sha256sum "/target/var/tmp/ombra-gw-ref/$f" | awk '{print $1}')"
        gw_got="$(sha256sum "$GWT/$f" 2>/dev/null | awk '{print $1}')"
        [ -n "$gw_want" ] && [ "$gw_want" = "$gw_got" ] || ombra_fatal "the container's /$f differs from the gateway overlay's"
    done
    rm -rf /target/var/tmp/ombra-gw-ref /target/var/tmp/ombra-gw-ref.tar.gz

    # the container's package versions, for audit
    awk '/^Package: /{p=$2} /^Architecture: /{a=$2} /^Version: /{v=$2} /^Status: .* installed$/{i=1} /^$/{if(i)print p" "v" "a; p=v=a="";i=0} END{if(i)print p" "v" "a}' "$GWT/var/lib/dpkg/status" | sort > /target/usr/share/ombra/gateway-packages.txt \
        && [ -s /target/usr/share/ombra/gateway-packages.txt ] \
        || ombra_fatal "could not record the gateway container's package manifest"

    # Tor's guard state for Persistent boots, idmapped into the container: owned by the container's NUMERIC debian-tor
    # ids, which belong to unrelated accounts on this host, hence the root-only parent
    gw_tor_uid="$(awk -F: '$1=="debian-tor" {print $3}' "$GWT/etc/passwd")"
    gw_tor_gid="$(awk -F: '$1=="debian-tor" {print $3}' "$GWT/etc/group")"
    case "$gw_tor_uid:$gw_tor_gid" in
        :*|*:|*[!0-9:]*) ombra_fatal "could not read debian-tor's uid/gid from the container tree ('$gw_tor_uid:$gw_tor_gid')" ;;
    esac
    rm -rf "/target$GW_STATE"
    mkdir -p "/target$GW_STATE/tor" && chown 0:0 "/target$GW_STATE" && chmod 0700 "/target$GW_STATE" \
        || ombra_fatal "could not create $GW_STATE"
    if [ -d "$GWT/var/lib/tor" ] && [ -n "$(ls -A "$GWT/var/lib/tor")" ]; then
        chroot /target cp -a "$GW_TREE/var/lib/tor/." "$GW_STATE/tor/" || ombra_fatal "could not seed the Tor state directory"
    fi
    chroot /target chown -R "$gw_tor_uid:$gw_tor_gid" "$GW_STATE/tor" && chmod 2700 "/target$GW_STATE/tor" \
        || ombra_fatal "could not hand $GW_STATE/tor to the container's debian-tor ($gw_tor_uid:$gw_tor_gid)"

    phase "single-image"
    # tree size + 40%, rounded up to 16 MiB; -E root_owner as the proven prototype; then the tree goes
    gw_kb="$(chroot /target du -sk "$GW_TREE" | awk '{print $1}')"
    case "$gw_kb" in ''|*[!0-9]*) ombra_fatal "could not size the gateway container tree" ;; esac
    gw_mb=$(( (gw_kb * 140 / 100 + 1023) / 1024 ))
    gw_mb=$(( (gw_mb + 15) / 16 * 16 ))
    echo "gateway tree ${gw_kb} KiB -> image ${gw_mb} MiB"
    rm -f "/target$GW_IMG"
    gw_tree_unmounted
    in-target mke2fs -q -t ext4 -L ombra-gw -m 0 -E root_owner=0:0 -d "$GW_TREE" "$GW_IMG" "${gw_mb}M" \
        || ombra_fatal "mke2fs could not build the gateway image"
    chmod 0600 "/target$GW_IMG" || ombra_fatal "could not set the gateway image mode"
    gw_size="$(chroot /target stat -c %s "$GW_IMG" 2>/dev/null || echo 0)"
    [ "$gw_size" -ge 104857600 ] || ombra_fatal "the gateway image is missing or under 100 MB ($gw_size bytes)"
    gw_tree_unmounted
    rm -rf "$GWT"
    [ ! -e "$GWT" ] || ombra_fatal "the gateway container tree could not be removed"
    # the image is the trust anchor for the Tor side: ombra-gateway-run refuses an image that does not hash to this
    gw_sum="$(sha256sum "/target$GW_IMG" | awk '{print $1}')"
    case "$gw_sum" in ''|*[!0-9a-f]*) ombra_fatal "could not hash the gateway image" ;; esac
    [ "${#gw_sum}" -eq 64 ] || ombra_fatal "the gateway image hash is malformed"
    printf '%s  %s\n' "$gw_sum" "$GW_IMG" > /target/usr/share/ombra/gateway.img.sha256

    phase "single-host"
    # host side (desktop/single): NIC rename, veth managed by NM and the NIC not, the unit and its run script, and the
    # intnet profile bound to the veth by name (it replaces the two-VM profile that matches any ethernet device)
    tar -xzf /ombra/single-rootfs.tar.gz -C /target || ombra_fatal "the single-edition host overlay would not unpack"
    # git cannot carry these modes; NetworkManager ignores a profile that is not 0600
    chmod 0600 /target/etc/NetworkManager/system-connections/*.nmconnection \
        || ombra_fatal "NetworkManager profile mode not set — the link to the gateway container would never come up"
    chmod 0755 /target/usr/local/sbin/ombra-gateway-run || ombra_fatal "ombra-gateway-run is not executable on the target"
    for f in /etc/systemd/network/05-ombra-nic.link /etc/udev/rules.d/86-ombra-gw.rules \
             /etc/NetworkManager/conf.d/20-ombra-single.conf /etc/systemd/system/ombra-gateway.service \
             /usr/local/sbin/ombra-gateway-run; do
        [ -f "/target$f" ] || ombra_fatal "$f is missing from the single-edition target"
    done
    grep -qx 'interface-name=ombra-gw' /target/etc/NetworkManager/system-connections/ombra-intnet.nmconnection \
        || ombra_fatal "the intnet profile is not bound to ombra-gw — it would claim the VM's own NIC"
    # the desktop firewall replaced by its single twin: the gateway rules bound to the veth, nothing through the VM's own card
    [ "$(grep -c '^[^#]*ifname "ombra-gw" ip [sd]addr 10.55.10.1 ' /target/etc/nftables.conf)" = 3 ] \
        || ombra_fatal "/etc/nftables.conf is not the single edition's (gateway rules bound to ombra-gw)"
    [ -x /target/usr/bin/systemd-nspawn ] || ombra_fatal "systemd-nspawn is missing from the target"
    in-target systemctl enable ombra-gateway.service >/dev/null 2>&1 \
        || ombra_fatal "systemctl enable failed for ombra-gateway.service"
    [ -L /target/etc/systemd/system/multi-user.target.wants/ombra-gateway.service ] \
        || ombra_fatal "ombra-gateway.service is not enabled — the single edition would boot with no gateway"
else
    printf 'two-vm\n' > /target/etc/ombra/edition || ombra_fatal "could not record the edition"
fi

# ---- boot face: plain "quiet" kernel line (unlock is the keyscript) ----
# no effect on the built grub.cfg: grub-mkconfig sources /etc/default/grub.d/*.cfg after this file, and 50-ombra.cfg sets the
# full hardened GRUB_CMDLINE_LINUX_DEFAULT (the drop-in owns it); this only keeps /etc/default/grub from reading Debian's default
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=0"/' /target/etc/default/grub
# boot-mode menu: the 09_ombra generator is the only source of entries; the stock generators stay disarmed
chmod 0755 /target/etc/grub.d/09_ombra \
    || ombra_fatal "boot-mode generator missing from the target overlay"
# a dpkg statoverride keeps them 0644 across grub-common upgrades (a bare chmod is undone by the next unpack); registered
# even for absent ones so a later install (os-prober) lands disarmed; --list guard: --add refuses an existing override
for g in 10_linux 20_linux_xen 30_os-prober 30_uefi-firmware; do
    in-target sh -c "dpkg-statoverride --list /etc/grub.d/$g >/dev/null 2>&1 || dpkg-statoverride --update --add root root 0644 /etc/grub.d/$g" \
        || ombra_fatal "dpkg-statoverride failed for /etc/grub.d/$g"
    grep -qxE "root root 0?644 /etc/grub.d/$g" /target/var/lib/dpkg/statoverride \
        || ombra_fatal "/etc/grub.d/$g has no 0644 statoverride — a grub-common upgrade would re-arm it"
    [ ! -e "/target/etc/grub.d/$g" ] || chmod 0644 "/target/etc/grub.d/$g"
    [ ! -x "/target/etc/grub.d/$g" ] || ombra_fatal "/etc/grub.d/$g is still executable — the stock entries would come back"
done
GT=/target/boot/grub/themes/ombra
mkdir -p /target/boot/grub/fonts
cp /target/usr/share/grub/unicode.pf2 /target/boot/grub/fonts/unicode.pf2 \
    || ombra_fatal "unicode.pf2 missing — the graphical boot menu would have no base font"
in-target grub-mkfont -s 18 -r 0x20-0x7e,0xa0-0x17f,0x2010-0x2026 -o /boot/grub/themes/ombra/ombra-16.pf2 \
    /usr/share/fonts/ombra/jetbrainsmono-nerdfont/JetBrainsMonoNerdFont-Regular.ttf \
    || ombra_fatal "grub-mkfont failed for the menu font"
in-target grub-mkfont -s 26 -r 0x20-0x7e -o /boot/grub/themes/ombra/ombra-title.pf2 \
    /usr/share/fonts/ombra/jetbrainsmono-nerdfont/JetBrainsMonoNerdFont-Bold.ttf \
    || ombra_fatal "grub-mkfont failed for the title font"
pf2_name() { dd if="/target$1" bs=96 count=1 2>/dev/null | tr -c 'A-Za-z0-9 ._-' '|' | sed 's/.*NAME|*//; s/|.*//'; }
f16="$(pf2_name /boot/grub/themes/ombra/ombra-16.pf2)"
ftitle="$(pf2_name /boot/grub/themes/ombra/ombra-title.pf2)"
[ -n "$f16" ] && [ -n "$ftitle" ] || ombra_fatal "could not read the menu font names — the theme would fall back to the default font"
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
# recurse=1 (overlayroot's default, pinned): /home is its own mount and must sit under the RAM overlay too
grep -q 'overlayroot=tmpfs:recurse=1' "$GCFG" \
    || ombra_fatal "grub.cfg lacks the overlayroot=tmpfs:recurse=1 kernel parameter"
grep -q 'ipv6.disable=1' "$GCFG" \
    || ombra_fatal "grub.cfg entries lost ipv6.disable=1"
grep -q 'init_on_alloc=1' "$GCFG" \
    || ombra_fatal "grub.cfg entries lost the hardened kernel cmdline"

phase "update-grub-done"
# ombra-boot wiring (binaries + units + initramfs hook ship in the overlay)
chmod 0755 /target/usr/local/libexec/ombra/ombra-askpass /target/usr/local/libexec/ombra/ombra-welcome \
    || ombra_fatal "boot binaries not executable on the target"
# keyscript= must be the REAL rootfs path: cryptsetup's hook validates it against the root fs at initrd build time.
# tries=0: ombra owns retries (cryptroot's 3-strike drops to the initramfs shell); x-initrd.attach completes the entry shape.
if ! grep -q 'keyscript=' /target/etc/crypttab; then
    # single-line awk (the walker in tests/build flags multi-line quoted regions)
    awk '/^[^#]/ && $NF ~ /^luks,/ && !wired && index($0, "keyscript=") == 0 { $0 = $0 ",x-initrd.attach,keyscript=/usr/local/libexec/ombra/ombra-askpass,tries=0"; wired = 1 } { print }' /target/etc/crypttab > /target/etc/crypttab.ombra \
        && mv /target/etc/crypttab.ombra /target/etc/crypttab
fi
echo "crypttab root entry: $(grep 'keyscript=' /target/etc/crypttab | head -1 || true)"
# CRITICAL: without the keyscript every boot shows the stock unlock prompt
grep -q 'keyscript=/usr/local/libexec/ombra/ombra-askpass' /target/etc/crypttab \
    || ombra_fatal "keyscript not wired into /target/etc/crypttab"
grep -q 'tries=0' /target/etc/crypttab \
    || ombra_fatal "tries=0 missing (3-strike initramfs shell lockout)"
# no TRIM through LUKS: discards reveal which blocks are free (usage pattern, filesystem type); root entry only, cryptswap carries none
sed -i '/^[^#].*keyscript=/s/,discard,/,/; /^[^#].*keyscript=/s/,discard$//; /^[^#].*keyscript=/s/,x-initrd\.attach,x-initrd\.attach/,x-initrd.attach/' /target/etc/crypttab
! grep -v '^#' /target/etc/crypttab | grep 'keyscript=' | grep -q 'discard' \
    || ombra_fatal "discard still set on the root crypttab entry — TRIM would pass through LUKS"
in-target systemctl mask fstrim.timer fstrim.service >/dev/null 2>&1 \
    || ombra_fatal "could not mask fstrim"
[ "$(readlink /target/etc/systemd/system/fstrim.timer)" = /dev/null ] \
    || ombra_fatal "fstrim.timer is not masked"
if [ -z "$SINGLE" ]; then
in-target systemctl enable ombra-setup-gate.service ombra-welcome.service ombra-askpass.service ombra-askpass-fallback.service >/dev/null 2>&1 \
    || ombra_fatal "systemctl enable failed for the ombra boot units"
for u in ombra-setup-gate.service ombra-welcome.service ombra-askpass.service ombra-askpass-fallback.service; do
    [ -f "/target/etc/systemd/system/$u" ] || ombra_fatal "$u missing from the target overlay"
done
for l in graphical.target.wants/ombra-setup-gate.service graphical.target.wants/ombra-welcome.service \
         multi-user.target.wants/ombra-askpass.service multi-user.target.wants/ombra-askpass-fallback.service; do
    [ -L "/target/etc/systemd/system/$l" ] \
        || ombra_fatal "enablement symlink $l missing — masking tty1 would leave a black console"
done
else
# single: no first-use screen, ever. The setup gate stays (it proves at every boot that the build key does not open the
# disk, and only then lets SDDM start); the first-use unit is removed and masked, so even a gate that fails cannot hand
# the console to it. The ombra-welcome binary stays: the gate runs it as `ombra-welcome --probe`.
in-target systemctl enable ombra-setup-gate.service ombra-askpass.service ombra-askpass-fallback.service >/dev/null 2>&1 \
    || ombra_fatal "systemctl enable failed for the ombra boot units"
for u in ombra-setup-gate.service ombra-askpass.service ombra-askpass-fallback.service; do
    [ -f "/target/etc/systemd/system/$u" ] || ombra_fatal "$u missing from the target overlay"
done
for l in graphical.target.wants/ombra-setup-gate.service \
         multi-user.target.wants/ombra-askpass.service multi-user.target.wants/ombra-askpass-fallback.service; do
    [ -L "/target/etc/systemd/system/$l" ] \
        || ombra_fatal "enablement symlink $l missing — masking tty1 would leave a black console"
done
rm -f /target/etc/systemd/system/ombra-welcome.service /target/etc/systemd/system/graphical.target.wants/ombra-welcome.service
in-target systemctl mask ombra-welcome.service >/dev/null 2>&1 || ombra_fatal "could not mask ombra-welcome.service"
[ "$(readlink /target/etc/systemd/system/ombra-welcome.service)" = /dev/null ] \
    || ombra_fatal "ombra-welcome.service is not masked — the single edition must never show the first-use screen"
fi
[ -f /target/etc/systemd/system/sddm.service.d/10-ombra-firstuse.conf ] \
    || ombra_fatal "sddm first-use gate drop-in missing from the target"
# tty1 belongs to ombra; in-target CHROOTS, so plain mask inside the
# chroot is correct (--root=/target would double-path and silently no-op)
in-target systemctl mask getty@tty1.service autovt@tty1.service >/dev/null 2>&1 \
    || ombra_fatal "could not mask getty@tty1"
for u in getty@tty1.service autovt@tty1.service; do
    [ "$(readlink "/target/etc/systemd/system/$u")" = /dev/null ] \
        || ombra_fatal "$u is not masked — the stock getty would fight ombra for tty1"
done
# plymouth must not exist: plymouth-quit-wait wedges the boot in this VM
purge_present 'plymouth*'
in-target systemctl mask plymouth-quit.service plymouth-quit-wait.service >/dev/null 2>&1 || true
# the unlock engine must be in /target BEFORE the rebuild; verify the
# BUILT ARTIFACT (lsinitramfs), never package state — presence is not function
if ! in-target dpkg -s cryptsetup-initramfs >/dev/null 2>&1; then
    # refresh the index (d-i may have cleaned it) and keep apt's staging
    # on the root LV — /target/tmp may be a small tmpfs
    in-target sh -c 'apt-get update -o Acquire::Retries=2 >/dev/null 2>&1 || true'
    in-target apt-get install -y --no-install-recommends -o APT::ExtractTemplates::TempDir=/var/tmp cryptsetup-initramfs >/dev/null 2>&1 \
        || ombra_fatal "cryptsetup-initramfs could not be installed — the rebuilt initrd would ship without the unlock engine"
fi
for pk in cryptsetup cryptsetup-bin dmsetup; do
    in-target dpkg -s "$pk" >/dev/null 2>&1 \
        || ombra_fatal "$pk is not installed — first-use LUKS re-encryption could not run"
done
phase "initramfs-begin"
# rebuild the initrd so the hook pulls ombra-askpass in at the crypttab path
mv /target/etc/initramfs-tools/update-initramfs.conf.ombra-orig /target/etc/initramfs-tools/update-initramfs.conf
in-target update-initramfs -u -k all >/dev/null 2>&1 \
    || ombra_fatal "update-initramfs failed — the boot cannot be verified, so it cannot ship"
phase "initramfs-done"
# a rebuilt initrd without Debian's cryptroot script can never unlock the disk
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q "scripts/local-top/cryptroot"'; then
    ombra_fatal "the rebuilt initrd has no cryptroot script — the machine could never unlock its own disk (cryptsetup-initramfs was missing at build time)"
fi
# the keyscript binary is present only if OUR hook ran (cryptsetup's own
# hook copies nothing for it)
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q "usr/local/libexec/ombra/ombra-askpass"'; then
    ombra_fatal "ombra-askpass missing from the rebuilt initrd — the boot would show the stock unlock prompt"
fi
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q "init-bottom/overlayroot"'; then
    ombra_fatal "the rebuilt initrd has no overlayroot script — the Amnesic boot mode would silently persist"
fi
# the unlock screen needs the virtio GPU driver in the initrd, or a QEMU/UTM machine shows "Display output is not active" at every unlock
if ! in-target sh -c 'lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q -E "virtio[-_]gpu[.]ko"'; then
    ombra_fatal "the rebuilt initrd has no virtio_gpu driver — the disk-unlock screen would be blank under QEMU/UTM"
fi
grep -qx 'overlayroot=""' /target/etc/overlayroot.conf \
    || ombra_fatal "overlayroot.conf is not persistent by default — the desktop would boot amnesic without being asked"

# ---- resolver: the gateway's DNS from the first boot ----
# the installer left its own DHCP resolv.conf (the hypervisor's NAT resolver and search domain), which NetworkManager only
# rewrites once the link to the gateway is up: replace it now that no step below needs the installer's network.
# A plain file, so NetworkManager keeps managing it (rc-manager auto writes a regular /etc/resolv.conf).
rm -f /target/etc/resolv.conf
printf 'nameserver 10.55.10.1\n' > /target/etc/resolv.conf
[ "$(cat /target/etc/resolv.conf)" = 'nameserver 10.55.10.1' ] \
    || ombra_fatal "/etc/resolv.conf does not name the gateway alone — the installer's NAT resolver would ship"

# ---- clock: the machine ships UTC (no timezone fingerprint) ----
ln -sf /usr/share/zoneinfo/UTC /target/etc/localtime
# hwclock REWRITES adjtime, so the forced UTC stamp must land after it
# (in-target the call has misbehaved and left LOCAL behind)
in-target hwclock --systohc --utc >/dev/null 2>&1 || true
printf 'UTC\n' > /target/etc/timezone
printf '0.0 0 0.0\n0\nUTC\n' > /target/etc/adjtime
tail -1 /target/etc/adjtime | grep -qx 'UTC' \
    || ombra_fatal "adjtime does not say UTC — the RTC would ship with a LOCAL-timezone fingerprint"

# the exact Debian package versions in this image, for audit: the suite is live trixie at build time, not a snapshot
mkdir -p /target/usr/share/ombra
awk '/^Package: /{p=$2} /^Architecture: /{a=$2} /^Version: /{v=$2} /^Status: .* installed$/{i=1} /^$/{if(i)print p" "v" "a; p=v=a="";i=0} END{if(i)print p" "v" "a}' /target/var/lib/dpkg/status | sort > /target/usr/share/ombra/packages.txt \
    && [ -s /target/usr/share/ombra/packages.txt ] \
    || ombra_fatal "could not record the package manifest"

phase "scrub"
# release scrub: the shipped disk carries no build residue (best-effort by design)
# (this empties every file under /var/log, ombra-late.log included: a shipped disk keeps only the lines written after it)
in-target sh -c 'rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/backups/*.gz /var/crash/* /tmp/* /var/tmp/* /var/log/installer 2>/dev/null || true; apt-get clean >/dev/null 2>&1 || true; find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true; rm -f /root/.*history /home/*/.*history /root/.viminfo /home/*/.viminfo 2>/dev/null || true' || true

# single: the gateway image and its recorded hash are immutable (ext4 +i): not even root replaces them without first
# clearing the flag, which ombra-update does around a signed gateway image update
if [ -n "$SINGLE" ]; then
    chroot /target chattr +i /var/lib/ombra/gateway.img /usr/share/ombra/gateway.img.sha256 \
        || ombra_fatal "could not make the gateway image and its hash immutable"
    for f in /var/lib/ombra/gateway.img /usr/share/ombra/gateway.img.sha256; do
        chroot /target lsattr "$f" 2>/dev/null | awk '{exit !($1 ~ /i/)}' || ombra_fatal "$f is not immutable"
    done
fi


phase "residue"
# release installs park on a live hit; the single edition installs on the user's own machine and only reports
RESIDUE_STRICT=1; [ -z "$SINGLE" ] || RESIDUE_STRICT=0
RESIDUE_ERE="$(residue_ere)"
[ -n "$RESIDUE_ERE" ] || ombra_fatal "residue: could not read the installer's own network addresses"
for m in "" /boot /home; do
    d="$(residue_mounted "/target$m")"; [ -n "$d" ] || continue
    [ "$(awk -v m="/target$m" '$2 == m {print $3; exit}' /proc/mounts)" = ext4 ] || continue
    residue_wipe "$d" "${m:-/}" ext4
done
# the swap volume (no filesystem; formatted afresh by cryptswap at every boot): off for the scan, hits zeroed
if [ -b /dev/mapper/vg0-swap ]; then
    ! grep -q '^/dev/mapper/vg0-swap \|^/dev/dm-' /proc/swaps || swapoff -a 2>/dev/null || true
    residue_wipe /dev/mapper/vg0-swap swap raw
fi

# LAST: the success stamp — its absence on a built disk means late.sh stopped before here; such a disk never
# reached the scrub, so /var/log/ombra-late.log still holds the whole run
touch /target/var/lib/ombra/late-ran
phase "complete"
echo "=== ombra late.sh COMPLETE ==="
