# Ombra desktop

Debian trixie (arm64), KDE Plasma on X11, LUKS2 (argon2id) full-disk
encryption, per-boot random-key swap. Its only network link is the
private link to the gateway (static 10.55.10.100/24; gateway and DNS
10.55.10.1). Isolation is topological: one NIC, no NAT, no bridge, no
second adapter, ever (`docs/DESIGN.md`, invariant 1).

## Contents

| Path | Role |
|---|---|
| `preseed.cfg` | Unattended installer recipe: LUKS2 + LVM, generic identity, base package set, no display manager, no wallet |
| `late-command.sh` | Installer finisher, see below |
| `rootfs/` | The shipped filesystem delta: configuration and vendored assets (`rootfs/README.md`) |

`late-command.sh` steps:

| Step | Effect |
|---|---|
| Identity | Diverts Debian's identity files |
| Session transaction | One recommends-off install of `kde-plasma-desktop`, `sddm`, `kwin-x11`, `kitty`, `kvantum`, `fastfetch`; a failure parks the installer |
| Overlay | Unpacks `rootfs/` |
| Unlock | Wires crypttab (keyscript, `tries=0`), rebuilds the initramfs around the Ombra unlock engine |
| Tor Browser | Installs the sha256-pinned alpha build, wrapped for the gateway's SOCKS port |
| Cleanup | Purges and masks Discover, KDE Connect, plymouth and telemetry surfaces |
| Firewall | Enables the local default-drop nftables policy |
| Boot menu | Builds the themed GRUB menu and fonts |
| Failure | Every hard assertion parks on a visible console; the installer never powers off on failure |

`build/make-install-iso.sh desktop` packs these into the pinned netinst
initrd. It fails if the four Rust binaries in the overlay (`ombra-askpass`,
`ombra-welcome`, `ombra`, `ombra-statusd`) differ from `core/dist/aarch64/`,
and stages Tor Browser only after its sha256 verifies. Nothing downloads at
install time except Debian packages from the pinned suite.

## The machine

| Area | Value |
|---|---|
| Identity | Hostname `ombra`, fixed generic `machine-id`; `os-release` says "Ombra" (`ID=ombra`); `/usr/lib/os-release` and `/etc/debian_version` are dpkg-diverted |
| Disk | LUKS2 (argon2id) root; cryptswap with a fresh key per activation |
| Install passphrase | Public build value `ombra-disk`; first use rotates it before the greeter may start (sddm is gated on `/run/ombra/setup-complete`, re-proved every boot) |
| Session | Plasma on X11 (Wayland entry diverted); open-vm-tools display auto-fit needs X11 |
| Look | Colloid-dark, Kaze-dark icons, phinger cursors, JetBrains Mono Nerd Font, kitty, `org.ombra.status` Tor LED, floating dock |
| IPv6 | Off at three layers: sysctl, NetworkManager profile, nft table |
| Remote access | No sshd; build and test access is vmrun guest operations |
| Apps | Tor Browser, KeePassXC; no crypto wallet |
| Power | No suspend daemon; screen blanking off |

## Boot modes

The GRUB menu waits for a choice; it never auto-starts.

| Entry | Effect |
|---|---|
| Ombra — Persistent (highlighted first) | Encrypted disk and home directory persist |
| Ombra — Amnesic (RAM only, forgets everything at shutdown) | Kernel line adds `overlayroot=tmpfs`; root and home are a RAM overlay over the LUKS/LVM root; the overlay is half of RAM (about 3 GB), so large downloads fill it |

First-time setup requires Persistent. `/etc/overlayroot.conf` ships
persistent, so only the Amnesic entry's kernel parameter turns the overlay on.

## Install and first boot

| Step | Command or action |
|---|---|
| 1 | `bash build/make-install-iso.sh desktop` |
| 2 | `bash build/fusion/create-desktop-vm.sh`: 6 GB RAM, 4 vCPU, 30 GB NVMe, NAT for install; unattended, 10-25 min; powers off when done |
| 3 | `bash build/fusion/post-install-desktop.sh`: NIC to "Private to my Mac", detach CD, disk-first, start |
| 4 | First boot: unlock with `ombra-disk`, set secrets, wait for re-encryption, reboot, unlock with your own passphrase |

The gateway must be running: DNS, Tor and the transparent proxy live there.
