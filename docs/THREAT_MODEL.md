# Ombra Threat Model

What Ombra defends against, what it does not, and where the trust
boundary sits. A protection not listed here is not provided.

Sections below describe the two-VM edition unless they say otherwise. The
single VM edition differs where
[Two VMs vs single VM](#two-vms-vs-single-vm) says so.

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

The boundary is the hypervisor: VMware Fusion, or UTM (QEMU 10 on Apple's Hypervisor framework) for the UTM archives. In the single VM edition there is no hypervisor boundary between the desktop and Tor's side: they share one kernel (see [Two VMs vs single VM](#two-vms-vs-single-vm)).

| Zone | Contents | Trust |
|---|---|---|
| Untrusted | Desktop userland at runtime: apps, files, downloaded content | None |
| Ours | Desktop and gateway guest OS, built from this repository | Integrity rests on the build pipeline |
| Trusted computing base | Apple silicon, firmware and SEP; macOS; Fusion or UTM, whichever runs the VMs; the Ombra build chain | Full |
| Semi-trusted | Debian packages; the pinned downloads (Debian installer, Tor Browser, Feather, SimpleX) | Debian packages are signed by Debian and checked by apt during the build (single VM edition: during your install). The pinned downloads are checked against a sha256 in `build/pins/` at build; any upstream signature was checked by the maintainer once, when the pin was made. SimpleX's arm64 build has no upstream signature |
| Not checked by Ombra | The hypervisor you install | The build and the images do not pin or check the Fusion or UTM version |

Ombra cannot defend the guest against the host. It defends the guest's
network identity against everyone the host talks to, and its disk against
everyone who gets the disk without the passphrase.

## Protected

| Threat | Mechanism |
|---|---|
| Network leaks (A2, A3): an app bypasses Tor, phones home or scans the LAN | Topology: the desktop has one NIC on the private link (10.55.10.0/24) whose only route is the gateway, which forwards nothing. IPv6 off: four layers on both machines (kernel parameter `ipv6.disable=1`, sysctl, network configuration, nft drop). Desktops installed from v1.1.0 images lack the kernel parameter and have the other three |
| IP deanonymization (A1, A2, A3) | The desktop never holds a routable address. The gateway permits outbound only for the Tor uid, DNS resolves only through Tor, the desktop firewall rejects every destination except the gateway, and SOCKS-aware clients reach the network via `ALL_PROXY`. TCP that gets past the desktop firewall (for example with root on the desktop) is redirected into Tor's TransPort; on the single VM edition root can bypass Tor entirely (see Two VMs vs single VM). The ISP sees Tor connections to guards, not destinations |
| Stored data read from a stolen disk (A4) | LUKS2 (argon2id) and encrypted swap. First use re-encrypts online under a new volume key (aes-xts-plain64, 512-bit; argon2id 1 GiB, 4 iterations, 2 threads) and retires the public build slot. The display manager waits for a Sealed disk. The desktop's virtual disk file on the Mac holds only ciphertext; what else the Mac can hold is under Host residue below |
| Passphrase guessing (A4) | Each guess costs one argon2id derivation: two-VM edition, at the fixed cost set in `core/src/welcome.rs` (1 GiB memory, 4 iterations, 2 threads); single VM edition, at the cost cryptsetup benchmarked on your machine during the install (1 GiB memory measured on a 6 GB VM). With a copy of the disk, guessing runs offline on the attacker's hardware at that cost per guess. At the console, attempts are unlimited: `tries=0` in crypttab, the Ombra unlock agent owns retries with no delay or lockout, and there is no initramfs shell on failure. The protection is a strong passphrase |
| Telling one Ombra install from another (A3) | Hostname and machine-id are fixed and the same on every install; internal addresses are fixed; no hostname in the gateway DHCP. Under Fusion, MACs are not pinned, so imports get random VMware MACs; under UTM every install has the same MACs. This does not hide Ombra: software inside the desktop can tell it runs on Ombra (`/etc/os-release` says Ombra, the fixed machine-id, the fixed address 10.55.10.100) and that it runs in a VM |

## Designed runtime probes

Every automatic request, and the on-demand checks that make requests.

| Component | Request | When |
|---|---|---|
| `ombra-statusd` (desktop, while a session is logged in) | A ping to the gateway, `status/circuit-established` from the gateway's control filter and an onion-name DNS query answered by the gateway (none leave the gateway); `https://check.torproject.org/api/ip` through Tor to confirm the exit | Local checks every 30 s, every 5 s in the first 2 min after start until all are green. Exit check at most every 15 min, every 2 min after a failure, including when the control filter does not answer. These cadences apply from v1.2.0; v1.1.0 checks the exit about every 30 s |
| `ombra` panel (gateway console) | A ping, `https://check.torproject.org/api/ip` through Tor's SOCKS port (one retry), an onion-name DNS query | Once at each console login; the console logs in automatically at boot. With `ombra --watch`, every 30 s until quit |
| `ombra` panel (desktop) | Same as the gateway panel | Only when the user runs it in a terminal; with `--watch`, every 30 s until quit |
| `ombra-systemcheck` (gateway) | `https://check.torproject.org/api/ip` through Tor's SOCKS port (one retry); a `tor-resolve` lookup of `deb.debian.org` through Tor; an onion-name lookup at Tor's DNSPort; a direct HTTPS attempt as an ordinary user, which the firewall must reject before it leaves the gateway | Only on demand (`sudo ombra-systemcheck`); not at boot |
| `ombra-update check` (both) | Signed index `https://dl.ombra-os.org/updates/latest.txt` and its signature through Tor; on the desktop also the signed app list `updates/apps.txt` and its signature (from 1.2.1); the update itself downloads only when the user runs Update | 3 min after boot plus up to 2 min random delay, then daily. If the server cannot be reached, retried every 2 min, at most 8 starts an hour |
| `ombra-timesync` (both) | HTTPS `Date` header of one of `check.torproject.org`, `www.debian.org`, `archive.org` through Tor (the source rotates); all three, with a 2-of-3 agreement, before the clock steps | 90 s (gateway) or 2 min (desktop) after boot, then 5 min after each run ends. One request per run; three when the clock is more than 90 s off or the first source does not answer |
| `ombra-update security` (desktop; gateway with `--no-rollback`) | Debian's package lists and pending updates from `deb.debian.org` through Tor | Only when the user starts it (Update Ombra → Check Debian security updates). Never automatic. Not in the v1.1.0 images |

Single VM edition: the same desktop rows apply. The gateway container has
no console panel, no update check and no `ombra-timesync` of its own (the
desktop sets the one shared clock).

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
| `SETEVENTS`, stubbed | `CIRC`, `STREAM`, `SIGNAL` and `CONF_CHANGED` are acknowledged locally and deliver nothing. `CONF_CHANGED` is stubbed from v1.2.0; v1.1.0 forwards it |
| `ADD_ONION` | For OnionShare only: a new or supplied ED25519-V3 key; flags limited to `V3Auth`, `DiscardPK`, `MaxStreamsCloseCircuit`; onion port 80 to a target port in 17600-17659 (or port 1 to 1); the target address is rewritten to the address of the asking connection; at most 8 per control connection; services end with their connection. Gateway and desktop firewalls open only 17600-17659 between the two machines |
| `DEL_ONION` | A well-formed v3 service id is passed to Tor |
| Refused | Everything else, with a 510 reply: `SETCONF`, `SAVECONF`, `SIGNAL`, `HSFETCH`, relay descriptors, other targets and ports |
| Consequence | Tor Browser's circuit display does not work, and New Identity cannot send Tor's NEWNYM signal (the browser still resets its state and uses fresh SOCKS credentials, which its port isolates). A compromised desktop can publish onion services on those ports from its own machine; it cannot reach other gateway ports or change Tor |

## Two VMs vs single VM

The single VM edition runs the gateway (the same Tor, dnsmasq, nftables
ruleset and control-port filter files as the gateway VM) as a
`systemd-nspawn` container inside the desktop VM. The container boots from
a read-only image (`/var/lib/ombra/gateway.img`) with its writes in RAM, in
its own user namespace, with no-new-privileges, a reduced capability set
and memory and task limits. It owns the VM's only network card; the desktop
reaches it over a virtual link with the two-VM addresses (10.55.10.100 to
10.55.10.1).

| | Two VMs | Single VM |
|---|---|---|
| Who it is for | Stronger isolation | Convenience: one download, one VM, less memory |
| Boundary between your apps and Tor's side | The hypervisor | The Linux kernel both share |
| Kernel exploit from any desktop app | Stays in the desktop VM unless it also escapes the hypervisor; the gateway is a separate VM | Reaches the Tor side too, and with it the network card: Tor can be bypassed |
| Root on the desktop | Cannot change the gateway; TCP that gets past the desktop firewall is redirected into Tor (the private link is still shared with the Mac, see Shared private link) | Can stop or modify the container, take the network card back and bypass Tor. The image hash check and the immutable flag stop accidents and non-root code, not root |
| A compromised app running as the user | Cannot bypass Tor | Cannot bypass Tor (a direct connection is refused) |
| Desktop firewall | Allows only 10.55.10.1 | Allows only 10.55.10.1, and only over the link to the container |
| If Tor's side is down | Desktop has no network | Desktop has no network: without the container there is no link to 10.55.10.1, NetworkManager leaves the VM's network card unconfigured, and the desktop firewall passes nothing through it |
| Gateway image integrity | Its own disk | Hashed at every container start against `/usr/share/ombra/gateway.img.sha256`; on a mismatch the container does not start and the desktop has no network. Image and hash are marked immutable |
| Gateway packages (Tor, dnsmasq, nftables) | `sudo ombra-update security --no-rollback` on the gateway, or an Ombra update | Fixed at install time. Replaced only by an Ombra update for the `single` role that carries a new image; Check Debian security updates updates the desktop's packages only |
| Tor state at rest | Unencrypted gateway disk (Persistent) | Inside the encrypted disk (`/var/lib/ombra/gateway-state/tor`, root-only parent) in Persistent mode; RAM only in Amnesic mode |
| Install network exposure | Release archives download nothing | The installer downloads Debian packages over the VM's NAT from your IP, not through Tor (see Residual risks, Single VM install) |
| Disk key | Public build passphrase until first use re-encrypts under a new key with fixed argon2id parameters | Your passphrase from the start (LUKS2, aes-xts-plain64 512-bit key, argon2id benchmarked by cryptsetup); no build passphrase, no first-use window. The install stops if you choose `ombra-disk` |
| Host-guest channels | Off in Ombra's VM settings, and the guest removes the helpers | Only the guest side: VMware drag-and-drop, clipboard and shared-folder helpers removed and kept out on reinstall; UTM's `spice-vdagent` non-executable. Your VM settings are yours |
| Host time sync | Off in Ombra's VM settings | Ombra cannot turn off VMware Tools' host time sync from inside the guest |
| Hardware clock at boot | UTC in the UTM bundles, and in Ombra's Fusion VM settings from v1.2.0 (see Initial clock) | A Fusion VM you create presents the Mac's local time: the clock starts off by the Mac's UTC offset until `ombra-timesync` corrects it, and software in the guest can see that offset early in a session |
| MAC address | Fusion: random per import; UTM: fixed in the bundle | Whatever your VM has |

Tested on real installs of the single VM edition:

| Test | Result |
|---|---|
| Gateway leak probe, inside the container | 7 of 7 pass, in Persistent and in Amnesic boots |
| Direct connection from the desktop user and from root | Refused |
| Desktop firewall flushed as root | Traffic still reaches only Tor's transparent port in the container |
| One byte of the gateway image changed | The container does not start; the desktop has no network |
| Amnesic boot | Writes to `/` and `/home` are discarded |

## Not protected

| Threat | Why |
|---|---|
| Compromised macOS host (A5) | Total compromise of the guest. The host can log keystrokes including the disk passphrase, read guest RAM and extract keys, snapshot and roll back the VM, silently change VM settings (add a NIC, re-enable clipboard or shared folders) and correlate Tor and clearnet use. Guest encryption protects data at rest only. Use dedicated hardware against this adversary |
| Hardware and physical attacks (A7) | Evil-maid on the Mac or firmware, implants, bus attacks and coercion are out of scope; no host secure-boot story |
| Tor-level adversaries (A6) | Entry and exit traffic confirmation, malicious exits seeing plaintext protocols, guard compromise and browser fingerprinting remain Tor's and the browser's problems; no fingerprinting claims |
| Kernel exploit on the single VM edition | The desktop and the gateway container share one kernel; an exploit from any desktop app can reach Tor's side and bypass it. Use the two-VM edition if this matters |
| Fusion compromise or escape | A hypervisor 0-day or trojaned Fusion defeats everything. Ombra does not pin or check the Fusion version; download it from VMware and keep it current |
| UTM or QEMU compromise or escape | Same outcome as a Fusion escape. UTM runs QEMU, a large C code base that emulates the guest's devices (virtio, NVMe, vmxnet3, e1000e, USB) in a user process, and the bundles run QEMU's own interrupt controller (`-machine kernel-irqchip=off`) instead of the hypervisor's, which adds a little more emulation. The images keep those device models for guest compatibility, so a QEMU device bug is in scope of the trust you place in UTM. Mitigations: download UTM from its project, keep it current (Ombra does not check the version), and keep host-guest channels off (the bundle config is checked for every one of them) |
| Seizure while running (A4, A7) | Keys and plaintext are in guest RAM and the host can image live state; at-rest protection applies only when the VMs are off |
| Metadata | The ISP and Apple can see that this Mac runs Fusion or UTM and Tor; Fusion, UTM and macOS telemetry are outside our control |
| User error | Pasting identifying data, reusing identities across Tor and clearnet, installing random software, backing up to a clearnet service |

## Host residue

What the Mac can keep, whatever the guest does. Amnesic mode controls only what the guest writes.

| Item | Detail |
|---|---|
| Suspend and saved state | Suspending or saving a VM's state writes its RAM to the Mac's disk, including the desktop's disk key and everything in an Amnesic session. Shut the VMs down instead |
| Mac Shared Folder transfer disk | The guest mounts it as plain FAT (`vfat`), not encrypted: whatever is copied onto it sits unencrypted in its disk file on the Mac |
| Hypervisor logs | Fusion and UTM keep their own logs and settings for each VM on the Mac |
| Host backups and snapshots | A Time Machine backup, cloud sync or hypervisor snapshot of the VM folder keeps an old copy of the encrypted disk. An old copy holds the LUKS header as it was then, so it opens with the passphrase that was valid then, even after you change it |

## Privacy applications

| Application | Note |
|---|---|
| All | Preset to the gateway SOCKS port. The desktop firewall still rejects every destination except the gateway, so an application that ignores its proxy setting fails rather than leaks |
| Wallets (Electrum, Feather) | In Amnesic mode the wallet file and seed vanish at shutdown. Write the seed down or copy it somewhere you control before shutdown. Light wallets reveal addresses to the servers they query, over Tor |
| OnionShare | The onion address is reachable by anyone who holds it. Share the address and key only over a channel you trust |
| Kleopatra | Keys live in the home directory: encrypted at rest in Persistent mode, lost in Amnesic mode unless exported. Keyserver lookups go through Tor only |
| SimpleX | The upstream arm64 desktop build is not signed. The image pins its sha256 but cannot verify an upstream signature. It reaches the network through a proxychains wrapper because the application has no SOCKS setting we can preset |
| SimpleX conditions | SimpleX shows its conditions of use on first launch and the user accepts or declines them; Ombra does not pre-accept. Amnesic mode asks again each session |
| Feather | Its bundled Tor is not used. The AppImage is pinned by sha256 and checked at build; its upstream signature was checked by the maintainer once, when the pin was made |

## Boot modes

| Mode | Gateway | Desktop |
|---|---|---|
| Amnesic | Tor state discarded at shutdown; new entry guards chosen every boot | What the guest writes, root and home included, lives in RAM and is gone at shutdown, including the browser profile and files. The Mac can still keep copies (see Host residue) |
| Persistent | Tor state and guards kept on the unencrypted disk | Writes to the encrypted disk |

Single VM edition: one boot menu for both sides. Amnesic keeps the gateway
container's Tor state in RAM (new guards every boot); Persistent keeps it in
`/var/lib/ombra/gateway-state/tor` on the encrypted disk.

| Limit | Detail |
|---|---|
| Boot menu | The GRUB menu and theme sit in the unencrypted boot area; anyone with the disk can see that Ombra is installed and which two entries exist |
| Amnesic scope | Does not defend against compromise during the session, RAM capture while running, what the Mac saves (Host residue), or what Tor and upstream networks observe |

## Residual risks accepted

| Risk | Detail |
|---|---|
| Single VM install | The installer reaches the network over the VM's NAT from your real IP, not through Tor: Debian's mirror `deb.debian.org` (package lists and packages over plain HTTP, signatures checked by apt; the gateway container's packages; an HTTPS request for the mirror's `Date` header to set the installer's clock) and the Debian installer's own NTP time step. Your network can see that this machine installed a Debian system with Ombra's package set (KDE Plasma, Tor and the rest). Package versions are whatever Debian's trixie suite serves on the day you install, so they can differ from what the maintainer tested; they are recorded in `/usr/share/ombra/packages.txt` and `/usr/share/ombra/gateway-packages.txt` |
| First-use window (two VMs) | Until first boot completes, the disk opens with the public build passphrase. A copy of the image from before first boot holds the original volume key, which protects only the empty disk. A power cut during re-encryption is recoverable but leaves the machine unusable until the Resume screen finishes the job |
| Entry guards on an Amnesic gateway | The gateway's boot menu highlights Amnesic first. In Amnesic mode Tor picks new entry guards on every boot, so over many boots the chance of picking a hostile guard grows. Persistent mode keeps the guards |
| Shared private link | The link is a host-only network shared with the Mac and any other VM attached to it; a co-resident VM can observe and reach both machines at layer 2. The gateway trusts by source address (any 10.55.10.0/24 host can use its DNS, SOCKS, TransPort and control filter), so attach no other VM to that network. The Mac itself has an address on the link (10.55.20.100 under UTM), so a guest whose root account is compromised could reach any service the Mac listens on across all interfaces: keep the macOS firewall on and file sharing off. The no-egress guarantee comes from the single NIC and the gateway firewall. Single VM edition: the link is a virtual pair inside the VM, not shared with the Mac or other VMs |
| Fixed MAC addresses under UTM | A UTM bundle carries its network cards' MAC addresses and UTM keeps them on import, so every UTM user has the same MACs on the private link. They exist only between the two VMs and the Mac; the gateway's NAT hides its MAC from the home network. Importing the same archive twice on one Mac puts two VMs with the same MACs on the link, which breaks both until one is deleted or its MAC is changed in UTM |
| No bridges or pluggable transports | The gateway's torrc has no bridge or transport lines. The local network and ISP can see that the Mac uses Tor, and Ombra does not work where Tor is blocked |
| Stream isolation | SOCKS port 9050 isolates by destination address and port, and 9150 by the browser's SOCKS credentials. Traffic through the TransPort and DNSPort has no per-destination isolation |
| Tor Browser channel | The image ships the stable channel for linux-aarch64 (pinned in `build/pins/torbrowser.txt`); v1.1.0 carried the alpha 16.0a14. Linux on ARM is a newer platform with fewer users than the x86 desktop builds, so its users are a smaller crowd, and rendering inside a VM can differ from a typical install |
| Update signing | Updates are signed with one Ed25519 key held by the maintainer. There is no threshold signing and no transparency log; whoever holds that key can sign an update |
| Prebuilt binaries | The Rust binaries in `core/dist/aarch64/` are committed to the repository and used for the release images. `core/verify-dist.sh` checks that they match the source |
| Hypervisor guest operations | Fusion: `vmtoolsd` and `vgauth` stay enabled, so `vmrun` guest operations work for anyone with a guest password; the release accounts are born locked, so they cannot authenticate. UTM: `qemu-guest-agent` answers only `guest-sync`, `guest-sync-delimited`, `guest-ping` and `guest-info` (`/etc/qemu/qemu-ga.conf`) |
| Initial clock | At boot the guest clock comes from the virtual hardware clock, which the hypervisor sets from the Mac. Ombra's Fusion VM settings present it in UTC (`rtc.diffFromUTC = "0"`, checked by the bundle verifier), and the UTM bundles keep `RTCLocalTime` off. Fusion VMs from the released v1.1.0 archives lack that setting: they boot with the Mac's local time read as UTC, off by the Mac's UTC offset (5 hours measured; Tor warned and stalled before recovering), and an update cannot change it because it is a VM setting on the Mac. A Fusion VM you create for the single VM edition behaves the same way. In each case `ombra-timesync` corrects the clock over Tor 90 s (gateway) or 2 min (desktop) after boot; until then software in the guest can see the offset, which reveals the Mac's time zone |
| Build-from-source exposure | The installer fetches Debian packages and does NTP over the host's NAT from the builder's real IP; the release archives (`.vmwarevm.zip`, `.utm.zip`) have no such step. Before contacting apt it takes the time from the `Date` header of `https://deb.debian.org/` when the installer clock is more than 60 s off; it assumes no build-host time zone |
| Host-guest channels | Two VMs: clipboard, drag-and-drop and shared folders are off in the VM configuration and the desktop removes the guest plugins; display auto-fit stays on. Single VM: only the guest side applies (see Two VMs vs single VM), and under UTM the display keeps its size when the window changes. Under UTM the clipboard setting is enforced by UTM on the Mac, not inside the guest (`spice-vdagent` has no switch to disable it), so a user who turns clipboard sharing on in UTM opens that channel. UTM's display socket has no password; it sits in UTM's own data folder, which macOS protects from other apps, so reaching it takes access to that folder |
| Application surface | Five more applications enlarge the guest's code and the image by about 1 GB; each is a separate attack surface inside the untrusted zone |
| Sound and USB | Single VM edition: whatever devices your VM has. Two VMs: the desktop VM has a virtual sound device and USB controller; microphone access follows the macOS permissions granted to Fusion. Under UTM there is no sound device; the USB controller carries only keyboard and pointer, with USB sharing off (UTM adds three idle usb-redir channels that carry nothing unless a device is attached through UTM) |
| Build pipeline | The build machine and its keys are a single point of compromise until independent verification exists. Debian packages come from the live trixie suite at build time, so builds are not reproducible |
| Clock skew | The Tor-routed time consensus narrows the skew window but is itself visible to a global adversary as periodic probe traffic |
| Unencrypted gateway disk | It holds no user data; an attacker with it learns the shipped image and, in Persistent mode, Tor's state |
| Browser and package freshness | Tor Browser's own updater is off and nothing runs apt on its own. From 1.2.1, Tor Browser, Feather, SimpleX and Electrum fixes arrive as app updates the user starts (Update Ombra): the signed app list names each version and hash, and the app is downloaded from its own project through Tor. A Debian fix arrives as an Ombra update, or when the user runs Check Debian security updates (`ombra-update security`). On the single VM edition the gateway container's packages change only with an Ombra update that replaces its image. Until then the machine runs the older code |
| Debian's Electrum | Electrum is Debian trixie's package, which is older than upstream's current release. Check upstream's security advisories against the installed version (`/usr/share/ombra/packages.txt`) before relying on it for significant funds |
| No independent audit | Ombra has not been independently audited |
