# Ombra Design

Architecture and invariants. Component detail lives beside the components
(`core/`, `gateway/`, `desktop/`).

## Overview

| | ombra-gateway | ombra-desktop |
|---|---|---|
| Role | Tor router, fail-closed firewall | KDE Plasma (X11) workstation |
| Base | Debian trixie, arm64, headless | Debian trixie, arm64 |
| Firmware | EFI | EFI |
| Disk | 5 GB NVMe, unencrypted (holds no user data) | 30 GB NVMe, LUKS2 |
| RAM / vCPU | 512 MB / 1 | 6 GB / 4 |
| NIC 1 | NAT, `vmxnet3`: the only upstream, Tor-only | Private link, `vmxnet3`, static 10.55.10.100 |
| NIC 2 | Private link, `e1000e`, static 10.55.10.1 | none |
| Extra NICs | none, ever | none, ever |
| USB | Keyboard and pointer only (Apple Silicon VMs have no PS/2, so console input needs USB); no USB sharing | Keyboard and pointer only; no USB sharing |

### Under UTM

| Item | UTM (QEMU, `hvf`) |
|---|---|
| Machine | `virt`, UEFI; the Fusion-built disk converted to qcow2 |
| Disk, NICs | NVMe, `vmxnet3` and `e1000e`: the same device names the guest code matches, so one image serves both hypervisors |
| Interrupt controller | In QEMU (`-machine kernel-irqchip=off`). With the hypervisor's own GIC, UTM 5.0.8 (QEMU 10.0.12) leaves it unreset on a guest restart and the next boot hangs before the kernel prints anything; found by testing, 3 of 3 failures without the flag and none with it. Idle CPU rises from about 5% to about 19% of a core; typing latency stays near 40 ms |
| Compositor | Off on QEMU guests (`ombra-kwin-compositing` writes `/etc/xdg/kwinrc`, `[Compositing] Enabled=false`). With no GPU, KWin's OpenGL compositor runs on Mesa's software renderer through GLX, and when the screen grows it stalls for about 19 s or never repaints. With it off, growth repaints in about 2 s (6 of 6 trials, against 0 of 3), typing latency median about 39 ms. Blur off, EGL instead of GLX and llvmpipe thread counts did not cure it. VMware keeps the compositor |
| Display | `virtio-gpu-pci`, no GL. The initrd carries `virtio_gpu` so the unlock screen draws before the root disk opens |
| Private link | UTM host-only network 10.55.20.0/24; guests keep static 10.55.10.x; gateway upstream on UTM Shared (NAT) |
| Host channels | Clipboard, shared folder, USB sharing, serial and sound off in the bundle; `qemu-guest-agent` allowlist is ping, sync, info; `spice-vdagent` only follows the window size |

The desktop has no network path except through the gateway. That
topology plus the gateway firewall is the product.

### Single VM edition

