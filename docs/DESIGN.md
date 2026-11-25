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
| Interrupt controller | In QEMU (`-machine kernel-irqchip=off`). With the hypervisor's own GIC, UTM 5.0.8 (QEMU 10.0.12) leaves it unreset on a guest restart and the next boot hangs before the kernel prints anything. Idle CPU is about 19% of a core instead of about 5%; typing latency stays near 40 ms |
| Compositor | Off on QEMU guests (`ombra-kwin-compositing` writes `/etc/xdg/kwinrc`, `[Compositing] Enabled=false`). With no GPU, KWin's OpenGL compositor runs on Mesa's software renderer and stalls when the screen grows. With it off, the screen repaints after a resize in about 2 s. VMware keeps the compositor |
| Display | `virtio-gpu-pci`, no GL. The initrd carries `virtio_gpu` so the unlock screen draws before the root disk opens |
| Private link | UTM host-only network 10.55.20.0/24; guests keep static 10.55.10.x; gateway upstream on UTM Shared (NAT) |
| Host channels | Clipboard, shared folder, USB sharing, serial and sound off in the bundle; `qemu-guest-agent` allowlist is ping, sync, info; `spice-vdagent` only follows the window size |

The desktop has no network path except through the gateway. That
topology plus the gateway firewall is the product.

