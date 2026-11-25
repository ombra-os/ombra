# Ombra Threat Model

What Ombra defends against, what it does not, and where the trust
boundary sits. A protection not listed here is not provided.

## Purpose

A workstation on a Mac where network anonymity (not linking the user's IP
to their activity) does not depend on the workstation software behaving
correctly.

## Assets

| # | Asset | Meaning |
|---|---|---|
| 1 | Network identity | Unlinkability of the user's home IP from destinations and counterparties |
| 2 | Data at rest | Files, credentials, history and configuration on the desktop disk |
| 3 | Existence of sensitive activity | Lesser goal: that this person runs a Tor-routed environment at all |

## Adversaries

| # | Adversary | Capabilities |
|---|---|---|
| A1 | ISP or local network operator | Sees and records all host traffic; on-path manipulation |
| A2 | Remote counterparties | See the originating IP; run their own servers |
| A3 | Malicious or compromised app in the desktop | Full userland control; tries to learn the IP, scan the LAN or exfiltrate |
| A4 | Opportunistic physical thief | Steals the Mac or disk and sifts the filesystem later |
| A5 | Compromised macOS host | Malware running as the user or root on macOS |
| A6 | Global passive adversary | Observes large fractions of Tor ingress and egress |
| A7 | Targeted physical adversary | Evil-maid on the Mac or firmware, implants, coercion |

## Trust boundary

The boundary is the hypervisor: VMware Fusion, or UTM (QEMU 10 on Apple's Hypervisor framework) for the UTM archives.

| Zone | Contents | Trust |
|---|---|---|
| Untrusted | Desktop userland at runtime: apps, files, downloaded content | None |
| Ours | Desktop and gateway guest OS, built from this repository | Integrity rests on the build pipeline |
| Trusted computing base | Apple silicon, firmware and SEP; macOS; Fusion or UTM, whichever runs the VMs; the Ombra build chain | Full |
| Semi-trusted | Debian packages; the pinned downloads (Debian installer, Tor Browser, Electrum, Feather, SimpleX) | Debian packages are signed by Debian and checked by apt during the build. The pinned downloads are checked against a sha256 in `build/pins/` at build; any upstream signature was checked by the maintainer once, when the pin was made. SimpleX's arm64 build has no upstream signature |
| Not checked by Ombra | The hypervisor you install | The build and the images do not pin or check the Fusion or UTM version |

Ombra cannot defend the guest against the host. It defends the guest's
network identity against everyone the host talks to, and its disk against
everyone who gets the disk without the passphrase.

## Protected

| Threat | Mechanism |
|---|---|
| Network leaks (A2, A3): an app bypasses Tor, phones home or scans the LAN | Topology: the desktop has one NIC on the private link (10.55.10.0/24) whose only route is the gateway, which forwards nothing. IPv6 off: four layers on both machines (kernel parameter `ipv6.disable=1`, sysctl, network configuration, nft drop). |
| IP deanonymization (A1, A2, A3) | The desktop never holds a routable address. The gateway permits outbound only for the Tor uid, no DNS query leaves the gateway (names are resolved inside Tor for SOCKS clients), the desktop firewall rejects every destination except the gateway, and SOCKS-aware clients reach the network via `ALL_PROXY`. TCP that gets past the desktop firewall (for example with root on the desktop) is rejected by the gateway. The ISP sees Tor connections to guards, not destinations |
| Stored data read from a stolen disk (A4) | LUKS2 (argon2id) and encrypted swap. First use re-encrypts online under a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads) and retires the public build slot. The display manager waits for a Sealed disk. The desktop's virtual disk file on the Mac holds only ciphertext; what else the Mac can hold is under Host residue below |
| Passphrase guessing (A4) | Each guess costs one argon2id derivation at the fixed cost set in `core/src/welcome.rs` (1 GiB memory, 4 iterations, 2 threads). With a copy of the disk, guessing runs offline on the attacker's hardware at that cost per guess. At the console, attempts are unlimited: `tries=0` in crypttab, the Ombra unlock agent owns retries with no delay or lockout, and there is no initramfs shell on failure. The protection is a strong passphrase |
| Telling one Ombra install from another (A3) | Hostname and machine-id are fixed and the same on every install; internal addresses are fixed; no hostname in the gateway DHCP. Under Fusion, MACs are not pinned, so imports get random VMware MACs; under UTM every install has the same MACs. This does not hide Ombra: software inside the desktop can tell it runs on Ombra (`/etc/os-release` says Ombra, the fixed machine-id, the fixed address 10.55.10.100) and that it runs in a VM |

