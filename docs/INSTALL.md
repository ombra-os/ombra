# Installing Ombra

Ombra is two virtual machines: a gateway (Tor) and a desktop, separated by
the hypervisor. A kernel exploit in the desktop stays in the desktop VM
unless it also escapes the hypervisor.

Paths: open the prebuilt archives (Quick start sections), run the guided
build (next section), or build by hand (steps 1-7). A final section covers
exporting the release files, for maintainers. Once installed, Ombra updates
itself in place when you ask; see [UPDATES.md](UPDATES.md).

## Guided build

```sh
curl -fsSL https://ombra-os.org/build.sh | bash
```

The script is [`scripts/build.sh`](../scripts/build.sh). It checks the Mac,
installs missing tools with Homebrew after asking, verifies the pinned
downloads, builds, and creates and installs both VMs. `--isos-only` stops
after the installer ISOs; `--yes` answers every prompt.

## Quick start: requirements

- Apple Silicon Mac with VMware Fusion, or with UTM 5.0.8 or newer
- About 45 GB of free disk. The downloads are about 6.8 GB (desktop) and
  0.9 GB (gateway), and you need room for the archive and the unzipped
  copy until you delete the archive. The provisioned virtual disks are
  5 GB (gateway) and 30 GB (desktop). First-use setup re-encrypts the
  whole desktop disk, so it grows to its full 30 GB then. If the Mac runs
  out of space, Fusion stops the VM with a "no space left" prompt: free
  space and choose Retry.

## Quick start: the release images

