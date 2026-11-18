# Gateway container overlay (single edition)

The single edition runs the gateway inside the desktop VM as a
`systemd-nspawn` container booted from a read-only ext4 image
(`/var/lib/ombra/gateway.img`). `desktop/late-command.sh` builds that
image at install time: a minbase trixie tree from `mmdebstrap`, then
`gateway/rootfs` (packed exactly as for the gateway VM), then this
overlay. Only `etc/` is packed; this README is not.

## Files

| File | What it does |
|------|--------------|
| `etc/systemd/network/10-upstream.network` | DHCP on `ombra-upstream`, the VM's NIC moved into the container; ignores the lease's DNS and NTP; no IPv6 RA or link-local |
| `etc/systemd/network/20-intnet.network` | Static 10.55.10.1/24 on `ombra-intnet`, the container end of the veth pair; `ConfigureWithoutCarrier=yes` so the address is up before the desktop end is |

They match by interface name, not by driver: nspawn names both
interfaces itself, and a veth has no NIC driver to match. The format
constraint in `gateway/rootfs/etc/systemd/network/README.md` applies:
no comments, ASCII only.

## What the container variant removes or changes

| Removed or changed | Why |
|--------------------|-----|
| `boot/`, `etc/default/grub.d`, `etc/grub.d`, `etc/overlayroot.conf` | No boot loader or initramfs: the desktop's kernel boots the container; nspawn's `--volatile=overlay` replaces overlayroot |
| `etc/qemu` | No hypervisor channel inside the container |
| The driver-matched `.link` and `.network` files | Replaced by the two files above |
| `getty@tty1` autologin drop-in; `getty@tty1`, `console-getty`, `systemd-logind` masked | No console: the container is reached with `machinectl` or `systemd-run -M ombra-gateway` from the desktop |
| `ombra-timesync`, `ombra-firstboot` masked | The desktop owns the clock (one kernel clock); first boot has nothing to finish |
| `ombra-update` and its units, sudoers grant and config removed; timers masked | The image is read-only; the desktop's updater owns updates |
| `systemd-remount-fs` masked | The image root is read-only by design; the stock unit fails on it |
| `systemd-networkd-wait-online`, apt, `e2scrub_all` and `fstrim` timers masked | Nothing waits for the network, nothing runs apt, the image has no writable filesystem to scrub or trim |
| Users `ombra` (uid 1000, no login shell) and `ombra-torctl` created | The sudoers grants name `ombra`; the control-port filter runs as `ombra-torctl`. With no-new-privileges (below) `sudo` does not work inside the container; nothing there calls it |
| Fixed hostname `ombra-gateway` and machine-id `...0002` | Same identity as the gateway VM |

## How the desktop runs it

`desktop/single/usr/local/sbin/ombra-gateway-run`, started by
`ombra-gateway.service`:

| Setting | Value |
|---|---|
| Integrity | `/var/lib/ombra/gateway.img` must hash to `/usr/share/ombra/gateway.img.sha256` at every start, or the container stays down and the desktop has no network. Both files are immutable (`chattr +i`) |
| Root filesystem | The image, read-only; writes go to a RAM overlay (`--volatile=overlay`) and are gone when the container stops |
| Users | Own user namespace (`-U`) |
| Privileges | `--no-new-privileges=yes`; capabilities dropped: `CAP_SYS_PTRACE`, `CAP_SYS_BOOT`, `CAP_AUDIT_CONTROL`, `CAP_AUDIT_WRITE`, `CAP_MKNOD`, `CAP_SYS_TTY_CONFIG`, `CAP_LINUX_IMMUTABLE`, `CAP_IPC_OWNER` (on top of those nspawn never grants) |
| Limits | `MemoryMax=768M`, `TasksMax=512` |
| Network | `--private-network`; the VM's NIC `ombra-nic` moves in as `ombra-upstream`; veth `ombra-gw` (desktop) to `ombra-intnet` (container) |
| Tor state | Persistent boots: `/var/lib/ombra/gateway-state/tor` bound to `/var/lib/tor` (idmapped; root-only parent on the desktop). Amnesic boots: no bind, so Tor's state stays in the RAM overlay |
| Updates | The image changes only through `ombra-update apply` with a signed `single` bundle that carries a new image and its hash; the new image is used after the restart |
| Reaching it | `machinectl` or `systemd-run -M ombra-gateway`, as root on the desktop |

Tested on VMware Fusion: the gateway leak probe passes 7 of 7 inside the
container in Persistent and Amnesic boots, and a changed byte in the image
keeps the container down. Not tested on UTM.
