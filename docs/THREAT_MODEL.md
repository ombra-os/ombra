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

The boundary is the VMware Fusion hypervisor.

| Zone | Contents | Trust |
|---|---|---|
| Untrusted | Desktop userland at runtime: apps, files, downloaded content | None |
| Ours | Desktop and gateway guest OS, pinned at build | Integrity rests on the build pipeline |
| Trusted computing base | Apple silicon, firmware and SEP; macOS; Fusion; the Ombra build chain | Full |
| Semi-trusted | Debian, Tor and Fusion packages | Independently verifiable signatures |

Ombra cannot defend the guest against the host. It defends the guest's
network identity against everyone the host talks to, and its disk against
everyone who gets the disk without the passphrase.

## Protected

| Threat | Mechanism |
|---|---|
| Network leaks (A2, A3): an app bypasses Tor, phones home or scans the LAN | Topology: the desktop has one NIC on the private link (10.55.10.0/24) whose only route is the gateway, which forwards nothing. IPv6 off: three layers on the desktop (sysctl, network configuration, nft drop), four on the gateway (plus `ipv6.disable=1`) |
| IP deanonymization (A1, A2, A3) | The desktop never holds a routable address. The gateway permits outbound only for the Tor uid, DNS resolves only through Tor, the desktop firewall rejects every destination except the gateway, SOCKS-aware clients reach the network via `ALL_PROXY`, and stray TCP is redirected into Tor's TransPort. The ISP sees Tor connections to guards, not destinations |
| Stored data read from a stolen disk (A4) | LUKS2 (argon2id) and encrypted swap. First use re-encrypts online under a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads) and retires the public build slot. The display manager waits for a Sealed disk. The host stores only ciphertext |
| Unlock brute force at the console (A4) | `tries=0` in crypttab; the Ombra unlock agent owns retries; no initramfs shell on failure |
| Fingerprinting as an Ombra box (A3) | Fixed generic hostname and machine-id; own internal addressing; no hostname in the gateway DHCP; MACs not pinned, so imports get random VMware MACs while emulated NIC models stay the same |

## Designed runtime probes

| Component | Request | Cadence |
|---|---|---|
| `ombra-statusd` (desktop) | `https://check.torproject.org/api/ip` through the gateway SOCKS port, a ping to the gateway, an onion-name DNS query answered by the gateway | About every 30 s while a session is logged in |
| `ombra-update check` (both) | Signed index `https://dl.ombra-os.org/updates/latest.txt` through Tor; the update itself downloads only when the user runs Update | A few minutes after boot, then daily |
| `ombra-timesync` (both) | HTTPS `Date` header of `check.torproject.org`, `www.debian.org`, `archive.org` through Tor; clock steps only when two of three agree | Every 30 min |

| Property | Value |
|---|---|
| What screens and logs show | Fixed per-state verdicts only (for example "all traffic routes through tor", green/yellow/red LED) |
| Response bodies | Dropped |
| Exit IP | Never displayed or logged by any component, including the gateway leak probe |
| Destination view | A Tor exit, not the user |
| Residual | The fixed cadence and curl's default user agent make this traffic recognizable as Ombra-like to a site operator or a global observer; it does not reveal the user's IP |

## Tor control port

| Item | Value |
|---|---|
| Filter | `ombra-torctl` on the gateway, own unprivileged user, loopback-only egress |
| Passed | `PROTOCOLINFO` (answered locally with null authentication), `AUTHENTICATE`, `QUIT` |
| `GETINFO` | `version`, `config-file`, `config-can-saveconf`, `status/bootstrap-phase`, `status/circuit-established`, `status/enough-dir-info`, `net/listeners/socks` |
| `SETEVENTS` | `STATUS_CLIENT`, `STATUS_GENERAL`, `STATUS_SERVER`, `CONF_CHANGED`, `BW`, `HS_DESC`; `CIRC`, `STREAM` and `SIGNAL` are acknowledged locally and deliver nothing |
| `ADD_ONION` / `DEL_ONION` | Allowed for OnionShare only: the target is rewritten to the desktop address, the virtual port range is 17600-17659, at most 8 services per control connection, and a service is removed with its connection. Gateway and desktop firewalls open only that range between the two machines |
| Refused | Everything else: relay descriptors, `SETCONF`, `SIGNAL`, `HSFETCH`, arbitrary targets |
| Consequence | Tor Browser's circuit display and New Identity do not work. A compromised desktop can publish onion services on those ports from its own machine; it cannot reach other gateway ports or change Tor |

## Not protected

