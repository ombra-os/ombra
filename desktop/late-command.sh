#!/bin/sh
# desktop/late-command.sh — the d-i preseed/late_command payload (invoked as the bare path
# /ombra/late.sh: debconf eats \n escapes). /target is the installed system; /ombra/* is the preseed carrier.

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
echo "=== ombra late.sh $(date -u +%FT%TZ) ==="

phase() {
    printf '%s %s\n' "$(date +%T)" "$1"
    [ -c /dev/ttyAMA0 ] && printf '%s ombra-late %s\n' "$(date +%T)" "$1" > /dev/ttyAMA0 2>/dev/null
    return 0
}

soft() { "$@" || echo "WARN(non-critical, re-applied post-install): $* failed"; }

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

phase "dpkg-configure-done"
# --- Per-boot random-key swap ("cryptswap") --------------------------------
# dm-crypt layer over the swap LV, keyed from /dev/urandom at every activation; the LV is DISCOVERED from fstab.
swap_spec="$(awk '!/^#/ && $3=="swap" {print $1; exit}' /target/etc/fstab)"
swap_lv="$(in-target findfs "$swap_spec" 2>/dev/null || true)"
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
chmod 0755 /target/usr/local/sbin/ombra-askpass-fallback /target/usr/local/sbin/ombra-timesync \
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
in-target find /usr/lib -path '*open-vm-tools/plugins/*' \( -name libdndcp.so -o -name libhgfsServer.so \) -delete >/dev/null 2>&1 || true
if [ -n "$(in-target find /usr/lib -path '*open-vm-tools/plugins/*' \( -name libdndcp.so -o -name libhgfsServer.so \) 2>/dev/null)" ]; then
    ombra_fatal "open-vm-tools clipboard/dnd/hgfs plugins still present — host-guest channel would stay open"
fi

# --- fixed machine-id: one anonymity set shared by every install
printf '6f6d6272610000000000000000000001\n' > /target/etc/machine-id
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id

# Tor-only time sync through the gateway (units ship in the overlay)
in-target systemctl enable ombra-timesync.timer >/dev/null 2>&1 || true
chmod 0755 /target/usr/local/sbin/ombra-update /target/usr/local/bin/ombra-update-notify /target/usr/local/bin/ombra-update-gui
in-target systemctl enable ombra-update-check.timer ombra-update-commit.timer >/dev/null 2>&1 || true
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
        if [ -n "$tbb_want" ] && [ "$tbb_got" != "$tbb_want" ]; then
            echo "FATAL: staged Tor Browser tarball sha256 mismatch ($tbb_got != $tbb_want) — refusing to install an unauditable browser" >&2
            echo "ombra-tbb: sha256 mismatch" > /tmp/ombra-tbb-fail
        else
        echo "installing Tor Browser from the pinned tarball ($(basename "$tbb_tar"))"
        mkdir -p /target/opt/tor-browser /target/var/tmp
        cp "$tbb_tar" /target/var/tmp/ombra-tbb.tar.xz
        # unpack with /target's GNU tar — the d-i env's tar may be BusyBox (no -J / --strip-components support)
        in-target tar -xJf /var/tmp/ombra-tbb.tar.xz -C /opt/tor-browser --strip-components=1 \
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
user_pref("network.proxy.socks_port", 9050);
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
export TOR_SOCKS_PORT=9050
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
# ---- boot face: plain "quiet" kernel line (unlock is the keyscript) ----
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=0"/' /target/etc/default/grub
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
grep -q 'overlayroot=tmpfs' "$GCFG" \
    || ombra_fatal "grub.cfg lacks the overlayroot=tmpfs kernel parameter"
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
echo "crypttab root entry: $(grep '^nvme0n1p4_crypt\|keyscript=' /target/etc/crypttab | head -1 || true)"
# CRITICAL: without the keyscript every boot shows the stock unlock prompt
grep -q 'keyscript=/usr/local/libexec/ombra/ombra-askpass' /target/etc/crypttab \
    || ombra_fatal "keyscript not wired into /target/etc/crypttab"
grep -q 'tries=0' /target/etc/crypttab \
    || ombra_fatal "tries=0 missing (3-strike initramfs shell lockout)"
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
in-target update-initramfs -u >/dev/null 2>&1 \
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
grep -qx 'overlayroot=""' /target/etc/overlayroot.conf \
    || ombra_fatal "overlayroot.conf is not persistent by default — the desktop would boot amnesic without being asked"

# ---- clock: the machine ships UTC (no timezone fingerprint) ----
ln -sf /usr/share/zoneinfo/UTC /target/etc/localtime
# hwclock REWRITES adjtime, so the forced UTC stamp must land after it
# (in-target the call has misbehaved and left LOCAL behind)
in-target hwclock --systohc --utc >/dev/null 2>&1 || true
printf 'UTC\n' > /target/etc/timezone
printf '0.0 0 0.0\n0\nUTC\n' > /target/etc/adjtime
tail -1 /target/etc/adjtime | grep -qx 'UTC' \
    || ombra_fatal "adjtime does not say UTC — the RTC would ship with a LOCAL-timezone fingerprint"

phase "scrub"
# release scrub: the shipped disk carries no build residue (best-effort by design)
in-target sh -c 'rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/backups/*.gz /var/crash/* /tmp/* /var/tmp/* /var/log/installer 2>/dev/null || true; apt-get clean >/dev/null 2>&1 || true; find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true; rm -f /root/.*history /home/*/.*history /root/.viminfo /home/*/.viminfo 2>/dev/null || true' || true

# LAST: the success stamp — its absence on a built disk means the
# overlay never fully landed (read /var/log/ombra-late.log)
touch /target/var/lib/ombra/late-ran
phase "complete"
echo "=== ombra late.sh COMPLETE ==="