```
┌────────────────── macOS host (Apple Silicon, Fusion or UTM) ──────────────────┐
│                                                                               │
│  ┌──────────────────────────────┐        ┌───────────────────────────────┐    │
│  │ VM: ombra-gateway (headless) │        │ VM: ombra-desktop             │    │
│  │                              │        │                               │    │
│  │  Tor (system service,        │private │  KDE Plasma on X11            │    │
│  │  dedicated uid)              │ link   │  LUKS2 root + encrypted swap  │    │
│  │  dnsmasq (local answers)     │◄──────►│  one NIC: private link        │    │
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
| 2 | The gateway is fail-closed | Outbound allowed only for the Tor uid; no DNS query leaves the gateway; if Tor dies the desktop has no network |
| 3 | Nothing fetches during the end user's install of the release archives; at runtime the only automatic fetches are the signed update index and app list, the Tor exit check (desktop status daemon, gateway console panel at login), the clock check and the gateway's Tor version check, all through Tor; a user-started update or health check adds its own requests (list: threat model, Designed runtime probes) | Debian packages from the live trixie suite at build time (not a snapshot, so builds are not reproducible), every version recorded in `/usr/share/ombra/packages.txt`; everything else vendored with source, tag, hash and license recorded |
| 4 | Generic guest identity | Fixed hostnames and machine-id; nothing derived from the user, the Mac or the build host |
| 5 | No version numbers on human surfaces | The machine calls itself "Ombra"; versions appear only in machine-readable fields |
| 6 | The disk is the state | No persistent stamps: first-use re-proves its precondition against the LUKS header every boot; the completion marker lives on tmpfs |

## Networking

| Area | Design |
|---|---|
| Private link | 10.55.10.0/24, static: gateway .1, desktop .100; no DHCP on the link |
| Gateway upstream | DHCP lease on the NAT side only, scoped firewall rules both ways |
| DNS | None reaches Tor. dnsmasq on the gateway answers from its own file and forwards nothing: every name is "no such name", at once. Applications resolve names by handing them to Tor's SOCKS port |
| `.onion` | Desktop apps reach onion services by passing hostnames over SOCKS. dnsmasq answers `.onion` with one fixed placeholder (10.66.0.1), which the status probe of earlier 1.2 desktops expects; nothing routes to it. The desktop's DNS questions are answered by its own stub and never reach the gateway |
| TCP | Desktop apps use the gateway's SOCKS ports (9050, 9150); the desktop firewall allows only 10.55.10.1. Any other connection that reaches the gateway is rejected: the gateway has no transparent proxy |
| Programs without proxy settings | `ssh host`, a script, `git` over ssh: the desktop's own `ombra-tproxy` (Rust, `core/src/tproxy.rs`, an unprivileged dynamic user) makes them work. The desktop firewall redirects every DNS question to its local stub, which answers with a random placeholder from 10.64.0.0/10 and remembers the name, and redirects every TCP connection not addressed to the gateway to its TCP port, where it becomes a SOCKS `CONNECT name:port` on the gateway's port 9050. A literal address is passed on as an address. TCP only; `ping` and other UDP do not work. systemd holds the two ports (`ombra-tproxy.socket`). A placeholder is never re-pointed while its name is in use; the table holds 100,000 names, drops idle ones for room and refuses new ones when none is idle; reverse lookups are not answered; the firewall limits lookups (2,000 a second) and connections (512) per user |
| Tor | Stock Debian `tor` under its own uid; firewall permits outbound for that uid only, by TCP, to public addresses. SOCKS is its only desktop-facing port: no TransPort, no DNSPort, no automap. Confined by Debian's unit plus Ombra's drop-ins (system-call filter, no writable-and-executable memory, mandatory AppArmor profile on the gateway VM) and a crash tripwire; a boot-time and daily check says whether Debian has a newer Tor. Design and limits: [TOR_HARDENING.md](TOR_HARDENING.md) |
| Control port | Filter on its own unprivileged user, loopback-only egress; status reads plus OnionShare's `ADD_ONION` (restricted grammar) and `DEL_ONION`. Targets are rewritten to the asking machine and limited to ports 17600-17659, at most 8 services per connection; no signal, reconfigure or arbitrary destination. Exact allowlist: [THREAT_MODEL.md](THREAT_MODEL.md#tor-control-port) |
| IPv6 | Gateway: kernel parameter, sysctl, systemd-networkd, nft drop. Desktop: kernel parameter `ipv6.disable=1`, sysctl, NetworkManager, nft. |
| Clock | Starts from the hypervisor's clock at boot: UTC in the UTM bundles and in Ombra's Fusion VM settings (`rtc.diffFromUTC = "0"`, checked by `create-*-vm.sh --verify` and `verify-bundle.sh`). `ombra-timesync` then runs every 5 min: one HTTPS Date header through Tor as a quick check; beyond 90 s off, all three sites are asked and the clock moves only on a 2-of-3 consensus, never on disagreement |
| Installer clock | Before apt runs, `desktop/late-command.sh` reads the `Date` header of `https://deb.debian.org/` and steps the clock when it is more than 60 s off; no build-host time zone is assumed |
| Host time sync | Off in both VMs' settings |

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
| Desktop disk | LUKS2 (argon2id) and encrypted swap with a fresh key per boot, inside the guest; the virtual disk file on the Mac holds ciphertext only. Suspended VM memory, hypervisor logs and host backups are outside this ([threat model, Host residue](THREAT_MODEL.md#host-residue)) |
| Layout | `desktop/preseed.cfg`: ESP 512 MB and `/boot` 1 GB (plain), then LUKS2 holding LVM `vg0`: `root` about 12 GB (11 GiB, fixed), `swap` about 4 GB (fixed), `home` the rest; 12% of the volume group stays free (about 3.4 GB on a 30 GB disk) for the 3 GB update snapshot. The install parks if `/home` is not its own mount |
| Build passphrase | `ombra-disk`, public by design; it only opens a machine that has not been set up |
| First use | `ombra-welcome` owns tty1 before the display manager: sets the user password, adds the user's keyslot, runs `cryptsetup reencrypt` online to a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads), retires the build slot |
| Release gate | The display manager starts only after the disk is Sealed: re-encryption done, build passphrase dead, user passphrase opens |
| Interruption | Re-encryption resumes at the next boot on a Resume screen; the machine is unusable until it finishes |
| Volume key | Replaced per machine; the distributed image's key only ever protected the empty image |
| Accounts | Born locked (`*`) on both machines; the gateway console autologins as `ombra` (no groups; NOPASSWD grants: the leak probe, `systemctl start ombra-systemcheck.service`, `ombra-systemcheck` with no arguments, and `ombra-update apply`, `rollback`, `commit`, `check`, `status`, `security --no-rollback`). |
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
| Browser | Tor Browser (stable channel, linux-aarch64) on its own gateway SOCKS port, 9150, which keeps the browser's per-site circuit isolation; other apps use 9050, isolated per destination. Its own updater is off: new builds arrive as app updates (signed app list, downloaded from the Tor Project through Tor) |
| Privacy applications | Kleopatra (OpenPGP, keyserver traffic only through Tor), OnionShare, Electrum, Feather and SimpleX; each is sha256-pinned or a Debian trixie package taken at build time, and is pointed at the gateway SOCKS port by shipped presets. Feather and SimpleX are vendored at a pinned hash and never fetch or update themselves; they, Tor Browser and Electrum (the electrum.org release in `/opt/electrum`) are updated through app updates. Tor services bundled by an application are disabled: the desktop has no tor daemon, and `ombra-socks` forwards the loopback SOCKS port that applications expect to the gateway |
| Passwords | KeePassXC |
| Terminal | kitty, started through `/usr/local/bin/kitty`, which sets `LIBGL_ALWAYS_SOFTWARE=1` so kitty draws its text correctly on Fusion's 3D device. KWin itself composites on the hardware device |
| Updates | Signed in-place updates fetched through Tor on request, and Debian's security updates on request (see [UPDATES.md](UPDATES.md)); the desktop snapshots root first (`/home` is on its own volume, so a rollback leaves it alone), the gateway keeps replaced files; Amnesic mode cannot update |

## Build and supply chain

| Part | Design |
|---|---|
| `core/` | Rust crate cross-built to aarch64 musl-static (`core/build.sh`): unlock agent, first-use setup, terminal panel, status daemon, control-port filter |
| `build/` | Installer ISOs from pinned inputs: Debian netinst at a pinned sha256, vendored assets at pinned tag and hash, overlay Rust binaries byte-compared against the committed `core/dist/aarch64/` (`core/verify-dist.sh` checks those against the source) |
| Installer | Unattended; parks visibly on failure instead of shipping a half-installed machine |
| Vendored assets | Display names renamed to Ombra; upstream identifiers and licenses unchanged; provenance in `desktop/rootfs/usr/share/ombra-assets/README.md` |
| Release images | `.vmwarevm.zip` (Fusion) and `.utm.zip` (UTM) archives exported from fresh installs, scrubbed of builder residue, all listed in `SHA256SUMS.txt`. `scripts/update/sign-sums.sh` signs that file with the update key; `SHA256SUMS.txt.sig` is published beside it |
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
| Gateway leak suite (nine tests, including Tor's surface and the hijacked-Tor probe) | `tests/leaks/README.md` |
| Gateway health | `ombra-systemcheck` on the gateway console |

## Out of scope

- Tor bridges and pluggable transports: the network can see Tor use, and Ombra does not work where Tor is blocked
- Automatic OS updates
- Host-side device management
