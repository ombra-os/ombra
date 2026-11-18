# Installing Ombra

## Editions

| Edition | What you get | Who it is for | How it ships |
|---|---|---|---|
| Two VMs | A gateway VM (Tor) and a desktop VM, separated by the hypervisor | Stronger isolation: a kernel exploit in the desktop stays in the desktop VM unless it also escapes the hypervisor | Prebuilt VM archives for Fusion and UTM (Quick start sections below) |
| Single VM | One VM: the desktop, with the gateway running as a container inside it | Convenience: one download, one VM, less memory | An installer ISO you boot in a VM you create ([Single VM (installer ISO)](#single-vm-installer-iso)) |

The difference in protection is in the threat model:
[Two VMs vs single VM](THREAT_MODEL.md#two-vms-vs-single-vm).

Paths: open the prebuilt two-VM archives (Quick start sections), install
the single VM edition from its ISO, run the guided build (next section),
or build by hand (steps 1-7). A final section covers exporting the release
files, for maintainers. Once installed, Ombra updates itself in place when
you ask; see [UPDATES.md](UPDATES.md).

## Guided build

```sh
curl -fsSL https://ombra-os.org/build.sh | bash
```

The script is [`scripts/build.sh`](../scripts/build.sh). It checks the Mac,
installs missing tools with Homebrew after asking, verifies the pinned
downloads, builds, and creates and installs both VMs. `--isos-only` stops
after the installer ISOs; `--yes` answers every prompt.
`--edition single` builds only the single VM installer ISO
(`build/disks/ombra-install-single.iso`) and creates no VM; VMware Fusion
is not needed for it.

## Quick start (two VMs): requirements

- Apple Silicon Mac with VMware Fusion, or with UTM 5.0.8 or newer
- About 45 GB of free disk. The downloads are about 6.8 GB (desktop) and
  0.9 GB (gateway), and you need room for the archive and the unzipped
  copy until you delete the archive. The provisioned virtual disks are
  5 GB (gateway) and 30 GB (desktop). First-use setup re-encrypts the
  whole desktop disk, so it grows to its full 30 GB then. If the Mac runs
  out of space, Fusion stops the VM with a "no space left" prompt: free
  space and choose Retry.

## Quick start (two VMs): the release images

1. Download `ombra-gateway-arm64-v1.2.0.vmwarevm.zip`,
   `ombra-desktop-arm64-v1.2.0.vmwarevm.zip` and `SHA256SUMS.txt` from the
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

Releases before v1.1 shipped as OVA files. An OVA cannot carry the ARM
guest type, so Fusion on Apple silicon refused to start an imported OVA
("requires x86"); the `.vmwarevm` archives keep it.

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

`SHA256SUMS.txt.sig` (from v1.2.0) is an Ed25519 signature of
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

## Quick start (two VMs): UTM

The same two machines run under UTM instead of VMware Fusion. Pick one
hypervisor and use its archives; do not mix them.

| Step | Detail |
|---|---|
| Host | Apple Silicon Mac, UTM 5.0.8 or newer (QEMU backend; Ombra does not use the Apple Virtualization backend) |
| Download | `ombra-gateway-arm64-v1.2.0.utm.zip`, `ombra-desktop-arm64-v1.2.0.utm.zip` and `SHA256SUMS.txt`; verify with `shasum -a 256 -c SHA256SUMS.txt --ignore-missing`. Check the signature too ([Verify the signature](#verify-the-signature)) |
| Unpack | Double-click each zip in Finder, or run `ditto -x -k <zip> .` in a terminal |
| Import | Double-click each `.utm` to add it to UTM. Nothing needs changing in the VM settings |
| Start | Gateway first: pick a boot mode, wait for its connectivity panel. Then the desktop: pick **Persistent** for the first boot. First boot is identical to Fusion (see below) |

What differs from Fusion:

| Topic | UTM |
|---|---|
| Display | The desktop follows the UTM window size. Leave Retina mode off. The display card is `virtio-gpu-pci` on purpose: typing was slower with the GL-accelerated cards in testing, and they hand the guest access to the Mac's graphics stack |
| Private link | Both VMs sit on UTM's host-only network (10.55.20.0/24); the guests use static 10.55.10.x addresses on top of it, so the Mac has no address on their subnet. The gateway's upstream is UTM's Shared Network (NAT) |
| Restart | A restart from inside the guest hangs on UTM 5.0.8 unless QEMU runs the interrupt controller itself, so the bundles carry the argument `-machine kernel-irqchip=off`. Do not remove it. The price is about 15% of one Mac core while the VM is idle |
| Window size | The desktop follows the UTM window when you resize it. To make that reliable, the desktop turns KWin's compositor off when it runs under QEMU (UTM), so there are no window shadows, translucency or animations there. VMware Fusion keeps them |
| Host channels | Clipboard sharing, shared folders, USB sharing and serial ports are off in the shipped configuration. Leave them off: turning clipboard sharing on lets the Mac read and write the guest clipboard |
| Guest tools | `qemu-guest-agent` answers only ping, sync and info; `spice-vdagent` drives window-size changes. The VMware tools stay installed and idle |
| Not available | The Mac Shared Folder transfer disk is a Fusion feature and is not supported under UTM |
| Updates | The in-place updater works the same way; it needs Persistent mode |

## Single VM (installer ISO)

One VM that you create yourself in VMware Fusion or UTM, installed from
Ombra's ISO.

| Item | Detail |
|---|---|
| File | `ombra-single-arm64-v<version>.iso` and `SHA256SUMS.txt`, from v1.2.0 or later (v1.1.0 does not have this edition). Or build it: `bash scripts/build.sh --edition single`, or `bash build/make-install-iso.sh single` after steps 1-3 below |
| Verify | `shasum -a 256 -c SHA256SUMS.txt --ignore-missing`, and the signature of `SHA256SUMS.txt` ([Verify the signature](#verify-the-signature)) |
| Network during install | Needed. The installer downloads Debian packages over the VM's NAT, directly from Debian's mirror, not through Tor (see [threat model](THREAT_MODEL.md#two-vms-vs-single-vm)) |
| Time | Depends on the network: about 5 to 10 minutes on a fast connection in testing |
| Keyboard | US layout in the installer and at the unlock screen |

### VM settings

The VM is yours, so Ombra's own VM settings are not there. Set these in
Fusion or UTM when you create it:

| Setting | Value |
|---|---|
| Guest type | Linux, 64-bit Arm (arm64) |
| CPUs | 4 |
| Memory | 6 GB (the installer stops below about 3 GB) |
| Disk | 30 GB (the installer stops below 24 GB) |
| Network | One adapter, on NAT (Fusion: Share with my Mac; UTM: Shared Network). No second adapter |
| CD/DVD | The Ombra ISO |
| Clipboard sharing, drag and drop, shared folders | Off |
| Snapshots | None: a snapshot keeps an old copy of the VM, and its memory if taken while running |
| Stopping | Shut down from inside Ombra; do not suspend (suspend writes the VM's memory, disk key included, to the Mac's disk) |

Inside the VM, Ombra removes VMware's drag-and-drop, clipboard and
shared-folder helpers and keeps them from coming back, and it makes
UTM's clipboard agent (`spice-vdagent`) non-executable. It cannot change
the VM settings, and it cannot turn off VMware Tools' host time
synchronisation from inside the guest.

### Steps: VMware Fusion

1. Download the ISO and `SHA256SUMS.txt` into one folder and verify them
   (Item table above).
2. In Fusion, create a new virtual machine from the ISO file. Choose a
   64-bit Arm Linux guest type.
3. Before starting it, open the VM's settings and set the values in the
   VM settings table: 4 CPUs, 6 GB memory, a 30 GB disk, one network
   adapter on Share with my Mac, and sharing and drag and drop off.
4. Start the VM. The menu entry **Install Ombra (single VM)** starts by
   itself after 3 seconds.
5. Enter the password for the account `ombra`, twice.
6. Enter the disk encryption passphrase, twice. At least 8 characters;
   it cannot be recovered. Do not use `ombra-disk`: the install stops
   with an error if you do.
7. Wait. The install runs on its own and restarts into Ombra when done.
   Detach the ISO if Fusion still has it attached.
8. At the boot menu choose **Persistent**, unlock with your passphrase,
   and log in as `ombra` with your password.

### Steps: UTM

1. Download and verify as for Fusion.
2. In UTM, create a new virtual machine with **Virtualize** (not
   Emulate), operating system Linux, and select the ISO as the boot image.
3. Set the values in the VM settings table: 4 CPUs, 6 GB memory, a
   30 GB disk, the network on Shared Network, clipboard sharing and
   shared folders off.
4. In the VM's QEMU settings, add the argument
   `-machine kernel-irqchip=off` (UTM needs it for restarts from inside
   the guest; the two-VM UTM bundles carry it already).
5. Start the VM and follow steps 4-8 of the Fusion steps.

UTM notes:

| Topic | Detail |
|---|---|
| Display | The two-VM UTM bundles use the `virtio-gpu-pci` card without GL. In this edition the window-size agent is disabled (it also carries UTM's clipboard), so the display keeps its size when the UTM window changes |
| Clipboard | Leave clipboard sharing off in UTM; inside the guest the agent that carries it does not run |

### After the install

| Topic | Detail |
|---|---|
| First use | None: the disk is created with your passphrase and the account with your password during the install |
| Account | `ombra`, not an administrator (no `sudo` group). Root login is disabled. Your password also authorizes Update Ombra |
| Network | Only through the gateway container. If the container is not running, the VM has no network |
| Boot modes | Persistent or Amnesic at every start, as in the two-VM edition |
| Updates | Update Ombra, as on the two-VM desktop ([UPDATES.md](UPDATES.md)). The gateway container's image is replaced only by an Ombra update for this edition; Check Debian security updates updates the desktop's packages only |
| Time | Ombra checks the clock over Tor 2 minutes after boot and corrects it. A Fusion VM you create presents the Mac's local time as the hardware clock, so until then the clock is off by the Mac's UTC offset |

## Requirements (building from source)

- Apple Silicon Mac, macOS
- VMware Fusion (not needed for `--edition single`)
- About 50 GB free disk (gateway 5 GB + desktop 30 GB, plus the ISOs
  and build outputs)
- Rust via `rustup` (`core/build.sh` runs `rustup target add`; the
  toolchain version is pinned in `core/rust-toolchain.toml`)
- `xorriso` (`brew install xorriso`), `python3`

Tor Browser ships from the stable channel (16.0.1, linux-aarch64).

## 1. Fetch the pinned Debian netinst

The exact ISO is pinned in `build/pins/debian-netinst-arm64.txt` —
read it for the filename, size and sha256, and download it from the
source listed there into `build/isos/`:

```sh
mkdir -p build/isos
curl -L -o build/isos/debian-13.7.0-arm64-netinst.iso \
  https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.7.0-arm64-netinst.iso
bash build/verify-iso.sh
```

If the `current` path no longer carries the pinned file (a newer Debian
point release superseded it), fetch it from the archive instead:
`https://cdimage.debian.org/cdimage/archive/13.7.0/arm64/iso-cd/`.

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
cp dist/aarch64/ombra dist/aarch64/ombra-statusd \
   ../desktop/rootfs/usr/local/bin/
cp dist/aarch64/ombra dist/aarch64/ombra-torctl-filter \
   ../gateway/rootfs/usr/local/bin/
cd ..
```

## 3. Stage the pinned downloads (desktop and single ISOs)

The desktop and single ISOs carry three sha256-pinned files: Tor Browser
(stable channel, `build/pins/torbrowser.txt`), Feather
(`build/pins/feather.txt`) and SimpleX (`build/pins/simplex.txt`). Each
is verified again inside the installer. Fetch the exact `file=` named in
each pin from its `url=` and place it in `build/vendor/` (the directory
is gitignored). Superseded builds move away, so use the pin's
`archive_url` if `url` no longer has the file:

```sh
mkdir -p build/vendor
curl -L -o build/vendor/tor-browser-linux-aarch64-16.0.1.tar.xz \
  https://dist.torproject.org/torbrowser/16.0.1/tor-browser-linux-aarch64-16.0.1.tar.xz
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
bash build/make-install-iso.sh single    # only for the single VM edition
```

Output: `build/disks/ombra-install-gateway.iso`,
`build/disks/ombra-install-desktop.iso` and
`build/disks/ombra-install-single.iso`. Each ISO is self-contained:
preseed, overlay and pinned payload travel inside the netinst initrd.
The single ISO is installed by hand as in
[Single VM (installer ISO)](#single-vm-installer-iso); steps 5-7 are for
the two-VM edition.

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

The script instantiates the VM from the proven template (pinned MACs,
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
  Ombra updates, signed and checked before anything is written.
- Debian's security updates install only when you ask: **Update Ombra** →
  **Check Debian security updates** on the desktop, `sudo ombra-update
  security --no-rollback` on the gateway (it cannot be undone there). The
  v1.1.0 images do not have this action.
- A rollback on the desktop restores the root volume from the snapshot
  taken before the update. What happens to your home folder depends on the
  image you installed from:

  | Installed from | Home folder on rollback |
  |---|---|
  | v1.1.0 desktop image | On the root volume, so it goes back too: anything saved after the update is lost. Copy it out first |
  | v1.2.0 and later (desktop and single VM) | On its own volume: not affected |

  `ombra-update info` prints `home_on_root=yes` or `no`; Update Ombra
  warns only when it is `yes`. An update cannot move `/home`; that needs a
  new image.
- Only the latest release is supported; earlier releases get no fixes.
- v1.0 installs have no updater and need a fresh download of both machines.
- From v1.1.0 to v1.2.0 there is no in-place update: install both
  machines from the v1.2.0 images, after copying your files out of the
  old desktop. The new disk layout, kernel settings and VM settings need
  new images, and a v1.1.0 gateway cannot run `ombra-update` (its image
  lacks the sudo grants, and its console account has no password).
  Releases after v1.2.0 update v1.2.0 machines in place.
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
converted to qcow2, in a different hypervisor wrapper. The v1.1.0 UTM archives
were built after the Fusion ones and add the QEMU guest tools; the published
Fusion archives are unchanged. Both VMs must be powered off and post-installed,
and the desktop must never have been booted.
Needs `qemu-img` (`brew install qemu`) and UTM.app.

```sh
bash build/utm/export-bundle.sh gateway
bash build/utm/export-bundle.sh desktop
```

The script converts the disk to qcow2, writes `config.plist` with every
host-guest channel off, zips the bundle and runs `build/utm/verify-bundle.sh`
on the archive. A TEST build is refused unless you pass `--allow-test`, which
writes an unzipped `ombra-<target>-TEST.utm` for local end-to-end testing only.

## Release the single VM ISO (maintainers)

The single VM edition ships only as its installer ISO; both exporters
refuse `single`.

```sh
bash build/make-install-iso.sh single
bash build/release-single-iso.sh
```

`release-single-iso.sh` refuses a TEST ISO or an initrd that carries a
disk passphrase or a password hash, copies the ISO to
`build/releases/ombra-single-arm64-v<version>.iso` and replaces its line
in `build/releases/SHA256SUMS.txt`. Sign the sums again afterwards
(`scripts/update/sign-sums.sh`, see [UPDATES.md](UPDATES.md)).