The same desktop and the same gateway files in one VM, installed by the
user from `build/disks/ombra-install-single.iso` (never exported as a VM
image). The hypervisor boundary is replaced by a container boundary; the
trade-off is in [THREAT_MODEL.md](THREAT_MODEL.md#two-vms-vs-single-vm).

| Item | Design |
|---|---|
| Gateway | `ombra-gateway.service` runs `systemd-nspawn` (`desktop/single/usr/local/sbin/ombra-gateway-run`): boot from `/var/lib/ombra/gateway.img` (read-only ext4, built at install by `mmdebstrap` plus `gateway/rootfs` plus `gateway/container`), `--volatile=overlay` (writes in RAM), `-U` (own user namespace), `--no-new-privileges`, capabilities dropped (`CAP_SYS_PTRACE`, `CAP_SYS_BOOT`, `CAP_AUDIT_CONTROL`, `CAP_AUDIT_WRITE`, `CAP_MKNOD`, `CAP_SYS_TTY_CONFIG`, `CAP_LINUX_IMMUTABLE`, `CAP_IPC_OWNER`), `MemoryMax=768M`, `TasksMax=512` |
| Gateway files | Firewall and `torrc` byte-identical to the gateway VM's (the install checks this); package versions in `/usr/share/ombra/gateway-packages.txt` |
| Integrity | The image is hashed at every start against `/usr/share/ombra/gateway.img.sha256`; on a mismatch the container does not start. Both files are immutable (`chattr +i`); `ombra-update` lifts the flag only to replace them from a signed `single` bundle |
| Network card | The VM's only NIC is renamed `ombra-nic` (`.link` matching `vmxnet3`, `e1000e`, `virtio_net`), left unmanaged by NetworkManager, and moved into the container as `ombra-upstream` (DHCP) |
| Link | veth `ombra-gw` (desktop, 10.55.10.100) to `ombra-intnet` (container, 10.55.10.1); the desktop's NetworkManager profile is bound to `ombra-gw` by name |
| Desktop firewall | `desktop/single/etc/nftables.conf`: output only to 10.55.10.1 over `ombra-gw`; input from 10.55.10.1 only on 17600-17659 (OnionShare) and ICMP echo |
| Tor state | Persistent: `/var/lib/ombra/gateway-state/tor` (root-only parent, idmapped into the container). Amnesic: in the container's RAM overlay |
| Clock | One kernel clock, set by the desktop's `ombra-timesync`; the container's is masked |
| Disk and account | Created by the installer with the user's passphrase and password: no build passphrase, no first-use screen (`ombra-welcome.service` masked; the setup gate still runs) |
| Host channels | Guest side only: VMware drag-and-drop, clipboard and HGFS plugins and the `vmhgfs` helpers removed and excluded from reinstall (`/etc/dpkg/dpkg.cfg.d/ombra-no-host-channels`); `/usr/bin/spice-vdagent` held at mode 0644 by a dpkg statoverride, so UTM's clipboard agent does not run and the display does not follow the UTM window |
| Installer | Boots by itself ("Install Ombra (single VM)", 3 s); asks only the account password and the disk passphrase (8 characters minimum); `build/single-iso/early.sh` stops before partitioning on a disk under 24 GB or memory under about 3 GB; picks the first disk that is not the install medium; reboots into the system when done |
| Edition marker | `/etc/ombra/edition` is `single` (two-VM installs write `two-vm`); the updater's index role is `single` |

```
┌────────────────── macOS host (Apple Silicon, Fusion or UTM) ──────────────────┐
│                                                                               │
│  ┌──────────────────────────────┐        ┌───────────────────────────────┐    │
│  │ VM: ombra-gateway (headless) │        │ VM: ombra-desktop             │    │
│  │                              │        │                               │    │
│  │  Tor (system service,        │private │  KDE Plasma on X11            │    │
│  │  dedicated uid)              │ link   │  LUKS2 root + encrypted swap  │    │
│  │  dnsmasq → Tor DNS           │◄──────►│  one NIC: private link        │    │
│  │  fail-closed nftables        │        │  Tor Browser, KeePassXC       │    │
│  └───────────────┬──────────────┘        └───────────────────────────────┘    │
│                  │ NIC 1: NAT, the only upstream, Tor-only                    │
└──────────────────┼────────────────────────────────────────────────────────────┘
                   ▼
              Tor network ──► internet
```

## Hard invariants

| # | Invariant | How it holds |
|---|---|---|
| 1 | The desktop has no direct network path | One NIC on a private link; no NAT, second adapter or bridge, ever. The link is shared with the host adapter and any other attached VM, so the guarantee is the single NIC plus the gateway firewall |
| 2 | The gateway is fail-closed | Outbound allowed only for the Tor uid; DNS only through Tor; if Tor dies the desktop has no network |
| 3 | Nothing fetches during the end user's install of the two-VM archives (the single VM installer downloads Debian packages, see the threat model); at runtime the only automatic fetches are the signed update index, the Tor exit check (desktop status daemon, gateway console panel at login) and the clock check, all through Tor; a user-started update or health check adds its own requests (list: threat model, Designed runtime probes) | Debian packages from the live trixie suite at build time (not a snapshot, so builds are not reproducible), every version recorded in `/usr/share/ombra/packages.txt`; everything else vendored with source, tag, hash and license recorded |
| 4 | Generic guest identity | Fixed hostnames and machine-id; nothing derived from the user, the Mac or the build host |
| 5 | No version numbers on human surfaces | The machine calls itself "Ombra"; versions appear only in machine-readable fields |
| 6 | The disk is the state | No persistent stamps: first-use re-proves its precondition against the LUKS header every boot; the completion marker lives on tmpfs |

## Networking

| Area | Design |
|---|---|
| Private link | 10.55.10.0/24, static: gateway .1, desktop .100; no DHCP on the link |
| Gateway upstream | DHCP lease on the NAT side only, scoped firewall rules both ways |
| DNS | dnsmasq on the gateway, only upstream is Tor's DNSPort |
| `.onion` | Tor's DNSPort automaps names into 10.66.0.0/16; desktop apps reach onion services by passing hostnames over SOCKS |
| TCP | Desktop apps use the gateway's SOCKS ports (9050, 9150); the desktop firewall allows only 10.55.10.1. As a backstop, the gateway redirects any desktop TCP connection to another address into Tor's TransPort (no per-destination isolation there) |
| Tor | Stock Debian `tor` under its own uid; firewall permits outbound for that uid only |
| Control port | Filter on its own unprivileged user, loopback-only egress; status reads plus OnionShare's `ADD_ONION` (restricted grammar) and `DEL_ONION`. Targets are rewritten to the asking machine and limited to ports 17600-17659, at most 8 services per connection; no signal, reconfigure or arbitrary destination. Exact allowlist: [THREAT_MODEL.md](THREAT_MODEL.md#tor-control-port) |
| IPv6 | Gateway: kernel parameter, sysctl, systemd-networkd, nft drop. Desktop (both editions): kernel parameter `ipv6.disable=1`, sysctl, NetworkManager, nft. Desktops installed from v1.1.0 images have no kernel parameter |
| Clock | Starts from the hypervisor's clock at boot: UTC in the UTM bundles and in Ombra's Fusion VM settings (`rtc.diffFromUTC = "0"`, checked by `create-*-vm.sh --verify` and `verify-bundle.sh`; the v1.1.0 Fusion archives lack it and start on the Mac's local time). `ombra-timesync` then runs every 5 min: one HTTPS Date header through Tor as a quick check; beyond 90 s off, all three sites are asked and the clock moves only on a 2-of-3 consensus, never on disagreement |
| Installer clock | Before apt runs, `desktop/late-command.sh` reads the `Date` header of `https://deb.debian.org/` and steps the clock when it is more than 60 s off; no build-host time zone is assumed |
| Host time sync | Off in both VMs' settings. The single VM edition cannot turn it off from inside the guest |

## Boot modes

Both machines start at a branded GRUB menu (`/etc/grub.d/09_ombra` is the
only entry generator; recovery, advanced and firmware entries are
disarmed). The menu waits for a choice.

| | Gateway | Desktop |
|---|---|---|
| Amnesic | Highlighted first; `overlayroot` tmpfs from `/etc/overlayroot.conf` | `overlayroot=tmpfs:recurse=1` on the kernel line (`recurse=1` also puts `/home`, its own mount, under the overlay) |
| Persistent | `overlayroot=disabled` on the kernel line | Highlighted first |
| Timeout | none | none |

| Mode | Effect |
|---|---|
| Amnesic | Root mounted read-only, every write goes to a RAM tmpfs (system, home, browser profile, logs); power-off discards it. The desktop LUKS disk is still unlocked but never written (swap is off in this mode) |
| Persistent, desktop | Writes to the encrypted disk; first-time setup runs only here |
| Persistent, gateway | Tor state and chosen guards stay on the unencrypted disk |

| Property | Value |
|---|---|
| Mechanism | `overlayroot` initramfs hook; independent of the hypervisor disk mode, so it does not depend on how the image is imported |
| Override | A kernel `overlayroot=` parameter beats `/etc/overlayroot.conf` |
| Command line | Every entry carries the full hardened line (`ipv6.disable=1` on the gateway) |
| RAM limit | tmpfs is half of RAM: about 230 MB gateway, about 3 GB desktop; large amnesic downloads fill it and writes fail |
| Gateway default | Amnesic: fresh guard sample per boot trades Tor's persistent-guard protection for a stateless gateway; Persistent restores it |
| Remount | A `systemd-remount-fs` drop-in handles overlayfs on both machines |
| Check | `ombra-systemcheck` reports the mode and checks the overlay only when amnesic |

## Storage and encryption

| Topic | Design |
|---|---|
| Desktop disk | LUKS2 (argon2id) and encrypted swap with a fresh key per boot, inside the guest; the virtual disk file on the Mac holds ciphertext only. Suspended VM memory, the transfer disk, hypervisor logs and host backups are outside this ([threat model, Host residue](THREAT_MODEL.md#host-residue)) |
| Layout | `desktop/preseed.cfg`: ESP 512 MB and `/boot` 1 GB (plain), then LUKS2 holding LVM `vg0`: `root` about 12 GB (11 GiB, fixed), `swap` about 4 GB (fixed), `home` the rest; 12% of the volume group stays free (about 3.4 GB on a 30 GB disk) for the 3 GB update snapshot. The install parks if `/home` is not its own mount |
| v1.1.0 layout | A stray terminator in the recipe made the installer skip it and fall back to Debian's default layout, without an error: one root volume holding `/home` and a 1.3 GB swap. v1.1.0 images have that layout; an update cannot change it |
| Build passphrase (two VMs) | `ombra-disk`, public by design; it only opens a machine that has not been set up |
| Single VM disk | Formatted by the installer with the user's passphrase: LUKS2, aes-xts-plain64 with a 512-bit key, one argon2id keyslot with parameters benchmarked by cryptsetup (1 GiB measured on a 6 GB VM). `late-command.sh` parks the install unless the header has exactly those properties, or if `ombra-disk` opens it |
| First use | `ombra-welcome` owns tty1 before the display manager: sets the user password, adds the user's keyslot, runs `cryptsetup reencrypt` online to a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads), retires the build slot |
| Release gate | The display manager starts only after the disk is Sealed: re-encryption done, build passphrase dead, user passphrase opens |
| Interruption | Re-encryption resumes at the next boot on a Resume screen; the machine is unusable until it finishes |
| Volume key | Replaced per machine; the distributed image's key only ever protected the empty image |
| Accounts | Born locked (`*`) on both machines; the gateway console autologins as `ombra` (no groups; NOPASSWD grants: the leak probe, `systemctl start ombra-systemcheck.service`, `ombra-systemcheck` with no arguments, and `ombra-update apply`, `rollback`, `commit`, `check`, `status`, `security --no-rollback`). Single VM edition: the account is created by the installer with the user's password, in no privileged group; root stays locked |
| crypttab | `tries=0`: unlock retries belong to the Ombra unlock agent |
| Runtime | Once unlocked, keys and plaintext live in guest RAM, visible to the host; encryption protects data at rest only |
| Host disk | FileVault is outside Ombra's control and recommended |

## Boot screens

| Item | Design |
|---|---|
| GRUB menu | Themed graphical menu: ink background, Ombra mark, JetBrains Mono, indigo selection |
| Unlock and first-use | Rendered to the framebuffer: Ombra mark, anti-aliased JetBrains Mono, exact palette (`core/src/fb.rs`) |
| Fallback | If the framebuffer cannot be used, the same screens draw on the text console with a vendored Terminus font (`core/src/psf.rs`); unlock always works |
| Palette | Ink #0b0c11, text #f4f3ef, muted #8b8d93, indigo #8f9bff, green #56d68a, amber #f2c260, coral #f0716b |
| Motion | None; progress screens may pulse dots |

## Desktop session

| Topic | Design |
|---|---|
| Session | KDE Plasma on X11 only; the Wayland entry is diverted at install. X11 is required for open-vm-tools display auto-fit |
| Privacy floor | No telemetry, Baloo off, no Discover, no KDE Connect, no networked widgets, clipboard history off |
| Status LED | `org.ombra.status` shows the Tor verdict from the status daemon; never network content |
| Host channels | Fusion: vmx keys disable copy/paste, drag-and-drop and shared folders; the guest also removes the drag-and-drop and hgfs plugins; display auto-fit stays. UTM: the bundle turns clipboard sharing, shared folders and USB sharing off, and the QEMU agent answers a short allowlist (see Under UTM) |
| Transfer disk | When a shared-folder disk is attached to the desktop VM it appears as one extra disk, labelled `OMBRA-SHARE`, and no network. It is not encrypted: its contents sit in plain form in its disk file on the Mac. A fixed systemd mount puts it at `/mnt/transfer/shared` (`vfat`, `sync,flush`, `noexec,nosuid,nodev`); the `udf` driver stays blacklisted. Dolphin's sidebar lists one place, Mac Shared Folder, the raw device is hidden from udisks, and a right-click Copy to Mac Shared Folder works from anywhere |
| Browser | Tor Browser (stable channel, linux-aarch64) on its own gateway SOCKS port, 9150, which keeps the browser's per-site circuit isolation; other apps use 9050, isolated per destination. Its own updater is off: new builds arrive as app updates (signed app list, downloaded from the Tor Project through Tor) |
| Privacy applications | Kleopatra (OpenPGP, keyserver traffic only through Tor), OnionShare, Electrum, Feather and SimpleX; each is sha256-pinned or a Debian trixie package taken at build time, and is pointed at the gateway SOCKS port by shipped presets. Feather and SimpleX are vendored at a pinned hash and never fetch or update themselves; from 1.2.1 they, Tor Browser and Electrum (the electrum.org release in `/opt/electrum`, replacing Debian's older package) are updated through app updates. Tor services bundled by an application are disabled: the desktop has no tor daemon, and `ombra-socks` forwards the loopback SOCKS port that applications expect to the gateway |
| Passwords | KeePassXC |
| Terminal | kitty, started through `/usr/local/bin/kitty`, which sets `LIBGL_ALWAYS_SOFTWARE=1`: on Fusion's 3D device kitty drew its text near-black. KWin itself composites on the hardware device |
| Updates | Signed in-place updates fetched through Tor on request, and Debian's security updates on request (see [UPDATES.md](UPDATES.md)); the desktop snapshots root first (with `/home` on its own volume a rollback leaves it alone; on v1.1.0 installs `/home` is on root, so a rollback also drops files saved after the update), the gateway keeps replaced files; Amnesic mode cannot update |

## Build and supply chain

| Part | Design |
|---|---|
| `core/` | Rust crate cross-built to aarch64 musl-static (`core/build.sh`): unlock agent, first-use setup, terminal panel, status daemon, control-port filter |
| `build/` | Installer ISOs from pinned inputs: Debian netinst at a pinned sha256, vendored assets at pinned tag and hash, overlay Rust binaries byte-compared against the committed `core/dist/aarch64/` (`core/verify-dist.sh` checks those against the source) |
| Installer | Unattended; parks visibly on failure instead of shipping a half-installed machine |
| Vendored assets | Display names renamed to Ombra; upstream identifiers and licenses unchanged; provenance in `desktop/rootfs/usr/share/ombra-assets/README.md` |
| Release images | `.vmwarevm.zip` (Fusion) and `.utm.zip` (UTM) archives exported from fresh installs, scrubbed of builder residue, plus the single VM installer ISO (`build/release-single-iso.sh`), all listed in `SHA256SUMS.txt`. `scripts/update/sign-sums.sh` signs that file with the update key; `SHA256SUMS.txt.sig` is published beside it from v1.2.0 |
| Build residue | The install empties logs, apt lists and histories, then zeroes every free block that still holds an address of the installer's own NAT network (a deleted `resolv.conf` or installer syslog); a release install parks if such an address is in a live file under `/etc`, `/var`, `/root` or `/home`. Archives are zipped with no owner fields and UTC times; the ISO's files and its appended cpio are owned by root |

## Verification

| Check | Command |
|---|---|
| Rust tests | `cd core && cargo test` |
| Installer script walker | `python3 tests/build/late-command-walker.py` |
| ISO build and assertions | `bash tests/build/test-install-iso.sh` |
| Public hygiene | `bash tests/build/test-public-hygiene.sh` |
| Release archive shape | `bash build/fusion/verify-bundle.sh <zip>`, `bash build/utm/verify-bundle.sh <role> <zip>` (run by the exporters) |
| Updater tooling | `bash tests/build/test-update.sh` |
| Updater logic (real `ombra-update` against a fake root) | `bash tests/build/test-update-logic.sh` |
| Committed binaries match the source | `bash core/verify-dist.sh` |
| Other offline checks | `bash tests/build/test-crypttab-wiring.sh`, `bash tests/build/test-verify-iso.sh`, `bash tests/build/test-utm-verify.sh` |
| Gateway leak suite | `tests/leaks/README.md` |
| Gateway health | `ombra-systemcheck` on the gateway console |

## Out of scope

- Tor bridges and pluggable transports: the network can see Tor use, and Ombra does not work where Tor is blocked
- Automatic OS updates
- Host-side device management
