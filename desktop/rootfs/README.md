# desktop/rootfs - the Ombra desktop overlay

`build/make-install-iso.sh` packs this directory, together with
`desktop/preseed.cfg` and `desktop/late-command.sh`, into the installer
initrd; the late command untars it over `/target`. It ships configuration
and vendored assets only. Packages come from `pkgsel/include` in the
preseed plus the late command's single recommends-off apt transaction
(kde-plasma-desktop, sddm, kwin-x11, kitty, qt-style-kvantum, plasma-nm,
plasma-pa, systemsettings, kio-extras, kscreen, kmenuedit,
breeze-gtk-theme, libpam-systemd, fastfetch) from the pinned trixie suite.
Vendored asset provenance is in `usr/share/ombra-assets/README.md`.

The session is KDE Plasma on X11 (SDDM, Plasma X11 session).

## Identity

| Path | What it is |
|------|------------|
| `usr/lib/os-release`, `etc/os-release` (symlink) | NAME and PRETTY_NAME are "Ombra" with no version; `ID=ombra`, `ID_LIKE=debian`; `VERSION_CODENAME=trixie` must stay (apt sources are codename-keyed); the late command dpkg-diverts `/usr/lib/os-release` |
| `etc/issue`, `etc/issue.net` | Console pre-login line and network banner; no version, kernel or host detail |
| `etc/motd`, `etc/update-motd.d/README` | Static motd; `update-motd.d` must stay script-free (the late command deletes base-files' `10-uname`) |
| `etc/lsb-release` | `lsb_release` compatibility: "Ombra", codename trixie, release mirrors the machine-facing `VERSION_ID` |
| `etc/debian_version` | Diverted away and deleted by the late command; no Debian version string ships |
| `/etc/machine-id` (written by the late command) | Fixed generic value, identical on every install |
| `etc/skel/.config/fastfetch/` | Branded panel: `ring.ans` is the ring from `core/src/art.rs` as raw ANSI; the tor line runs `ombra-statusd --once` under a 1 s timeout and shows "tor: unknown" when it is absent |

Hostname is `ombra`, set in the preseed and repaired by the late command.

## Network

| Path | What it is |
|------|------------|
| `etc/network/interfaces` | Loopback only, so NetworkManager manages the NIC |
| `etc/NetworkManager/system-connections/ombra-intnet.nmconnection` | Static 10.55.10.100/24, gateway and DNS 10.55.10.1, IPv6 off, matches any ethernet device (no MAC pin); must be mode 600 or NetworkManager ignores it |
| `etc/NetworkManager/conf.d/10-ombra-no-auto-default.conf` | `no-auto-default=*`: no auto-created DHCP profile that could route around the gateway |
| `etc/nftables.conf` | The desktop's own firewall: input, output and forward policy drop; the private link and ICMP echo are the accepts |
| `etc/sysctl.d/60-ombra-desktop.conf` | Kernel hardening and IPv6 off; no oops-limit pinning, so a panic stays on screen |
| `usr/local/sbin/ombra-timesync` + timer | Tor-only clock sync; writes `ok` or `stale` to `/run/ombra/timesync` for `ombra-statusd` |

There is deliberately no `etc/resolv.conf` (the resolver comes from the
gateway via NetworkManager) and no `etc/systemd/network/` (NetworkManager
is the only network manager on the desktop).

## Boot and first use

| Path | What it is |
|------|------------|
| `usr/local/libexec/ombra/*`, `etc/systemd/system/ombra-*.service` | The branded LUKS unlock and the first-use setup that owns tty1 before SDDM |
| `etc/systemd/system/sddm.service.d/10-ombra-firstuse.conf` | SDDM is gated on `/run/ombra/setup-complete`, which `ombra-setup-gate` re-proves against the LUKS header every boot |
| `etc/sddm.conf.d/50-ombra.conf` | X11 display server, Colloid-dark greeter theme, no autologin; sets no `Session=` key because sddm has no such key |
| `etc/default/grub.d/50-ombra.cfg`, `99-ombra-brand.cfg` | Kernel hardening set (never `init_on_free`) and GRUB branding; the boot menu has no timeout |
| `etc/grub.d/09_ombra`, `boot/grub/themes/ombra/` | The only boot-entry generator (Persistent and Amnesic) and its theme |
| `etc/overlayroot.conf`, `etc/systemd/system/systemd-remount-fs.service.d/` | Overlay defaults (persistent) and the remount drop-in for overlayfs |
| `etc/modprobe.d/ombra-blacklist.conf` | Blacklist of rare filesystems, bluetooth, exotic protocols and absent hardware |

## Session defaults (skel)

| Path | What it is |
|------|------------|
| `etc/skel/.config/kdedefaults/` | KConfig defaults layer: Colloid-dark look-and-feel, Kvantum-dark style, ColloidDark colors, Kaze-dark icons, phinger cursors, Noto Sans and JetBrains Mono Nerd Font, kitty, translucency block in `kwinrc`; the look-and-feel id must match in both files |
| `etc/skel/.config/plasma-*` (absent) | The layout is generated at first login from the look-and-feel `contents/layouts/org.kde.plasma.desktop-layout.js`; that filename is what the loader asks for, and its launchers value must be a JS array |
| `etc/skel/.config/baloofilerc` | Baloo file indexer off |
| `etc/skel/.config/kscreenlockerrc` | 10-minute idle lock, lock on resume, lock-screen wallpaper pinned to `ombra-02-4k` |
| `etc/skel/.config/klipperrc` | `KeepClipboardContents=false`, `MaxClipItems=1` (KConfigXT clamps 0 to 1) |
| `etc/skel/.local/state/UserFeedback.org.kde.plasmashell`, `.config/KDE/UserFeedback.conf` | KDE telemetry off, prompt suppressed |
| `etc/skel/.config/kitty/kitty.conf` | Ombra palette, JetBrains Mono Nerd Font, ligatures disabled (they fuse the ring art's `==`, `-=`, `+=` runs) |
| `etc/skel/.config/Kvantum/kvantum.kvconfig` | Selects the vendored ColloidDark Kvantum theme |
| `etc/skel/.config/gtk-{3,4}.0/settings.ini` | Dark theme, Kaze-dark icons and phinger cursors for the two GTK apps |
| `etc/skel/.config/systemd/user/ombra-statusd.service`, `.config/autostart/org.ombra.status-ensure.desktop` | Start the Tor-status daemon with the session |
| `etc/xdg/autostart/org.kde.discover.notifier.desktop`, `org.kde.kdeconnect.daemon.desktop` | `Hidden=true` tombstones under upstream's filenames; the late command also purges and masks both |
| `usr/share/plasma/plasmoids/org.kde.plasma.clipboard/metadata.json` | Ombra override of KDE's clipboard applet metadata: tray category removed, `EnabledByDefault=false`, so klipper never runs and history is never written |
| `usr/local/share/applications/kitty.desktop`, `tor-browser.desktop` | Launcher overrides by XDG precedence; Tor Browser uses an absolute icon path and `StartupWMClass` so the dock shows one tile |

## Plasma plasmoids

| Path | What it is |
|------|------------|
| `usr/share/plasma/plasmoids/org.ombra.status/` | Tor-status LED (dot and tooltip): polls `ombra-statusd --once` every 31 s through the `executable` dataengine and renders the pinned JSON state; malformed output greys out; placed leftmost in the top bar by the layout script |
| `usr/share/plasma/plasmoids/luisbocanegra.panel.colorizer/` | Panel Colorizer, installed verbatim and not in the default layout (its default would show a widget blob in the dock) |

## Themes and assets

| Path | What it is |
|------|------------|
| `usr/share/plasma/look-and-feel/com.github.vinceliuice.Colloid-dark/` | Colloid look-and-feel with Ombra's own dock layout |
| `usr/share/plasma/desktoptheme/Colloid-dark/` | Plasma style |
| `usr/share/aurorae/themes/Colloid-dark{,-round}/` | Window decorations |
| `usr/share/color-schemes/ColloidDark.colors` | Color scheme |
| `usr/share/Kvantum/ColloidDark/` | Kvantum Qt theme |
| `usr/share/sddm/themes/Colloid-dark/` | SDDM greeter (Qt6 variant) with `ombra-02-4k` as `background.png` |
| `usr/share/icons/Kaze-dark/`, `usr/share/icons/phinger-cursors-light/` | Icon and cursor themes |
| `usr/share/fonts/ombra/jetbrainsmono-nerdfont/` | JetBrains Mono Nerd Font core weights with OFL text; Noto Sans comes from `fonts-noto-core` |
| `usr/share/backgrounds/ombra/*`, `usr/share/wallpapers/Colloid-dark/` | Ombra wallpapers; `ombra-02-4k` is the session wallpaper |
| `usr/local/bin/ombra`, `ombra-statusd` | Connectivity panel and Tor-status daemon (`core/` crate); the daemon caches for 30 s and serves JSON on `$XDG_RUNTIME_DIR/ombra-status.sock` |

## Not shipped

| Item | Reason |
|------|--------|
| powerdevil | Not installed by the session transaction: no suspend daemon (a suspended VM cannot reliably wake under Fusion on Apple Silicon), so no screen blanking |
| xdg-desktop-portal-* | No portal-dependent workflow exists in the image |
| Colloid-gtk-theme | Only two small GTK apps ship; `settings.ini` covers them |
| Crypto wallets | By decision; adding one needs a new pin and a new verification pass |
