# Ombra gateway

Headless Debian (arm64) VM that moves bytes between `ombra-desktop` and
the Tor network and does nothing else. It is fail-closed: the desktop's
only link is the private link whose other member is this VM, and nothing
leaves the NAT NIC except the `debian-tor` user's traffic.

## Contents

One line per file; the constraint that matters is stated with it.

| Path | What it is |
|------|------------|
| `rootfs/etc/nftables.conf` | The firewall. Desktop-facing accepts are port-scoped (DNS, Tor ports, control-port filter, ICMP echo); no ssh rule exists |
| `rootfs/etc/tor/torrc` | Client-only Tor: SocksPort 10.55.10.1:9050, TransPort :9040, DNSPort 127.0.0.1:5353, loopback cookie-auth ControlPort 9051; `DormantTimeoutEnabled 0` |
| `rootfs/etc/dnsmasq.d/ombra.conf` | DNS-only resolver for the desktop; its only upstream is Tor's DNSPort; no DHCP on the private link |
| `rootfs/etc/sysctl.d/60-ombra-gateway.conf` | No forwarding, strict rp_filter, ARP hardening, no TCP timestamps, privilege-surface cuts; keep `icmp_echo_ignore_all=0` (the desktop pings the gateway) |
| `rootfs/etc/default/grub.d/50-ombra.cfg` | Kernel command line, including `ipv6.disable=1` |
| `rootfs/etc/systemd/network/*` | driver-matched interface renames and networkd config; see the README in that directory before editing |
| `rootfs/etc/systemd/journald.conf.d/10-ombra-volatile.conf` | Volatile, size-capped journal |
| `rootfs/etc/sudoers.d/*` | The two NOPASSWD grants: the leak probe, and starting the health report |
| `rootfs/usr/local/sbin/ombra-timesync` (+ service, timer) | Steps the clock from a 2-of-3 consensus of HTTPS Date headers fetched through Tor's SOCKS port; on disagreement it changes nothing |
| `rootfs/usr/local/sbin/ombra-systemcheck` (+ service) | Boot health report on tty1 and on demand (`sudo ombra-systemcheck`); exit code is the failure count; never prints an exit IP |
| `rootfs/usr/local/sbin/ombra-leak-probe` | The shipped leak probe (see `tests/leaks/README.md`) |
| `rootfs/usr/local/sbin/ombra-splash`, `ombra-firstboot` | The tty1 ring splash and the one-shot first-boot finisher |
| `rootfs/usr/local/bin/ombra-torctl-filter` (+ service) | Re-publishes Tor's control port to the private link on :9052 as a read-only dialect (`core/src/torctl.rs`); runs as its own `ombra-torctl` uid with loopback-only egress |
| `rootfs/usr/local/bin/ombra` | The connectivity panel for the gateway console (`core/` crate, static build) |
| `rootfs/etc/os-release`, `issue`, `issue.net`, `motd`, `lsb-release` | Ombra identity; Debian compatibility fields stay machine-facing; no version number on any human surface |
| `rootfs/etc/systemd/system/` masks | Serial getty and cron are masked; `vmtoolsd` and `vgauth` must stay enabled or vmrun guest operations fail |
| `preseed.cfg`, `late-command.sh` | The unattended installer path, packed into the ISO by `build/make-install-iso.sh gateway`; failures park visibly |

Notes on specific rows:

- **Control-port filter.** Only bootstrap and version GETINFOs and status
  events are allowed; everything else gets a single 510 reply. STREAM and
  CLIENTS_SEEN events are refused because STREAM would relay every
  desktop connection's destination onto the private link. The filter
  reads Tor's group-readable cookie via `SupplementaryGroups=debian-tor`,
  and the desktop's browser authenticates with a shared public cookie
  pinned in `core/src/torctl.rs` and `desktop/late-command.sh`.
- **Health report.** Checks Tor bootstrap, firewall equals the shipped
  file, fail-closed egress, Tor-only DNS, `.onion` automap, a SOCKS
  IsTor proof, the clock verdict, failed units, the listener whitelist
  and the absence of any unix control socket. DNS is checked through Tor's
  resolver because dnsmasq serves only `ombra-intnet`.
