# Gateway network configuration

Interface names, addressing and the file-format constraint for the
gateway's `systemd-networkd` and `systemd-udevd` configuration.

## Files

| File | What it does |
|------|--------------|
| `05-upstream.link` | Renames the NIC bound to the `vmxnet3` driver (ethernet0 in the build template) to `ombra-upstream` |
| `06-intnet.link` | Renames the NIC bound to the `e1000e` driver (ethernet1 in the build template) to `ombra-intnet`, the private link to the desktop |
| `10-nat.network` | DHCP on the upstream NIC, matched by driver; ignores the lease's DNS and NTP; no IPv6 RA or link-local |
| `20-intnet.network` | Static 10.55.10.1/24 on the private link, present before any client asks; no IPv6 RA or link-local |

The firewall keys on the fixed interface names, so the renames must not
depend on hypervisor-assigned PCI slot order or on MAC addresses (imports
assign random MACs). Identity is the emulated NIC model: the two NICs
must be different models, vmxnet3 upstream and e1000e on the private link. The `.link` files sort
before the distribution's `99-default.link`, so their names win.

## Format constraint

Keep the `.link` and `.network` files minimal. On Debian trixie
(systemd 257) under VMware Fusion, versions of these files carrying `#`
comment blocks, some with multi-byte UTF-8 such as em-dashes, made
`systemd-udevd` fail at boot with "could not create link config file ...
Invalid argument". The NICs were then never renamed and
`systemd-networkd` failed with them.

- The same directives without comments parsed and applied cleanly.
- Warm udevd restarts sometimes parsed the commented files, but cold-boot
  coldplug failed reliably.
- The specific bytes that break the parse were not isolated.

Do not add comment blocks or non-ASCII characters here without a
cold-boot test on a fresh install.