1. Download `ombra-gateway-arm64-v1.2.2.vmwarevm.zip`,
   `ombra-desktop-arm64-v1.2.2.vmwarevm.zip` and `SHA256SUMS.txt` from the
   download page into one folder, and verify what you downloaded:

   ```sh
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```

   Every file you did download must report `OK`. This proves the
   download is complete and undamaged; to prove `SHA256SUMS.txt` comes
   from Ombra, also check its signature ([Verify the signature](#verify-the-signature)).
2. Double-click each zip to unpack it, and move the two `.vmwarevm`
   folders into `~/Virtual Machines.localized/`.
   Then double-click each `.vmwarevm` to open it in Fusion. If Fusion asks
   whether you moved or copied it, choose **I Moved It**. Nothing needs
   changing in the VM settings.
3. Power on the gateway first and pick a boot mode (below), let it reach
   its connectivity panel on the console, then power on the desktop, pick a boot mode, and
   continue with First boot below.


### Boot modes

Both VMs start at an Ombra boot menu with two entries and wait for your
choice; nothing starts on its own.

- **Amnesic** — the system runs from RAM on top of the read-only image.
  Everything written since power-on, including Tor state and your
  files, is gone at shutdown. The gateway highlights this first.
- **Persistent** — the disk is written normally. The desktop
  highlights this first, and first-time setup runs only in this mode.

Pick **Persistent** for the desktop's first boot. You can restart into
either mode at any time.

## Verify the signature

`SHA256SUMS.txt.sig` is an Ed25519 signature of
`SHA256SUMS.txt`, made with the key that signs Ombra updates. Take the
public key from this repository on GitHub, not from the download host, so
that one compromised host cannot swap the images, the hashes and the key
together.

| Step | Command | Expected |
|---|---|---|
| Signature | `curl -fLO https://dl.ombra-os.org/SHA256SUMS.txt.sig` | |
| Public key | `curl -fLo update-pubkey.pem https://raw.githubusercontent.com/ombra-os/ombra/main/build/update-pubkey.pem` | |
| Key fingerprint | `shasum -a 256 update-pubkey.pem` | `194b5338cf4000a2d34785c152e07fc2513912828f74380e0904f22d16e7a3fe` (also shown on [ombra-os.org/install](https://ombra-os.org/install)) |
| Signature check | `"$(brew --prefix openssl@3)/bin/openssl" pkeyutl -verify -pubin -inkey update-pubkey.pem -rawin -in SHA256SUMS.txt -sigfile SHA256SUMS.txt.sig` | `Signature Verified Successfully` |
| Hashes | `shasum -a 256 -c SHA256SUMS.txt --ignore-missing` | `OK` for every file you downloaded |

Needs OpenSSL 3 (`brew install openssl@3`): the `/usr/bin/openssl` that
ships with macOS cannot read Ed25519 keys. In a clone of this repository,
`bash scripts/update/verify-sums.sh build/update-pubkey.pem SHA256SUMS.txt`
does the signature and hash checks in one step.

## Quick start: UTM

The same two machines run under UTM instead of VMware Fusion. Pick one
hypervisor and use its archives; do not mix them.

| Step | Detail |
|---|---|
| Host | Apple Silicon Mac, UTM 5.0.8 or newer (QEMU backend; Ombra does not use the Apple Virtualization backend) |
| Download | `ombra-gateway-arm64-v1.2.2.utm.zip`, `ombra-desktop-arm64-v1.2.2.utm.zip` and `SHA256SUMS.txt`; verify with `shasum -a 256 -c SHA256SUMS.txt --ignore-missing`. Check the signature too ([Verify the signature](#verify-the-signature)) |
| Unpack | Double-click each zip in Finder, or run `ditto -x -k <zip> .` in a terminal |
| Import | Double-click each `.utm` to add it to UTM. Nothing needs changing in the VM settings |
| Start | Gateway first: pick a boot mode, wait for its connectivity panel. Then the desktop: pick **Persistent** for the first boot. First boot is identical to Fusion (see below) |

What differs from Fusion:

| Topic | UTM |
|---|---|
| Display | The desktop follows the UTM window size. Leave Retina mode off. The display card is `virtio-gpu-pci` without GL acceleration; the GL-accelerated cards hand the guest access to the Mac's graphics stack |
| Private link | Both VMs sit on UTM's host-only network (10.55.20.0/24); the guests use static 10.55.10.x addresses on top of it, so the Mac has no address on their subnet. The gateway's upstream is UTM's Shared Network (NAT) |
| Restart | A restart from inside the guest hangs on UTM 5.0.8 unless QEMU runs the interrupt controller itself, so the bundles carry the argument `-machine kernel-irqchip=off`. Do not remove it. It costs about 15% of one Mac core while the VM is idle |
| Window size | The desktop follows the UTM window when you resize it. To make that reliable, the desktop turns KWin's compositor off when it runs under QEMU (UTM), so there are no window shadows, translucency or animations there. VMware Fusion keeps them |
| Host channels | Clipboard sharing, shared folders, USB sharing and serial ports are off in the shipped configuration. Leave them off: turning clipboard sharing on lets the Mac read and write the guest clipboard |
| Guest tools | `qemu-guest-agent` answers only ping, sync and info; `spice-vdagent` drives window-size changes. The VMware tools stay installed and idle |
| Updates | The in-place updater works the same way; it needs Persistent mode |

## Requirements (building from source)

- Apple Silicon Mac, macOS
- VMware Fusion
- About 50 GB free disk (gateway 5 GB + desktop 30 GB, plus the ISOs
  and build outputs)
- Rust via `rustup` (`core/build.sh` runs `rustup target add`; the
  toolchain version is pinned in `core/rust-toolchain.toml`)
- `xorriso` (`brew install xorriso`), `python3`

Tor Browser ships from the stable channel (16.0.3, linux-aarch64).

## 1. Fetch the pinned Debian netinst

The exact ISO is pinned in `build/pins/debian-netinst-arm64.txt` —
read it for the filename, size and sha256, and download it from the
source listed there into `build/isos/`:

```sh
mkdir -p build/isos
curl -L -o build/isos/debian-13.8.0-arm64-netinst.iso \
  https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.8.0-arm64-netinst.iso
bash build/verify-iso.sh
```

If the `current` path no longer carries the pinned file (a newer Debian
point release superseded it), fetch it from the archive instead:
`https://cdimage.debian.org/cdimage/archive/13.8.0/arm64/iso-cd/`.

`verify-iso.sh` checks size and sha256 against the pin; it fails loud
on any mismatch. Do not build from an unverified ISO.

## 2. Build the Rust binaries

```sh
cd core
bash build.sh
```

This cross-compiles aarch64 musl-static binaries into
`core/dist/aarch64/`. Copy them into the desktop overlay (the ISO
build refuses to run if the overlay binaries drift from `dist/`; the
gateway gets the `ombra` panel too):

```sh
cp dist/aarch64/ombra-askpass dist/aarch64/ombra-welcome \
   ../desktop/rootfs/usr/local/libexec/ombra/
cp dist/aarch64/ombra dist/aarch64/ombra-statusd dist/aarch64/ombra-tproxy \
   ../desktop/rootfs/usr/local/bin/
cp dist/aarch64/ombra dist/aarch64/ombra-torctl-filter \
   ../gateway/rootfs/usr/local/bin/
cd ..
```

## 3. Stage the pinned downloads (desktop ISO)

The desktop ISO carries four sha256-pinned files: Tor Browser
(stable channel, `build/pins/torbrowser.txt`), Electrum
(`build/pins/electrum.txt`), Feather (`build/pins/feather.txt`) and
SimpleX (`build/pins/simplex.txt`). Each
is verified again inside the installer. Fetch the exact `file=` named in
each pin from its `url=` and place it in `build/vendor/` (the directory
is gitignored). Superseded builds move away, so use the pin's
`archive_url` if `url` no longer has the file:

```sh
mkdir -p build/vendor
curl -L -o build/vendor/tor-browser-linux-aarch64-16.0.3.tar.xz \
  https://dist.torproject.org/torbrowser/16.0.3/tor-browser-linux-aarch64-16.0.3.tar.xz
curl -L -o build/vendor/Electrum-4.8.4.tar.gz \
  https://download.electrum.org/4.8.4/Electrum-4.8.4.tar.gz
curl -L -o build/vendor/feather-2.9.1-arm64.AppImage \
  https://github.com/feather-wallet/feather/releases/download/2.9.1/feather-2.9.1-arm64.AppImage
curl -L -o build/vendor/simplex-desktop-ubuntu-24_04-aarch64.deb \
  https://github.com/simplex-chat/simplex-chat/releases/download/v7.1.4/simplex-desktop-ubuntu-24_04-aarch64.deb
shasum -a 256 build/vendor/*
```

Each hash must equal its pin's `sha256=` line; `make-install-iso.sh`
re-checks them before staging.

## 4. Build the installer ISOs

```sh
bash build/make-install-iso.sh gateway
bash build/make-install-iso.sh desktop
```

Output: `build/disks/ombra-install-gateway.iso` and
`build/disks/ombra-install-desktop.iso`. Each ISO is self-contained:
preseed, overlay and pinned payload travel inside the netinst initrd.

## 5. Create the VMs

VMware Fusion must be installed; nothing else is needed on the host.
Disconnect any VPN that intercepts DNS before installing; if installs
cannot resolve Debian mirrors, restart Fusion's network daemons
(`vmnet-cli --stop` / `--start`) and retry.

Install the gateway first, and leave it running: the desktop's real
network (DNS, Tor) runs through it.

```sh
bash build/fusion/create-gateway-vm.sh
```

The script instantiates the VM from the template (pinned MACs,
NVMe, no shared folders, clipboard/drag-and-drop/HGFS isolation keys),
attaches the installer ISO and starts it. The install is unattended,
~5-15 minutes, and the VM powers itself off when done.

Then finish the gateway on the host side:

```sh
bash build/fusion/post-install-gateway.sh              # connect NIC2, detach CD, disk-first, start
bash build/fusion/post-install-gateway.sh --no-start   # same, leave it powered off
```

Same shape for the desktop, once the gateway is up:

```sh
bash build/fusion/create-desktop-vm.sh
# after the installer powers the VM off:
bash build/fusion/post-install-desktop.sh              # NIC to "Private to my Mac", detach CD, disk-first, start
```

Both post-install scripts accept an explicit vmx path, are idempotent,
strip install-time debug keys, and refuse to run while the VM is
powered on.

To audit an existing VM against the pinned shape (add `--fix` to
repair what is fixable; the vmx is located by its display name, or pass
its path):

```sh
bash build/fusion/create-gateway-vm.sh --verify --fix
bash build/fusion/create-desktop-vm.sh --verify --fix "$HOME/Virtual Machines.localized/ombra-desktop.vmwarevm/ombra-desktop.vmx"
```

## 6. The install

- The gateway install is fully unattended; ~5-15 minutes.
- The desktop install is fully unattended; ~10-25 minutes, varying with
  the network; the package transaction is not time-limited.
- The installer powers the VM off when done. A failed desktop install
  parks on a visible console with the reason instead of shipping a
  half-landed machine; do not power off or export a VM that parked.
  The gateway has no park: an unexpectedly early poweroff means a
  failed install.
- After each poweroff, run that VM's `post-install-*.sh` (step 5).

## 7. First boot

- The desktop's disk unlock accepts the public build passphrase
  `ombra-disk`. This is intentional: it is a published build value, and
  it only ever unlocks a machine that has not yet been set up.
- The first-use screen then owns the console: choose the real disk
  passphrase and the user password. It adds your passphrase, then
  re-encrypts the disk online under a new volume key, which retires the
  build passphrase. Only once the disk is sealed (re-encryption
  finished, build passphrase dead, yours opens) does it release the
  machine to the login screen.
- The disk is re-encrypted with a new key on first use. This takes a
  few minutes on the 30 GB disk. Do not power off or restart during it. If it is interrupted, the next boot shows a Resume screen
  asking for your passphrase and finishes the job; the machine is not
  usable until then.
- The machine restarts when it is done; from then on, unlock with
  **your** passphrase. The gateway has no user-facing setup — it comes
  up as a Tor router and shows its connectivity panel on its console
  (`sudo ombra-systemcheck` prints the full health report). Both
  machines' accounts are born locked: there is no default login
  password on either.
- Choose Persistent at the boot menu for first boot. In Amnesic mode the
  first-use screen only asks you to restart in Persistent mode.
- Tor Browser's circuit display is unavailable by design: the control
  port is filtered to a small status dialect plus OnionShare's onion
  services (see [THREAT_MODEL.md](THREAT_MODEL.md#tor-control-port)). New Identity still resets
  the browser and its circuits.

## Updates

- Ombra updates itself in place, only when you ask. About 3 minutes after
  boot and then daily, each machine checks a small signed index through Tor
  and tells you when a newer version exists. Details: [UPDATES.md](UPDATES.md).
- Desktop: open **Update Ombra** from the menu. Gateway: `sudo ombra-update apply`
  at its console. Updates need Persistent mode.
- Tor Browser's own updater is disabled; new Tor Browser builds arrive as
  app updates (**Update Ombra** → **Update apps**), from a signed app list,
  checked before anything is written.
- Debian's security updates install only when you ask: **Update Ombra** →
  **Check Debian security updates** on the desktop, `sudo ombra-update
  security --no-rollback` on the gateway (it cannot be undone there).
- A rollback on the desktop restores the root volume from the snapshot
  taken before the update. Your home folder is on its own volume and is
  not affected.
- Only the latest release is supported; earlier releases get no fixes.
- From v1.2.0 or v1.2.1: both machines update in place to v1.2.2. Desktop: **Update
  Ombra**; your files stay where they are. Gateway: `sudo ombra-update
  apply` at its console, in Persistent mode.
- The gateway's Amnesic mode starts every boot from the installed system,
  so it never carries an update itself: apply updates in Persistent mode.

## Export the release images (maintainers)

Start from freshly installed VMs, both powered off, both post-installed.
The desktop must never have been booted.

```sh
bash build/fusion/export-bundle.sh gateway
bash build/fusion/export-bundle.sh desktop
```

The export strips builder residue from a copy of the VM bundle, asserts
the shipped shape (ARM guest type, NICs, boot order, isolation keys),
zips it, runs `verify-bundle.sh` on the archive and writes one
`SHA256SUMS.txt` with a line per archive present; downloaders filter it
with `--ignore-missing`. Output lands in `build/releases/`. There is no OVA
export: OVF cannot express an ARM guest type.

## Export the UTM images (maintainers)

A UTM archive is made from a freshly installed Fusion-built VM: the same disk,
converted to qcow2, in a different hypervisor wrapper. Both VMs must be powered off and post-installed,
and the desktop must never have been booted.
Needs `qemu-img` (`brew install qemu`) and UTM.app.

```sh
bash build/utm/export-bundle.sh gateway
bash build/utm/export-bundle.sh desktop
```

The script converts the disk to qcow2, writes `config.plist` with every
host-guest channel off, zips the bundle and runs `build/utm/verify-bundle.sh`
on the archive.
