# Ombra desktop

Debian trixie (arm64), KDE Plasma on X11, LUKS2 (argon2id) full-disk
encryption, per-boot random-key swap. The same tree is the base of the
single VM edition (`build/make-install-iso.sh single`), which adds
`desktop/single/` and the gateway container; see the last section. Its only network link is the
private link to the gateway (static 10.55.10.100/24; gateway and DNS
10.55.10.1). Isolation is topological: one NIC, no NAT, no bridge, no
second adapter, ever (`docs/DESIGN.md`, invariant 1).

## Contents

| Path | Role |
|---|---|
| `preseed.cfg` | Unattended installer recipe: LUKS2 + LVM (root, swap and `/home` as separate volumes), generic identity, base package set, no display manager |
| `single/` | Overlay only the single VM edition carries (network card rename, link to the gateway container, its firewall and unit) |
| `late-command.sh` | Installer finisher, see below |
| `rootfs/` | The shipped filesystem delta: configuration and vendored assets (`rootfs/README.md`) |

`late-command.sh` steps:

| Step | Effect |
|---|---|
| Identity | Diverts Debian's identity files |
| Clock and updates | Sets the installer clock from the `Date` header of `https://deb.debian.org/` when it is more than 60 s off, then applies Debian's security and point-release updates |
| Disk layout | Parks unless `/home` is its own mount |
| Session transaction | One recommends-off install of `kde-plasma-desktop`, `sddm`, `kwin-x11`, `kitty`, `kvantum`, `fastfetch`; a failure parks the installer |
| Overlay | Unpacks `rootfs/` |
| Unlock | Wires crypttab (keyscript, `tries=0`), rebuilds the initramfs around the Ombra unlock engine |
| Tor Browser | Installs the sha256-pinned stable build, wrapped for the gateway's SOCKS port |
| Applications | Kleopatra, OnionShare and Electrum from Debian; Feather and SimpleX from sha256-pinned upstream files |
| Cleanup | Purges and masks Discover, KDE Connect, plymouth and telemetry surfaces |
| Firewall | Enables the local default-drop nftables policy |
| Boot menu | Builds the themed GRUB menu and fonts |
| Failure | Every hard assertion parks on a visible console; the installer never powers off on failure |

`build/make-install-iso.sh desktop` packs these into the pinned netinst
initrd. It fails if the four Rust binaries in the overlay (`ombra-askpass`,
`ombra-welcome`, `ombra`, `ombra-statusd`) differ from `core/dist/aarch64/`,
and stages Tor Browser only after its sha256 verifies. During the build
install, the only downloads are Debian packages from the live trixie suite
(not a snapshot, so builds are not reproducible); every version is recorded
in `/usr/share/ombra/packages.txt`. Release images download nothing at
install.

## The machine

| Area | Value |
|---|---|
| Identity | Hostname `ombra`, fixed generic `machine-id`; `os-release` says "Ombra" (`ID=ombra`); `/usr/lib/os-release` and `/etc/debian_version` are dpkg-diverted |
| Disk | LUKS2 (argon2id) holding LVM `vg0`: `root` about 12 GB, `swap` about 4 GB, `home` the rest, 12% left free for the update snapshot; cryptswap with a fresh key per activation. Desktops installed from v1.1.0 images have Debian's default layout instead (one root volume including `/home`, 1.3 GB swap): the recipe was skipped then |
| Install passphrase | Two VMs: public build value `ombra-disk`; first use rotates it before the greeter may start (sddm is gated on `/run/ombra/setup-complete`, re-proved every boot). Single VM: the user's own passphrase from the installer |
| Session | Plasma on X11 (Wayland entry diverted); the UTM display fix (compositor off under QEMU) exists only on X11 |
| Look | Ombra ink wallpaper and palette over Colloid-dark (quiet window buttons, the unlock screen's field style at login), Kaze-dark icons, phinger cursors, JetBrains Mono Nerd Font, kitty, `org.ombra.status` Tor light, floating dock |
| Terminal | kitty runs through `/usr/local/bin/kitty` with `LIBGL_ALWAYS_SOFTWARE=1`: on Fusion's 3D device it drew its text near-black. KWin stays on the hardware device |
| IPv6 | Off at four layers: kernel parameter `ipv6.disable=1`, sysctl, NetworkManager profile, nft table (v1.1.0 images lack the kernel parameter) |
| Remote access | No sshd; build and test access is vmrun guest operations |
| Apps | Tor Browser, KeePassXC, Kleopatra, OnionShare, Electrum, Feather, SimpleX |
| Power | No suspend daemon; screen blanking off |

## Boot modes

The GRUB menu waits for a choice; it never auto-starts.

| Entry | Effect |
|---|---|
| Ombra — Persistent (highlighted first) | Encrypted disk and home directory persist |
| Ombra — Amnesic (RAM only, forgets everything at shutdown) | Kernel line adds `overlayroot=tmpfs:recurse=1`; root and `/home` (its own volume) are RAM overlays over the LUKS/LVM volumes; the overlay is half of RAM (about 3 GB), so large downloads fill it |

First-time setup requires Persistent. `/etc/overlayroot.conf` ships
persistent, so only the Amnesic entry's kernel parameter turns the overlay on.

## Install and first boot (two VMs)

| Step | Command or action |
|---|---|
| 1 | `bash build/make-install-iso.sh desktop` |
| 2 | `bash build/fusion/create-desktop-vm.sh`: 6 GB RAM, 4 vCPU, 30 GB NVMe, NAT for install; unattended, 10-25 min; powers off when done |
| 3 | `bash build/fusion/post-install-desktop.sh`: NIC to "Private to my Mac", detach CD, disk-first, start |
| 4 | First boot: unlock with `ombra-disk`, set secrets, wait for re-encryption, reboot, unlock with your own passphrase |

The gateway must be running: DNS and Tor's SOCKS ports live there.

## Single VM edition

`build/make-install-iso.sh single` builds an installer for a VM the user
creates. It asks the account password and the disk passphrase, then
`late-command.sh` runs the same steps as above plus:

| Step | Effect |
|---|---|
| Disk check | Parks unless the LUKS header is LUKS2 with one argon2id keyslot and aes-xts-plain64 with a 512-bit key, or if `ombra-disk` opens it |
| Account check | Parks unless `ombra` has a password hash and no privileged group, and root is locked |
| Host channels | Removes the VMware shared-folder helpers (`vmhgfs-fuse`, `mount.vmhgfs`) and keeps them out with dpkg excludes; `spice-vdagent` held non-executable by a dpkg statoverride |
| Gateway container | Builds `/var/lib/ombra/gateway.img` from `mmdebstrap`, `gateway/rootfs` and `gateway/container` ([README](../gateway/container/README.md)); checks its firewall and `torrc` against the gateway overlay; records its hash and package list; marks image and hash immutable |
| Host overlay | Unpacks `single/`, enables `ombra-gateway.service` |
| First use | None: `ombra-welcome.service` is masked; the setup gate still runs |
| Finish | Reboots into the installed system |

Installed in a hand-made VM: see
[docs/INSTALL.md](../docs/INSTALL.md#single-vm-installer-iso). Tested on
VMware Fusion; untested on UTM.