- **Identity.** `/usr/lib/os-release` and `/etc/debian_version` are
  dpkg-diverted at install so base-files cannot restore them.
- **Installer.** The late command also freezes the static resolver
  (`chattr +i`), sets UTC and the quiet kernel line, purges
  netcat/telnet and disables the timesyncd and apt timers.

## Boot modes

The menu waits for a choice; there is no countdown.

| Entry | Kernel line | Effect |
|---|---|---|
| Ombra — Amnesic (highlighted first) | Overlay from `/etc/overlayroot.conf` | RAM-only upper layer; Tor state discarded at power-off |
| Ombra — Persistent | Adds `overlayroot=disabled` | Tor state, chosen guards included, stays on disk |

`/etc/grub.d/09_ombra` is the only entry generator; recovery, the
advanced submenu and the firmware entry are disabled. The overlay tmpfs
is half of RAM (about 230 MB).

## IPv6

IPv6 is disabled at four layers:

| Layer | Setting |
|-------|---------|
| Kernel command line | `ipv6.disable=1` (the sysctl lines carry a `-` prefix because the keys do not exist then) |
| sysctl | `all` and `default` `disable_ipv6=1` |
| systemd-networkd | `IPv6AcceptRA=no` and `LinkLocalAddressing=no` in both `.network` files |
| nftables | `inet` table with policy drop |

## VM shape

| Item | Value |
|------|-------|
| Storage | 5 GB NVMe, unencrypted (the gateway holds no user data) |
| Amnesic mode | Inside the guest: `overlayroot` mounts the disk read-only and layers a RAM (tmpfs) upper, so every boot starts from the shipped image and session writes die at power-off. Independent of the hypervisor disk mode; the tmpfs may grow to half of RAM (about 230 MB) |
| NIC 1 | NAT, `vmxnet3` (identified by driver, not MAC); the only upstream, Tor-only through the firewall |
| NIC 2 | Private link, `e1000e` (identified by driver, not MAC), static 10.55.10.1/24; disconnected during install |
| MAC addresses | Not pinned by the guest; imported images get random MACs and the guest behaves identically (a build vmx may still carry fixed ones) |
| RAM | 512 MB |
| Host-guest channels | Clipboard, drag-and-drop, shared folders and GUI-options sync disabled in the vmx; host time sync off |
| Console | tty1 autologin of `ombra`, a born-locked account (`*`, no groups) whose only privileges are the two sudoers grants |
| Remote access | None: no sshd, no NAT port-forward, no ssh firewall exception |
| Audit | `build/fusion/create-gateway-vm.sh --verify [--fix]` checks the whole set |

## Leak suite

`tests/leaks/run-gateway-leaks.sh` drives the shipped probe over vmrun
guest operations, which need a guest password. Release images are born
locked, so the suite cannot authenticate against them. On a build VM,
build the test-only gateway ISO with
`OMBRA_TEST_GUEST_PASSWORD=... bash build/make-install-iso.sh gateway`
and create the VM from it; details are in `tests/leaks/README.md`. On a
release image, run the probe at the gateway console with
`sudo /usr/local/sbin/ombra-leak-probe`.

## Invariants

Violating any of these blocks a release.

1. **live == shipped**: every file in `rootfs/` matches the running VM in content and mode.
2. **Amnesic mode holds**: in Amnesic mode `findmnt -no FSTYPE /` is `overlay`; `ombra-systemcheck` reports the mode and fails if the overlay is missing when amnesic.
3. **Leak suite green**, including the control-port filter isolation test.
4. **Desktop-reachable surface** is exactly DNS, Tor 9040/9050, the control-port filter on 9052, and ICMP echo.
5. **Egress** is exactly `debian-tor` on the upstream NIC, loopback, the gateway's own upstream DHCP client, and PMTUD.
6. **No sshd**: no package or config ships, and nothing listens on or accepts :22.

## Known gaps

- The transparent-proxy path (private link to :9040) is asserted structurally; a paired desktop install exercises it live.
