# Tor hardening

How Ombra defends against a remote-code-execution bug in the Tor daemon on
the gateway: what each measure is, how it is checked, and what it does not
cover. The short version is in the
[threat model](THREAT_MODEL.md#tor-daemon-compromise-what-ombra-does).

## The threat

Tor is a large C program. It parses data from the desktop (SOCKS requests,
control commands) and from the network (cells, directory documents, onion
service descriptors). A memory-safety bug in any of these can give an attacker
code execution inside the Tor process on the gateway.

An example Ombra defends against by design:

| Item | Detail |
|---|---|
| Bug | TROVE-2026-036: use-after-free in Tor's `addressmap_register_virtual_address()` when the automap address pool is exhausted |
| Fixed in | Tor 0.4.9.12 |
| Preconditions | `AutomapHostsOnResolve 1`, and a client able to send Tor many resolve requests |
| Outcome | Code execution in Tor, then a direct connection from the gateway to the attacker, revealing the user's public address |

Ombra's gateway has no automap, so that code cannot be reached from the
desktop on any Tor version. The measures below are not tied to one bug: they
reduce what the desktop can reach in Tor, limit what code running inside Tor
can do, stop Tor after repeated crashes, and report when Debian has a newer Tor.

## What confinement cannot prevent

| Fact | Source |
|---|---|
| Every relay tells a connecting client the address it sees the client coming from, in the NETINFO cell | Tor `src/core/or/connection_or.c` (`netinfo_cell_set_other_addr`); tor-spec, NETINFO cells |
| Directory answers may carry it again, in the `X-Your-Address-Is` header | Tor `src/feature/dircache/dircache.c`; dir-spec |
| A NAT in front of the gateway does not change this | The guard sees the public address |
| Sending it out needs nothing unusual | A Tor client can open a circuit to any server |

Code running inside Tor can therefore learn the Mac's public address and send
it anywhere using only what Tor does in normal operation. No system-call
filter, AppArmor profile or firewall rule can tell that apart from normal use.
Only a network layer under the gateway, so that the guard sees a different
address, would prevent it. Ombra does not include one.

## 1. Reach: the desktop's ways into Tor

| Measure | File | Effect |
|---|---|---|
| No automap (`AutomapHostsOnResolve`, `VirtualAddrNetworkIPv4` unset) | `gateway/rootfs/etc/tor/torrc` | The address-map code is not reachable from a resolve request. Its other caller, the control command `MAPADDRESS`, is refused by the control-port filter |
| No DNSPort | `torrc` | No DNS packet reaches Tor |
| No TransPort, and no firewall redirect into Tor | `torrc`, `gateway/rootfs/etc/nftables.conf` | Desktop TCP to any address other than the gateway's SOCKS and filter ports is rejected |
| dnsmasq answers locally and forwards nothing | `gateway/rootfs/etc/dnsmasq.d/ombra.conf` | Every name gets "no such name" at once. A query flood ends at dnsmasq |
| `SocksPolicy` limited to the private link and loopback | `torrc` | Restates what the firewall enforces |

| Question | Answer |
|---|---|
| Do shipped applications depend on DNS or the transparent port? | No. Tor Browser, SimpleX (proxychains with remote DNS), Electrum, Feather, OnionShare, Kleopatra's keyserver access, `apt` and `curl` hand hostnames to SOCKS. Programs with no proxy settings go through `ombra-tproxy` on the desktop (next section) |
| Why does `.onion` get a DNS answer? | dnsmasq returns the fixed placeholder 10.66.0.1 for onion names, which the status probe of earlier 1.2 desktops expects. Nothing routes to it |
| What can the desktop still reach in Tor? | The SOCKS parser on 9050 and 9150 (resolve commands included; with automap off they map nothing), and the control-port filter's allowlist |
| What is not reduced? | What Tor reads from the network: onion service descriptors, cells from a hostile exit or relay, directory documents. A web page can make Tor fetch an attacker's onion service. That surface is the same for every Tor user |

## 2. Programs that know nothing about proxies

Programs with no proxy settings (`ssh host`, `dig`, a script) reach the
network through `ombra-tproxy` on the desktop. It hands every connection to
the gateway as a SOCKS `CONNECT`, so the gateway's Tor sees nothing new.

| Piece | Where | What it does |
|---|---|---|
| Name stub | `ombra-tproxy` (`core/src/tproxy.rs`), UDP on loopback | Answers every DNS question for a hostname with a placeholder address from 10.64.0.0/10 and remembers which name it stands for. Other record types get an empty answer. A single-label, malformed, local-only (`.local`, `.lan`, `.internal`, `.home.arpa` and similar) or reverse-lookup name gets "no such name" |
| Redirects | `desktop/rootfs/etc/nftables.conf`, `table ip nat` | UDP port 53 to the stub; every TCP connection not addressed to the gateway or to loopback to the proxy's TCP port |
| Hand-off | `ombra-tproxy`, TCP on loopback | Reads the address the program dialled (`SO_ORIGINAL_DST`), finds the name, and opens `CONNECT name:port` on the gateway's SOCKS port 9050. A literal address is passed on as an address |

| Property | Detail |
|---|---|
| What Tor sees | SOCKS `CONNECT` only |
| A bug in `ombra-tproxy` | Cannot reveal the address: the desktop has no route except the gateway's SOCKS port, and the service runs as an unprivileged dynamic user allowed to reach only loopback and the private link |
| Its ports | Held by systemd (`ombra-tproxy.socket`) from boot to shutdown. While the service is stopped, restarting or being updated, no other program can bind them; redirected traffic waits in the queue and goes nowhere |
| Stream isolation | Port 9050 isolates by destination address and port. Two programs that reach the same host and port share a circuit, as two programs using port 9050 without credentials do |
| Not covered | UDP other than DNS (`ping`, QUIC), and DNS record types other than A. `curl` refuses `.onion` names unless it has a proxy; the desktop's `ALL_PROXY` gives it one |
| Privacy | A program not configured for Tor goes online through Tor without asking. The network sees Tor either way, but such a program can identify its user by what it sends |

The name table is shared by every program on the desktop. One program must
not be able to change where another program's placeholder leads, nor learn
what others looked up.

| Rule | How |
|---|---|
| A placeholder never changes meaning while in use | A name used in the last five minutes is never dropped. A dropped name's address then stands for nothing: a connection to it is refused. It is given to another name only an hour after it was dropped, and only once every address in the pool has been used |
| Nobody can aim at a placeholder | Addresses are picked at random among those not used since the proxy started |
| A flood is refused, not absorbed | At most 100,000 names (8 MB) are remembered. When that is full, names idle for five minutes make room; if none is idle, a new name gets "server failure". Names in use keep working |
| A flood is slow | The firewall drops name lookups beyond 2,000 a second per user and refuses more than 512 redirected connections per user |
| Nobody can list the table | Reverse lookups are never answered |
| A stale placeholder leads nowhere | A connection to a placeholder that stands for no name is refused |

## 3. Confinement: what injected code can do

Debian's `tor@default.service` sets `NoNewPrivileges`, `PrivateTmp`,
`PrivateDevices`, a read-only file tree and four capabilities. Ombra adds
`tor@default.service.d/20-ombra-hardening.conf`:

| Directive | Effect |
|---|---|
| `SystemCallFilter=@system-service`, `SystemCallArchitectures=native` | A call outside the set kills Tor with SIGSYS |
| `MemoryDenyWriteExecute=yes` | No memory that is both writable and executable |
| `RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK` | No raw or packet sockets |
| `RestrictNamespaces`, `RestrictSUIDSGID`, `RestrictRealtime`, `LockPersonality` | Fewer kernel features to attack |
| `ProtectKernelModules`, `ProtectKernelTunables`, `ProtectKernelLogs`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname` | Kernel surface closed |
| `IPAddressDeny=` private, link-local, carrier-NAT, multicast and reserved ranges; `IPAddressAllow=10.55.10.0/24` | An address filter that follows the process (cgroup), next to the firewall rule |

| Also | Detail |
|---|---|
| AppArmor required (`30-ombra-apparmor.conf`) | Debian's unit names the profile as optional (`AppArmorProfile=-system_tor`), so Tor would start unconfined without it. Ombra installs AppArmor and requires the profile: without it, Tor does not start. The profile allows no shell and no program except pluggable transports (none ship) |
| `NoExec 1` in torrc | Tor refuses to start programs |
| Firewall, Tor uid | TCP only, and never to 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 or 224.0.0.0/3. Tor cannot ask the home router for the public address (UPnP, NAT-PMP), reach services on the Mac or scan the local network |
| Status-event scrubbing | Tor reports its internal errors as status events with `REASON="<log text>"`, which can name the entry guard or carry a backtrace with the addresses the process is loaded at. The control-port filter drops every status line Tor marks as `BUG` and checks every status value against the shape that field has in Tor's ordinary events (a number, one word, or a short phrase without digits) |

## 4. Tripwire: a failed attempt is seen

| Event | What happens |
|---|---|
| Tor dies by a signal (crash, out of memory, watchdog) | `ombra-tor-tripwire record` adds one to `/run/ombra/tor-crashes`. Tor is restarted once. The desktop shows: "Tor stopped unexpectedly and was restarted" |
| Second such death in the same boot | Tor stays down. The desktop has no network and shows "Tor is stopped", with advice to close what is open, check for updates and restart the gateway |
| Tor is killed by its system-call filter (SIGSYS) | No restart. The same notice, stating that Tor was stopped by Ombra's protections |
| Gateway restarted | The counters are in `/run` and start again at zero |

| Point | Detail |
|---|---|
| Wording of the first notice | It does not say "attack": a crash from a plain bug and one from a failed exploit look the same |
| No all-clear | The notice never says the user is safe: a successful exploit can reveal the address before Tor crashes |
| How the desktop learns it | The control-port filter answers `GETINFO ombra/gateway-state` from the gateway's state files (`crashes:N,killed:B,update:B`, rebuilt from parsed values, never file bytes). When Tor is down, the same values ride on the filter's refusal line. `ombra-gateway-notify` on the desktop asks once a minute |
| Cost | A manual gateway restart after a second crash. Restarting an Amnesic gateway picks new entry guards, so someone able to crash Tor twice per boot can force guard changes; Persistent mode keeps the guards |

## 5. Freshness: Tor is not left out of date

| Item | Detail |
|---|---|
| Check | `ombra-tor-freshness`, 3 minutes after every boot and then daily |
| How | Fetches Debian's signed `trixie-security` package list through the gateway's own Tor and compares the `tor` version with the installed one. Uses its own source list and a list directory under `/run`; the system's apt state is not read or written, so it works in Amnesic mode |
| Result | `/run/ombra/tor-update` holds `current` or `available`. `ombra-systemcheck` prints it; the desktop shows "A newer Tor is available for the gateway" at once and every six hours until it is installed |
| Installing | `sudo ombra-update security --no-rollback` at the gateway console, in Persistent mode |
| It installs nothing itself | Nothing on Ombra runs apt on its own |

## Coverage of the TROVE-2026-036 attack

| Step | Met by |
|---|---|
| Flood the automap pool | No automap; DNS never reaches Tor |
| Place a reverse-lookup entry on the freed object | The object is never created |
| Read memory, replace a callback | Not reached. For a different bug: the confinement, and two attempts per boot |
| Direct connection to the attacker | Not blocked for public addresses: Tor must reach relays anywhere. Local addresses are blocked |
| Variant: read the address from NETINFO, send it through Tor | Not blocked. See Limits |

## Limits

| Limit | Detail |
|---|---|
| A successful exploit can still reveal the address | See What confinement cannot prevent |
| Network-side bugs | Reach is unchanged for bugs in what Tor parses from relays, exits and onion services |
| Desktop SOCKS | Tor's SOCKS parser is directly reachable from the desktop |
| Compile-time hardening | Debian's package as built (PIE, stack protector, `-mbranch-protection=standard`). Tor's own `Sandbox 1` is not compiled into Debian's arm64 package |

## How it is checked

| Check | Where |
|---|---|
| Tor runs with no automap, DNSPort or TransPort; Tor maps no onion name to an address | Leak probe test 8 (`gateway/rootfs/usr/local/sbin/ombra-leak-probe`) |
| As the Tor uid: UDP refused; router, private, link-local and carrier-NAT addresses refused; system-call filter, no-new-privileges and AppArmor label on the running Tor; tripwire wired into the unit | Leak probe test 9 |
| No DNS path: public resolver refused, no DNSPort, `getent` resolves nothing, Tor resolves over SOCKS | Leak probe test 3 |
| No listener on 9040 or 5353 | Leak probe test 5, `ombra-systemcheck` |
| Name table rules (random addresses, no re-pointing, refusal when full, no reverse lookups), DNS answers, malformed packets, SOCKS framing, relay teardown | `core/src/tproxy.rs` and `core/src/bin/ombra-tproxy.rs` tests |
| Status-event scrubbing (a backtrace line and a guard fingerprint are dropped), gateway state parsing, the filter's answer | `core/src/torctl.rs` tests |
| Confinement, crash count and Tor version at a glance | `sudo ombra-systemcheck` |