## Designed runtime probes

Every automatic request, and the on-demand checks that make requests.

| Component | Request | When |
|---|---|---|
| `ombra-statusd` (desktop, while a session is logged in) | A ping to the gateway, `status/circuit-established` from the gateway's control filter and an onion-name DNS query answered on the desktop by `ombra-tproxy` (none leave the gateway); `https://check.torproject.org/api/ip` through Tor to confirm the exit | Local checks every 30 s, every 5 s in the first 2 min after start until all are green. Exit check at most every 15 min, every 2 min after a failure, including when the control filter does not answer. |
| `ombra-gateway-notify` (desktop, while a session is logged in) | `GETINFO ombra/gateway-state` from the gateway's control filter (answered by the filter, never forwarded) | Once a minute |
| `ombra` panel (gateway console) | A ping, `https://check.torproject.org/api/ip` through Tor's SOCKS port (one retry), an onion-name DNS query answered on the machine itself (dnsmasq on the gateway, `ombra-tproxy` on the desktop) | Once at each console login; the console logs in automatically at boot. With `ombra --watch`, every 30 s until quit |
| `ombra` panel (desktop) | Same as the gateway panel | Only when the user runs it in a terminal; with `--watch`, every 30 s until quit |
| `ombra-systemcheck` (gateway) | `https://check.torproject.org/api/ip` through Tor's SOCKS port (one retry); a `tor-resolve` lookup of `deb.debian.org` through Tor; a resolve request for an onion name, which must return nothing; a direct HTTPS attempt as an ordinary user, which the firewall must reject before it leaves the gateway | Only on demand (`sudo ombra-systemcheck`); not at boot |
| `ombra-update check` (both) | Signed index `https://dl.ombra-os.org/updates/latest.txt` and its signature through Tor; on the desktop also the signed app list `updates/apps.txt` and its signature; the update itself downloads only when the user runs Update | 3 min after boot plus up to 2 min random delay, then daily. If the server cannot be reached, retried every 2 min, at most 8 starts an hour |
| `ombra-timesync` (both) | HTTPS `Date` header of one of `check.torproject.org`, `www.debian.org`, `archive.org` through Tor (the source rotates); all three, with a 2-of-3 agreement, before the clock steps | 90 s (gateway) or 2 min (desktop) after boot, then 5 min after each run ends. One request per run; three when the clock is more than 90 s off or the first source does not answer |
| `ombra-tor-freshness` (gateway) | Debian's signed package list for `trixie-security` from `deb.debian.org` through Tor, to see whether a newer Tor exists. Downloads no package and installs nothing | 3 min after boot plus up to 2 min random delay, then daily. If Debian cannot be reached, retried every 10 min, at most 6 starts an hour |
| `ombra-update security` (desktop; gateway with `--no-rollback`) | Debian's package lists and pending updates from `deb.debian.org` through Tor | Only when the user starts it (Update Ombra → Check Debian security updates). Never automatic. |

| Property | Value |
|---|---|
| What screens and logs show | Fixed per-state verdicts only (for example "all traffic routes through tor", green/yellow/red LED) |
| Response bodies | Dropped |
| Exit IP | Never displayed or logged by any component, including the gateway leak probe |
| Destination view | A Tor exit, not the user |
| Residual | The fixed cadence and curl's default user agent make this traffic recognizable as Ombra-like to a site operator or a global observer; it does not reveal the user's IP |

## Tor control port

The filter is `core/src/torctl.rs`; this table matches its allowlist.