| Threat | Why |
|---|---|
| Compromised macOS host (A5) | Total compromise of the guest. The host can log keystrokes including the disk passphrase, read guest RAM and extract keys, snapshot and roll back the VM, silently change VM settings (add a NIC, re-enable clipboard or shared folders) and correlate Tor and clearnet use. Guest encryption protects data at rest only. Use dedicated hardware against this adversary |
| Hardware and physical attacks (A7) | Evil-maid on the Mac or firmware, implants, bus attacks and coercion are out of scope; no host secure-boot story |
| Tor-level adversaries (A6) | Entry and exit traffic confirmation, malicious exits seeing plaintext protocols, guard compromise and browser fingerprinting remain Tor's and the browser's problems; no fingerprinting claims |
| Fusion compromise or escape | A hypervisor 0-day or trojaned Fusion defeats everything; mitigation is verified downloads and pinned versions |
| Seizure while running (A4, A7) | Keys and plaintext are in guest RAM and the host can image live state; at-rest protection applies only when the VMs are off |
| Metadata | The ISP and Apple can see that this Mac runs Fusion and Tor; Fusion and macOS telemetry are outside our control |
| User error | Pasting identifying data, reusing identities across Tor and clearnet, installing random software, backing up to a clearnet service |

## Privacy applications

| Application | Note |
|---|---|
| All | Preset to the gateway SOCKS port. The desktop firewall still rejects every destination except the gateway, so an application that ignores its proxy setting fails rather than leaks |
| Wallets (Electrum, Feather) | In Amnesic mode the wallet file and seed vanish at shutdown. Write the seed down or copy it somewhere you control before shutdown. Light wallets reveal addresses to the servers they query, over Tor |
| OnionShare | The onion address is reachable by anyone who holds it. Share the address and key only over a channel you trust |
| Kleopatra | Keys live in the home directory: encrypted at rest in Persistent mode, lost in Amnesic mode unless exported. Keyserver lookups go through Tor only |
| SimpleX | The upstream arm64 desktop build is not signed. The image pins its sha256 but cannot verify an upstream signature. It reaches the network through a proxychains wrapper because the application has no SOCKS setting we can preset |
| SimpleX conditions | SimpleX shows its conditions of use on first launch and the user accepts or declines them; Ombra does not pre-accept. Amnesic mode asks again each session |
| Feather | Its bundled Tor is not used; the signed upstream archive is verified at build time |

## Boot modes

| Mode | Gateway | Desktop |
|---|---|---|
| Amnesic | Tor state discarded at shutdown; fresh guard sample per boot | Root and home live in RAM and vanish at shutdown, including the browser profile and files |
| Persistent | Tor state and guards kept on the unencrypted disk | Writes to the encrypted disk |

| Limit | Detail |
|---|---|
| Boot menu | The GRUB menu and theme sit in the unencrypted boot area; anyone with the disk can see that Ombra is installed and which two entries exist |
| Amnesic scope | Does not defend against compromise during the session, RAM capture while running, or what Tor and upstream networks observe |

## Residual risks accepted

| Risk | Detail |
|---|---|
| First-use window | Until first boot completes, the disk opens with the public build passphrase. A copy of the image from before first boot holds the original volume key, which protects only the empty disk. A power cut during re-encryption is recoverable but leaves the machine unusable until the Resume screen finishes the job |
| Guard sample per boot | Amnesic gateway mode trades Tor's persistent-guard protection for a stateless gateway; Persistent mode keeps the guards |
| Shared private link | The link is shared with the host adapter and any other VM attached to it; a co-resident VM can observe and reach both machines at layer 2. The no-egress guarantee comes from the single NIC and the gateway firewall |
| Build-from-source exposure | The installer fetches Debian packages and does NTP over the host's NAT from the builder's real IP; release OVAs have no such step |
| Host-guest channels | Clipboard, drag-and-drop and shared folders are off in the VM configuration and the desktop removes the guest plugins; display auto-fit stays on |
| Application surface | Five more applications enlarge the guest's code and the image by about 1 GB; each is a separate attack surface inside the untrusted zone |
| Sound and USB | The desktop VM has a virtual sound device and USB controller; microphone access follows the macOS permissions granted to Fusion |
| Build pipeline | The build machine and its keys are a single point of compromise until independent verification exists |
| Clock skew | The Tor-routed time consensus narrows the skew window but is itself visible to a global adversary as periodic probe traffic |
| Unencrypted gateway disk | It holds no user data; an attacker with it learns the shipped image and, in Persistent mode, Tor's state |
| No independent audit | Ombra has not been independently audited |
