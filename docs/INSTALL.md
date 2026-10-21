# Installing Ombra

Three paths: import the prebuilt OVAs into Fusion (next section), run the
guided build below, or build by hand (steps 1-7). A final section covers
exporting the OVAs, for maintainers.

## Guided build

```sh
curl -fsSL https://ombra-os.org/build.sh | bash
```

The script is [`scripts/build.sh`](../scripts/build.sh). It checks the Mac,
installs missing tools with Homebrew after asking, verifies the pinned
downloads, builds, and creates and installs both VMs. `--isos-only` stops
after the installer ISOs; `--yes` answers every prompt.

## Quick start: requirements

- Apple Silicon Mac, VMware Fusion
- About 40 GB of free disk. The downloads are about 5.1 GB (desktop) and
  0.7 GB (gateway). The provisioned virtual disks are
  5 GB (gateway) and 30 GB (desktop); they occupy less until they fill.

## Quick start: the release OVAs

1. Download `ombra-gateway-arm64-v1.0.0.ova`,
   `ombra-desktop-arm64-v1.0.0.ova` and `SHA256SUMS.txt` from the
   download page into one folder, and verify what you downloaded:

   ```sh
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```

   Every file you did download must report `OK`.
2. Double-click each `.ova` (or use File > Import in Fusion) and import
   it. Accept the defaults; Fusion may warn that the OVA was not
   signed. Nothing needs changing in the VM settings.
3. Power on the gateway first and pick a boot mode (below), let it reach
   its health report, then power on the desktop, pick a boot mode, and
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

## Requirements (building from source)

- Apple Silicon Mac, macOS
- VMware Fusion
- About 45 GB free disk (gateway 5 GB + desktop 30 GB, plus the ISOs
  and build outputs)
- Rust via `rustup` (`core/build.sh` runs `rustup target add`; the
  toolchain version is pinned in `core/rust-toolchain.toml`)
- `xorriso` (`brew install xorriso`), `python3`

Tor Browser ships from the alpha channel (16.0a13): it is the only
channel that publishes linux-aarch64 builds.

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
build refuses to run if the overlay binaries drift from `dist/`):

```sh
cp dist/aarch64/ombra-askpass dist/aarch64/ombra-welcome \
   ../desktop/rootfs/usr/local/libexec/ombra/
cp dist/aarch64/ombra dist/aarch64/ombra-statusd \
   ../desktop/rootfs/usr/local/bin/
cp dist/aarch64/ombra-torctl-filter \
   ../gateway/rootfs/usr/local/bin/
cd ..
```

## 3. Stage the pinned Tor Browser (desktop ISO only)

The desktop ISO carries the sha256-pinned Tor Browser tarball (alpha
channel, the only one with linux-aarch64 builds); it is verified again
inside the installer. Fetch the exact file named in
`build/pins/torbrowser.txt` and place it in `build/vendor/` (the
directory is gitignored). Superseded alpha builds move to Tor's archive,
so use the pin's `archive_url`:

```sh
mkdir -p build/vendor
curl -L -o build/vendor/tor-browser-linux-aarch64-16.0a13.tar.xz \
  https://archive.torproject.org/tor-package-archive/torbrowser/16.0a13/tor-browser-linux-aarch64-16.0a13.tar.xz
shasum -a 256 build/vendor/tor-browser-linux-aarch64-16.0a13.tar.xz
```

The hash must equal the pin's `sha256=` line; `make-install-iso.sh`
re-checks it before staging.

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
  up as a Tor router and shows its health report on its console. Both
  machines' accounts are born locked: there is no default login
  password on either.
- Choose Persistent at the boot menu for first boot. In Amnesic mode the
  first-use screen only asks you to restart in Persistent mode.
- Tor Browser's "New Identity" and circuit display are unavailable by
  design — the control port is filtered to a small read-only status
  dialect.

## Updates

- Only the latest release is supported; earlier releases get no fixes and
  their images are not kept.
- Tor Browser's updater is disabled. Machine packages are frozen at the
  release image, and a new Tor Browser arrives with a new release
  image.
- Desktop OS packages are frozen at the release image — the desktop
  ships no root shell by design. Updated packages arrive with new
  release images.
- The gateway's Amnesic mode starts every boot from the shipped image;
  gateway updates are new images by construction.

## Export the release OVAs (maintainers)

Start from freshly installed VMs, both powered off, both post-installed.
The desktop must never have been booted.

```sh
bash build/fusion/export-release-image.sh gateway
bash build/fusion/export-release-image.sh desktop
bash build/fusion/verify-ova.sh build/releases/ombra-gateway-arm64-v1.0.0.ova
bash build/fusion/verify-ova.sh build/releases/ombra-desktop-arm64-v1.0.0.ova
```

The export strips builder residue from a copy of the VM bundle, runs
`ovftool`, and writes a single file per VM (the disk is
compressed inside; an encrypted disk does not shrink further). Set
`OMBRA_SPLIT=1` to split into `.ova.part-aa`, `.part-ab`, ... under
GitHub's 2 GiB release-asset cap for GitHub-only hosting. Output lands
in `build/releases/` with one `SHA256SUMS.txt`, rewritten on every run
with a line per artifact present; downloaders filter it with
`--ignore-missing`.
`verify-ova.sh` imports the OVA into a scratch directory and asserts the
shipped shape of the resulting VM.