| Item | Value |
|---|---|
| Filter | `ombra-torctl` on the gateway, own unprivileged user, loopback-only egress; listens on the private link, port 9052 |
| Before authentication | `PROTOCOLINFO` (answered locally with null authentication), `AUTHENTICATE`, `QUIT` |
| Authentication | An empty token or the shared public cookie pinned in `core/src/torctl.rs` and `desktop/late-command.sh`; any machine on the private link can authenticate |
| `GETINFO` | `version`, `onions/current`, `config-file`, `config-can-saveconf`, `status/bootstrap-phase`, `status/circuit-established`, `status/enough-dir-info`, `net/listeners/socks`; `circuit-status` is answered locally with an empty list |
| `GETCONF` | `HiddenServiceSingleHopMode`, `__OwningControllerProcess` (OnionShare's checks) |
| `SETEVENTS`, passed | `STATUS_CLIENT`, `STATUS_GENERAL`, `STATUS_SERVER` with only fixed fields (relay and guard addresses `HOSTADDR`, `HOSTID`, `SOURCE`, and `ADDRESS`, `HOSTNAME` removed, also from the `status/bootstrap-phase` answer); `BW`; `HS_DESC` only for services this connection created, with the directory relay replaced by a placeholder |
| `SETEVENTS`, stubbed | `CIRC`, `STREAM`, `SIGNAL` and `CONF_CHANGED` are acknowledged locally and deliver nothing. |
| `ADD_ONION` | For OnionShare only: a new or supplied ED25519-V3 key; flags limited to `V3Auth`, `DiscardPK`, `MaxStreamsCloseCircuit`; onion port 80 to a target port in 17600-17659 (or port 1 to 1); the target address is rewritten to the address of the asking connection; at most 8 per control connection; services end with their connection. Gateway and desktop firewalls open only 17600-17659 between the two machines |
| `DEL_ONION` | A well-formed v3 service id is passed to Tor |
| Refused | Everything else, with a 510 reply: `SETCONF`, `SAVECONF`, `SIGNAL`, `HSFETCH`, relay descriptors, other targets and ports |
| Consequence | Tor Browser's circuit display does not work, and New Identity cannot send Tor's NEWNYM signal (the browser still resets its state and uses fresh SOCKS credentials, which its port isolates). A compromised desktop can publish onion services on those ports from its own machine; it cannot reach other gateway ports or change Tor |

## Not protected

| Threat | Why |
|---|---|
| Compromised macOS host (A5) | Total compromise of the guest. The host can log keystrokes including the disk passphrase, read guest RAM and extract keys, snapshot and roll back the VM, silently change VM settings (add a NIC, re-enable clipboard or shared folders) and correlate Tor and clearnet use. Guest encryption protects data at rest only. Use dedicated hardware against this adversary |
| Hardware and physical attacks (A7) | Evil-maid on the Mac or firmware, implants, bus attacks and coercion are out of scope; no host secure-boot story |
| Tor-level adversaries (A6) | Entry and exit traffic confirmation, malicious exits seeing plaintext protocols, guard compromise and browser fingerprinting remain Tor's and the browser's problems; no fingerprinting claims |
| Tor daemon compromise | Tor is a large C program that handles data from the desktop and from the network, and bugs that give an attacker code execution in it have been found and fixed (for example TROVE-2026-036). Code running inside the gateway's Tor can learn the Mac's public address: the entry guard reports it to every client inside the Tor protocol (the NETINFO cell, and the `X-Your-Address-Is` header of directory answers), and Tor can send it anywhere through its own circuits. No sandbox or firewall rule on the gateway can prevent that, because both steps are Tor's normal work. What Ombra does instead is under [Tor daemon compromise](#tor-daemon-compromise-what-ombra-does); the full design is [TOR_HARDENING.md](TOR_HARDENING.md) |
| Fusion compromise or escape | A hypervisor 0-day or trojaned Fusion defeats everything. Ombra does not pin or check the Fusion version; download it from VMware and keep it current |
| UTM or QEMU compromise or escape | Same outcome as a Fusion escape. UTM runs QEMU, a large C code base that emulates the guest's devices (virtio, NVMe, vmxnet3, e1000e, USB) in a user process, and the bundles run QEMU's own interrupt controller (`-machine kernel-irqchip=off`) instead of the hypervisor's, which adds a little more emulation. The images keep those device models for guest compatibility, so a QEMU device bug is in scope of the trust you place in UTM. Mitigations: download UTM from its project, keep it current (Ombra does not check the version), and keep host-guest channels off (the bundle config is checked for every one of them) |
| Seizure while running (A4, A7) | Keys and plaintext are in guest RAM and the host can image live state; at-rest protection applies only when the VMs are off |
| Metadata | The ISP and Apple can see that this Mac runs Fusion or UTM and Tor; Fusion, UTM and macOS telemetry are outside Ombra's control |
| User error | Pasting identifying data, reusing identities across Tor and clearnet, installing random software, backing up to a clearnet service |

## Tor daemon compromise: what Ombra does

This makes such an attack harder to start, harder to finish and visible when it fails. It does not make a
successful one harmless (see Not protected).

| Layer | Measure | Effect |
|---|---|---|
| Reach | No automap, no DNSPort, no TransPort; DNS is answered locally (on the desktop by `ombra-tproxy`, on the gateway by dnsmasq) and never reaches Tor | The code path of TROVE-2026-036 cannot be reached from the desktop, on any Tor version. A compromised desktop can still speak SOCKS to Tor and make it contact servers and onion services of the attacker's choosing, as any website can |
| Confinement | System-call filter, no writable-and-executable memory, restricted socket families, kernel protections, `NoExec 1`; AppArmor profile mandatory on the gateway VM | Narrows what injected code can do and blocks starting other programs |
| Egress | The Tor uid goes out by TCP only, never to private, link-local, carrier-NAT, multicast or reserved addresses (firewall and cgroup filter) | A hijacked Tor cannot ask the home router for the public address, reach services on the Mac or scan the local network |
| Tripwire | A Tor that dies by a signal is restarted once per boot; a second death, or a kill by the system-call filter, leaves it down until the gateway is restarted. The desktop shows a notice either way | An exploit gets two attempts per boot instead of unlimited silent ones. A crash is usually a fault, and it can also follow a successful attack, so the notice does not say which |
| Freshness | At boot and daily the gateway asks Debian, through Tor, whether a newer Tor exists, and the desktop shows a notice until it is installed | A gateway does not stay on a Tor with published bugs unnoticed |

| Limit | Detail |
|---|---|
| Transparent proxying moved, not removed | Programs without proxy settings are served by `ombra-tproxy` on the desktop, which speaks only SOCKS `CONNECT` to Tor. Its name table, which does the job of Tor's automap, runs in a memory-safe program on the untrusted side, where filling it makes new names fail and nothing else |
| Bugs in what Tor reads from the network | Onion service descriptors, cells from a hostile exit or relay and directory documents are still parsed by Tor. Only the confinement and the tripwire stand against a bug there |
| Restarting after the tripwire | Restarting an Amnesic gateway picks new entry guards. Someone able to crash Tor twice could force that; Persistent mode keeps the guards |
| Desktop SOCKS | Tor's own SOCKS parser, resolve commands included, is still reachable from the desktop |

## Host residue

What the Mac can keep, whatever the guest does. Amnesic mode controls only what the guest writes.

| Item | Detail |
|---|---|
| Suspend and saved state | Suspending or saving a VM's state writes its RAM to the Mac's disk, including the desktop's disk key and everything in an Amnesic session. Shut the VMs down instead |
| Hypervisor logs | Fusion and UTM keep their own logs and settings for each VM on the Mac |
| Host backups and snapshots | A Time Machine backup, cloud sync or hypervisor snapshot of the VM folder keeps an old copy of the encrypted disk. An old copy holds the LUKS header as it was then, so it opens with the passphrase that was valid then, even after you change it |

## Privacy applications

| Application | Note |
|---|---|
| All | Preset to the gateway SOCKS port. The desktop firewall rejects every destination except the gateway. The TCP connections of an application that ignores its proxy setting are carried to Tor by `ombra-tproxy` (see Residual risks, Programs not built for Tor). It cannot leak the address |
| Wallets (Electrum, Feather) | In Amnesic mode the wallet file and seed vanish at shutdown. Write the seed down or copy it somewhere you control before shutdown. Light wallets reveal addresses to the servers they query, over Tor |
| OnionShare | The onion address is reachable by anyone who holds it. Share the address and key only over a channel you trust |
| Kleopatra | Keys live in the home directory: encrypted at rest in Persistent mode, lost in Amnesic mode unless exported. Keyserver lookups go through Tor only |
| SimpleX | The upstream arm64 desktop build is not signed. The image pins its sha256 but cannot verify an upstream signature. It reaches the network through a proxychains wrapper because the application has no SOCKS setting Ombra can preset |
| SimpleX conditions | SimpleX shows its conditions of use on first launch and the user accepts or declines them; Ombra does not pre-accept. Amnesic mode asks again each session |
| Electrum | The electrum.org release, pinned by sha256 and unpacked into `/opt/electrum`; it runs on Debian trixie's Python and Qt 6. Its upstream signature was checked by the maintainer once, when the pin was made |
| Feather | Its bundled Tor is not used. The AppImage is pinned by sha256 and checked at build; its upstream signature was checked by the maintainer once, when the pin was made |

## Boot modes

| Mode | Gateway | Desktop |
|---|---|---|
| Amnesic | Tor state discarded at shutdown; new entry guards chosen every boot | What the guest writes, root and home included, lives in RAM and is gone at shutdown, including the browser profile and files. The Mac can still keep copies (see Host residue) |
| Persistent | Tor state and guards kept on the unencrypted disk | Writes to the encrypted disk |

| Limit | Detail |
|---|---|
| Boot menu | The GRUB menu and theme sit in the unencrypted boot area; anyone with the disk can see that Ombra is installed and which two entries exist |
| Amnesic scope | Does not defend against compromise during the session, RAM capture while running, what the Mac saves (Host residue), or what Tor and upstream networks observe |

## Residual risks accepted

| Risk | Detail |
|---|---|
| First-use window | Until first boot completes, the disk opens with the public build passphrase. A copy of the image from before first boot holds the original volume key, which protects only the empty disk. A power cut during re-encryption is recoverable but leaves the machine unusable until the Resume screen finishes the job. The account password is set at the start of setup, so its hash is first written under the public key: a snapshot or backup of the VM taken during those minutes holds the hash in a form anyone with the image can read, for offline guessing. Setting it afterwards would risk a sealed disk with a locked account if power failed in between |
| Entry guards on an Amnesic gateway | The gateway's boot menu highlights Amnesic first. In Amnesic mode Tor picks new entry guards on every boot, so over many boots the chance of picking a hostile guard grows. Persistent mode keeps the guards |
| Shared private link | The link is a host-only network shared with the Mac and any other VM attached to it; a co-resident VM can observe and reach both machines at layer 2. The gateway trusts by source address (any 10.55.10.0/24 host can use its DNS, SOCKS and control filter), so attach no other VM to that network. The Mac itself has an address on the link (10.55.20.100 under UTM), so a guest whose root account is compromised could reach any service the Mac listens on across all interfaces: keep the macOS firewall on and file sharing off. The no-egress guarantee comes from the single NIC and the gateway firewall. |
| Fixed MAC addresses under UTM | A UTM bundle carries its network cards' MAC addresses and UTM keeps them on import, so every UTM user has the same MACs on the private link. They exist only between the two VMs and the Mac; the gateway's NAT hides its MAC from the home network. Importing the same archive twice on one Mac puts two VMs with the same MACs on the link, which breaks both until one is deleted or its MAC is changed in UTM |
| No bridges or pluggable transports | The gateway's torrc has no bridge or transport lines. The local network and ISP can see that the Mac uses Tor, and Ombra does not work where Tor is blocked |
| Programs not built for Tor | Any program on the desktop can reach the internet through Tor without being configured for it. Its traffic is anonymous at the network level like everything else, but a program that was not written with Tor in mind can identify you by what it sends: an account it logs in to, a device or install identifier, an update check with a serial number. Tor Browser and the shipped applications are unaffected. `ombra-tproxy` itself adds no way out: it can only reach the gateway's SOCKS port. systemd holds its ports, so no other program can take them; if it stops, redirected traffic waits and goes nowhere. Its name table is shared by all programs on the desktop: placeholders are random, never re-pointed while in use, and not listable; a program that floods it is rate-limited per user and at worst makes new names fail for a while |
| Stream isolation | SOCKS port 9050 isolates by destination address and port, and 9150 by the browser's SOCKS credentials. Connections carried by `ombra-tproxy` use port 9050 |
| Tor Browser channel | The image ships the stable channel for linux-aarch64 (pinned in `build/pins/torbrowser.txt`). Linux on ARM is a newer platform with fewer users than the x86 desktop builds, so its users are a smaller crowd, and rendering inside a VM can differ from a typical install |
| Update signing | Updates are signed with one Ed25519 key held by the maintainer. There is no threshold signing and no transparency log; whoever holds that key can sign an update |
| Prebuilt binaries | The Rust binaries in `core/dist/aarch64/` are committed to the repository and used for the release images. `core/verify-dist.sh` checks that they match the source |
| Hypervisor guest operations | Fusion: `vmtoolsd` and `vgauth` stay enabled, so `vmrun` guest operations work for anyone with a guest password; the release accounts are born locked, so they cannot authenticate. UTM: `qemu-guest-agent` answers only `guest-sync`, `guest-sync-delimited`, `guest-ping` and `guest-info` (`/etc/qemu/qemu-ga.conf`) |
| Initial clock | At boot the guest clock comes from the virtual hardware clock, which the hypervisor sets from the Mac. Ombra's Fusion VM settings present it in UTC (`rtc.diffFromUTC = "0"`, checked by the bundle verifier), and the UTM bundles keep `RTCLocalTime` off. In each case `ombra-timesync` corrects the clock over Tor 90 s (gateway) or 2 min (desktop) after boot; until then software in the guest can see the offset, which reveals the Mac's time zone |
| Build-from-source exposure | The installer fetches Debian packages and does NTP over the host's NAT from the builder's real IP; the release archives (`.vmwarevm.zip`, `.utm.zip`) have no such step. Before contacting apt it takes the time from the `Date` header of `https://deb.debian.org/` when the installer clock is more than 60 s off; it assumes no build-host time zone |
| Host-guest channels | Clipboard, drag-and-drop and shared folders are off in the VM configuration and the desktop removes the guest plugins; display auto-fit stays on. Under UTM the clipboard setting is enforced by UTM on the Mac, not inside the guest (`spice-vdagent` has no switch to disable it), so a user who turns clipboard sharing on in UTM opens that channel. UTM's display socket has no password; it sits in UTM's own data folder, which macOS protects from other apps, so reaching it takes access to that folder |
| Application surface | Five more applications enlarge the guest's code and the image by about 1 GB; each is a separate attack surface inside the untrusted zone |
| Sound and USB | The desktop VM has a virtual sound device and USB controller; microphone access follows the macOS permissions granted to Fusion. Under UTM there is no sound device; the USB controller carries only keyboard and pointer, with USB sharing off (UTM adds three idle usb-redir channels that carry nothing unless a device is attached through UTM) |
| Build pipeline | The build machine and its keys are a single point of compromise; there is no independent build verification. Debian packages come from the live trixie suite at build time, so builds are not reproducible |
| Clock skew | The Tor-routed time consensus narrows the skew window but is itself visible to a global adversary as periodic probe traffic |
| Unencrypted gateway disk | It holds no user data; an attacker with it learns the shipped image and, in Persistent mode, Tor's state |
| Browser and package freshness | Tor Browser's own updater is off and nothing runs apt on its own. Tor Browser, Feather, SimpleX and Electrum fixes arrive as app updates the user starts (Update Ombra): the signed app list names each version and hash, and the app is downloaded from its own project through Tor. A Debian fix arrives as an Ombra update, or when the user runs Check Debian security updates (`ombra-update security`). Until then the machine runs the older code |
| No independent audit | Ombra has not been independently audited |
