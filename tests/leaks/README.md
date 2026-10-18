# Ombra gateway leak tests

Runnable definition-of-done for gateway networking.
Each test attacks one assumption of the gateway the way an adversary would;
every test and every whitelist entry is reviewed like a firewall rule.
**If a test cannot pass, the test is not weakened; it is reported as a
finding.**

## Run

Against the live gateway (from the host Mac, with the gateway VM powered on):

```sh
tests/leaks/run-gateway-leaks.sh \
    "$HOME/Virtual Machines.localized/ombra-gateway.vmwarevm/ombra-gateway.vmx"
```

**Delivery:** vmrun guest ops against the shipped, root-owned
`/usr/local/sbin/ombra-leak-probe`. The gateway ships no sshd, no `:22`,
and no general sudo, so the probe travels inside the image and the host
drives it through its one narrow NOPASSWD sudoers grant. The orchestrator
asserts the VM is in `vmrun list`, runs the probe, copies the report
(`/run/ombra-leak/report.txt`, mode 0644 in a root-owned 0755 directory) back to the host and prints it, and exits the probe's code
(0 = 7/7, else the failing count). Nothing is downloaded and nothing is
copied in.

## Guest password and the test-only ISO

The guest account ships locked, so there is no default password, and vmrun
guest operations need one:

```sh
OMBRA_GUEST_PASS='<the password set on this build VM>' \
    tests/leaks/run-gateway-leaks.sh \
    "$HOME/Virtual Machines.localized/ombra-gateway.vmwarevm/ombra-gateway.vmx"
```

On a build VM, that password comes from a test-only gateway ISO:

```sh
OMBRA_TEST_GUEST_PASSWORD='<password>' bash build/make-install-iso.sh gateway
OMBRA_GATEWAY_ISO=build/disks/ombra-install-gateway-test.iso \
    bash build/fusion/create-gateway-vm.sh
```

- The test ISO is written to `build/disks/ombra-install-gateway-test.iso`
  and presets the guest account's password to the value given.
- It is never exported and is not a release artifact. The export script
  reads `ombra-install-gateway.iso`, not the test ISO.
- Release images are born locked, so the suite cannot authenticate against
  them. To check a release image, run the shipped probe at the gateway
  console: `sudo /usr/local/sbin/ombra-leak-probe`.

Run overrides: `OMBRA_VMX` (instead of the argument), `OMBRA_VMRUN` (vmrun
binary), `OMBRA_GUEST_USER` (default `ombra`).

Notes:

- The suite uses only what already ships in the guest (the probe itself,
  `nft`, `ss`, `curl`, `getent`, `bash`, `journalctl`, `unshare`,
  coreutils). DNS probes are raw UDP over bash's `/dev/udp`.
- No exit IP is ever printed or written: the Tor check parses
  `check.torproject.org/api/ip` in memory, validates `IsTor` and that the
  address is public, then drops the body and the address. The report
  carries pass/fail and exit codes only.
- The tests are read-only on the VM state (scratch lives under
  `/run/ombra-leak`) and safe to re-run. They never reboot or reconfigure
  the VM.

## The seven tests and what each proves

| # | Test | Attack it simulates | Pass condition |
|---|------|--------------------|----------------|
| 1 | non-tor egress fails | a compromised non-tor process (runs the probes as uid `ombra` via `su`, not root) calling home, e.g. an apt mirror or update beacon | `curl` to `check.torproject.org:443` and `deb.debian.org:80` dies with **connection refused (curl exit 7)** — the output chain's `counter reject`, not a timeout (28 would mean DROP semantics, 0 would mean the firewall is off); `tor@default` journal shows `Bootstrapped 100% (done)` |
| 2 | SOCKS reaches the real Tor network | verifying the sanctioned path actually lands on Tor, not a look-alike | `curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip` returns `IsTor:true` with a public, non-RFC1918 address; only the booleans are reported |
| 3 | non-tor DNS fails | a process trying to leak DNS to a public resolver, bypassing Tor | a raw UDP/53 query to `9.9.9.9` gets no answer (rejected by the output chain); the same query to Tor's DNSPort `127.0.0.1:5353` returns NOERROR; `getent hosts` resolves |
| 4 | live ruleset == shipped file | silent drift between the reviewed `gateway/rootfs/etc/nftables.conf` and what the kernel is actually enforcing | counter-normalized diff of two **nft-rendered** rulesets is empty (see below); plus structural asserts: NOTHING on `:22` (no ssh rule, no listener, no sshd artifacts), `meta skuid` == `debian-tor`'s uid, forward chain = `policy drop` + exactly one forwarding-prohibited **reject**, the desktop-facing intnet accepts are port-scoped (no DHCP rule on the intnet, the whole-/24 accept absent, no ruleset match for the `ombra-torctl` uid), and the stray-DNS redirect (foreign UDP/53 → dnsmasq) exists |
| 5 | no unexpected listeners | a debugging daemon or stray port left bound (every listener is attack surface from NAT or intnet) | `ss -ltnu` sockets ⊆ the probe's whitelist; unexpected sockets are printed actual-vs-expected |
| 6 | IPv6 absent | the classic dual-stack bypass (AAAA preference, v6-capable resolvers) | no global-scope v6 address; either the stack is absent (`ipv6.disable=1`, no `/proc/sys/net/ipv6`) or `disable_ipv6=1` on `all` and every interface |
| 7 | control-port filter isolation | a bug in the filter inheriting Tor's upstream egress or its raw cookie | `ombra-torctl-filter` runs as `ombra-torctl`; a curl as that uid is refused (exit 7); `/run/tor/control.authcookie` is unreadable to `ombra` |

### Why test 4 renders the file in a throwaway netns

A raw textual diff is impossible: `nft list ruleset` prints canonical token
forms (`meta skuid 101` for `"debian-tor"`, `flags ! fin,syn,rst,ack` for
`== 0x0`, `ipv6-icmp` for `icmpv6`, `code 4` for `frag-needed`) plus runtime
`counter packets N bytes M`. Hand-normalizing those would mean
re-implementing nft's printer — easy to get subtly wrong. Instead the
shipped file is loaded with `nft -f` inside `unshare -n` (a throwaway
network namespace, isolated from the real ruleset), listed with nft's own
parser+printer, and diffed against the live listing after stripping
counters on both sides. That is a true semantic comparison performed by
nft itself.

## Whitelisted listeners (deliberate, with reasons)

- the gateway's own `udp` client socket on the upstream NIC
  (`%ombra-upstream:68`) — systemd-networkd DHCP on the upstream side.
- dnsmasq `10.55.10.1:53` (tcp/udp), Tor `10.55.10.1:9050`/`:9040`,
  the filter `10.55.10.1:9052`, and loopback `9050`/`9051`/`5353`.
- `getent hosts` may return an AAAA through Tor (glibc asks v6 first).
  That is a Tor-DNS answer, not a v6 leak; no v6 route exists (test 6).

## Canonical probe

`gateway/rootfs/usr/local/sbin/ombra-leak-probe` is the only copy of the
seven tests; it ships root-owned in the image. POSIX sh (dash) plus bash
for the UDP probes, timeout-bounded.

## Files

- `run-gateway-leaks.sh` — host-side orchestrator: vmrun guest-ops delivery
  (running-state assert, stale-report pre-clean, sudo'd probe run, report
  copy-out and print, best-effort guest cleanup, result banner); exits the
  probe's code, FATAL = 125. Usage: `run-gateway-leaks.sh <gateway.vmx>`.
