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
| USB | off | console input only |

The desktop has no network path except through the gateway. That
topology plus the gateway firewall is the product.

```
┌────────────────── macOS host (Apple Silicon, VMware Fusion) ──────────────────┐
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
| 3 | Nothing fetches at install, boot or runtime | Debian packages from the pinned suite; everything else vendored with source, tag, hash and license recorded |
| 4 | Generic guest identity | Fixed hostnames and machine-id; nothing derived from the user, the Mac or the build host |
| 5 | No version numbers on human surfaces | The machine calls itself "Ombra"; versions appear only in machine-readable fields |
| 6 | The disk is the state | No persistent stamps: first-use re-proves its precondition against the LUKS header every boot; the completion marker lives on tmpfs |

## Networking

| Area | Design |
|---|---|
| Private link | 10.55.10.0/24, static: gateway .1, desktop .100; no DHCP on the link |
| Gateway upstream | DHCP lease on the NAT side only, scoped firewall rules both ways |
| DNS | dnsmasq on the gateway, only upstream is Tor's DNSPort |
| `.onion` | Automap into 10.66.0.0/16; SOCKS-aware apps pass hostnames to Tor |
| TCP | Gateway redirects every desktop TCP connection into Tor's TransPort |
| Tor | Stock Debian `tor` under its own uid; firewall permits outbound for that uid only |
| Control port | Read-only filter, own unprivileged user, loopback-only egress; status GETINFOs and events only; no signal, reconfigure or destination relay |
| IPv6 | Gateway: kernel parameter, sysctl, systemd-networkd, nft drop. Desktop: sysctl, NetworkManager, nft |
| Clock | `ombra-timesync` every 30 min: HTTPS Date headers from three sites through Tor, 2-of-3 consensus, no change on disagreement |
| Host time sync | Off in both VMs |

## Boot modes

Both machines start at a branded GRUB menu (`/etc/grub.d/09_ombra` is the
only entry generator; recovery, advanced and firmware entries are
disarmed). The menu waits for a choice.

| | Gateway | Desktop |
|---|---|---|
| Amnesic | Highlighted first; `overlayroot` tmpfs from `/etc/overlayroot.conf` | `overlayroot=tmpfs` on the kernel line |
| Persistent | `overlayroot=disabled` on the kernel line | Highlighted first |
| Timeout | none | none |

| Mode | Effect |
|---|---|
| Amnesic | Root mounted read-only, every write goes to a RAM tmpfs (system, home, browser profile, logs); power-off discards it. The desktop LUKS disk is still unlocked but never written |
| Persistent, desktop | Writes to the encrypted disk; first-time setup runs only here |
| Persistent, gateway | Tor state and chosen guards stay on the unencrypted disk |

| Property | Value |
|---|---|
| Mechanism | `overlayroot` initramfs hook; independent of the hypervisor disk mode, so it survives OVA import |
| Override | A kernel `overlayroot=` parameter beats `/etc/overlayroot.conf` |
| Command line | Every entry carries the full hardened line (`ipv6.disable=1` on the gateway) |
| RAM limit | tmpfs is half of RAM: about 230 MB gateway, about 3 GB desktop; large amnesic downloads fill it and writes fail |
| Gateway default | Amnesic: fresh guard sample per boot trades Tor's persistent-guard protection for a stateless gateway; Persistent restores it |
| Remount | A `systemd-remount-fs` drop-in handles overlayfs on both machines |
| Check | `ombra-systemcheck` reports the mode and checks the overlay only when amnesic |

## Storage and encryption

| Topic | Design |
|---|---|
| Desktop disk | LUKS2 (argon2id) and encrypted swap with a fresh key per boot, inside the guest; the host sees ciphertext only |
| Build passphrase | `ombra-disk`, public by design; it only opens a machine that has not been set up |
| First use | `ombra-welcome` owns tty1 before the display manager: sets the user password, adds the user's keyslot, runs `cryptsetup reencrypt` online to a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads), retires the build slot |
| Release gate | The display manager starts only after the disk is Sealed: re-encryption done, build passphrase dead, user passphrase opens |
| Interruption | Re-encryption resumes at the next boot on a Resume screen; the machine is unusable until it finishes |
| Volume key | Replaced per machine; the distributed image's key only ever protected the empty image |
| Accounts | Born locked (`*`) on both machines; the gateway console autologins as `ombra` (no groups, two NOPASSWD grants: leak probe, health report) |
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
| Host channels | vmx keys disable copy/paste, drag-and-drop and shared folders; the guest also removes the drag-and-drop and hgfs plugins; display auto-fit stays |
| Browser | Tor Browser (alpha channel, the only one with linux-aarch64 builds) wrapped to use the gateway's SOCKS port; updater disabled |
| Passwords | KeePassXC; no crypto wallet ships |
| Updates | Packages frozen at the release image; updates arrive as new images |

## Build and supply chain

| Part | Design |
|---|---|
| `core/` | Rust crate cross-built to aarch64 musl-static (`core/build.sh`): unlock agent, first-use setup, terminal panel, status daemon, control-port filter |
| `build/` | Installer ISOs from pinned inputs: Debian netinst at a pinned sha256, vendored assets at pinned tag and hash, Rust binaries byte-compared against the build output |
| Installer | Unattended; parks visibly on failure instead of shipping a half-installed machine |
| Vendored assets | Renamed display metadata, upstream identifiers and licenses unchanged; provenance in `desktop/rootfs/usr/share/ombra-assets/README.md` |
| Release images | OVAs exported from fresh installs, scrubbed of builder residue, checksummed |

## Verification

| Check | Command |
|---|---|
| Rust tests | `cd core && cargo test` |
| Installer script walker | `python3 tests/build/late-command-walker.py` |
| ISO build and assertions | `bash tests/build/test-install-iso.sh` |
| Public hygiene | `bash tests/build/test-public-hygiene.sh` |
| Gateway leak suite | `tests/leaks/README.md` |
| Gateway health | `ombra-systemcheck` on the gateway console |

## Out of scope

- Tor bridges and pluggable transports
- Automatic OS updates
- Host-side device management
