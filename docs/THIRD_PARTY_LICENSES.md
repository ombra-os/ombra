# Third-party software in the Ombra images

The packages and assets below ship in the images. Everything is either
a Debian trixie package taken from the live suite at build time (every
version recorded in `/usr/share/ombra/packages.txt` on each machine) or
pinned by sha256 or tag/commit with its hash recorded. The release
archives download no software at install or boot; at runtime the machines fetch
only what the [threat model](THREAT_MODEL.md#designed-runtime-probes)
lists, and new software arrives only as a signed Ombra update or app
update the user starts. Full license texts are embedded in each upstream
archive and installed on the images alongside the software; vendored
license copies live in `desktop/rootfs/usr/share/ombra-assets/`.

| Component | Version/commit | License | Pin / provenance |
|---|---|---|---|
| Debian | trixie (13.8.0 netinst) | DFSG-free aggregate | build/pins/debian-netinst-arm64.txt |
| Tor Browser (stable channel, linux-aarch64) | 16.0.3 | MPL-2.0 (+ bundled licenses in the browser directory) | build/pins/torbrowser.txt |
| Electrum (upstream release tarball in `/opt/electrum`; sha256 pin checked at build, upstream signature checked by the maintainer when the pin was made) | 4.8.4 | MIT | build/pins/electrum.txt |
| Feather Wallet (AppImage; sha256 pin checked at build, upstream signature checked by the maintainer when the pin was made) | 2.9.1 | BSD-3-Clause | build/pins/feather.txt |
| SimpleX Chat (arm64 desktop deb; upstream signs only its x86_64 checksums, so this is a sha256 pin with no upstream signature) | 7.1.4 | AGPL-3.0 | build/pins/simplex.txt |
| Kleopatra, OnionShare, Electrum (icon and libraries for the pinned release), proxychains4 (Debian trixie packages) | trixie | GPL-2.0-or-later, GPL-3.0, MIT, GPL-2.0-or-later | Debian suite |
| qemu-guest-agent, spice-vdagent (Debian trixie packages; UTM/QEMU guest tools, locked down by `/etc/qemu/qemu-ga.conf`) | trixie | GPL-2.0-or-later, GPL-3.0-or-later | Debian suite |
| Colloid-kde (look-and-feel, desktop theme, aurorae, color scheme, Kvantum, SDDM greeter) | commit `b768904d10ba9fcb95abfb59538eab100b1fed1e` | GPL-3.0 | desktop/rootfs/usr/share/ombra-assets/README.md |
| Kaze icons (dark variant) | commit `ab77c4d1cbfbb1fc9de1a125a3f9ed74c2513cd3` | GPL-3.0 | build/pins/kaze.txt |
| Phinger cursors (light variant) | tag `v2.1` | CC-BY-SA-4.0 | desktop/rootfs/usr/share/ombra-assets/README.md |
| JetBrains Mono Nerd Font (core weights) | release `v3.5.1` | SIL OFL 1.1 | desktop/rootfs/usr/share/ombra-assets/README.md |
| JetBrains Mono subsets and Ombra logo mask embedded in the boot binaries (`core/assets`) | derived from the row above | SIL OFL 1.1 (fonts), project mark (logo) | desktop/rootfs/usr/share/ombra-assets/README.md |
| Panel Colorizer plasmoid | release `v8.0.0` | GPL-3.0 | desktop/rootfs/usr/share/ombra-assets/README.md |
| Terminus console font (Uni2-Terminus16, embedded in the boot binaries) | console-setup-linux 1.242~deb13u1 (Debian trixie) | Public domain per the console-setup package copyright; the Terminus glyphs are SIL OFL 1.1 upstream (Dimitar Toshkov Zhelev) — recorded under the stricter of the two | core/assets/Uni2-Terminus16.psf (source URL + hashes in desktop/rootfs/usr/share/ombra-assets/README.md) |
| Ombra wallpapers and logo (first-party; `usr/share/backgrounds/ombra/` and the default wallpaper package) | sha256 per file in the assets README | GPL-3.0-or-later, same terms as the repo | desktop/rootfs/usr/share/ombra-assets/README.md |
| Session, lock-screen and login wallpapers (`ombra-ink-4k.jpg`, SDDM `background.jpg`) | sha256 in the assets README | first-party | desktop/rootfs/usr/share/ombra-assets/README.md |
| Tor Browser launcher icon (`tor-browser.png`, derived from the pinned bundle's icon) | pinned Tor Browser bundle | Tor Project artwork under the browser's MPL-2.0 distribution; "Tor" and the onion logo are Tor Project trademarks, used only to identify the unmodified launcher | desktop/rootfs/usr/share/ombra-assets/README.md |

Pins: the build enforces the sha256 in each `build/pins/*.txt` file
(`build/make-install-iso.sh`, `scripts/build.sh`, and again inside the
installer). It does not check upstream signatures. Where upstream signs,
the maintainer checked the signature once when the pin was made; the pin
file records the signer and fingerprint:

| Pin | Upstream signature |
|---|---|
| Tor Browser | Signed checksum manifest, Tor Browser Developers key |
| Feather | Detached signature, FeatherWallet key |
| SimpleX (arm64) | None: upstream's signed checksum list covers x86_64 files only. The pin proves the file has not changed since, not who built it |
| Debian netinst | sha256 and size only |

## Source

| Software | Where the source is |
|---|---|
| Debian packages | Debian's archive (deb.debian.org, and snapshot.debian.org for older versions), for the exact versions listed in `/usr/share/ombra/packages.txt` on each machine |
| Ombra's own code and configuration | This repository, at the release tag |
| Vendored upstream assets and pinned applications | The upstream projects at the tag, commit or release named above and in the assets README |

## Rust crates linked into the static binaries

The binaries built from `core/` (`ombra-askpass`, `ombra-welcome`,
`ombra`, `ombra-statusd`, `ombra-torctl-filter`) are aarch64
musl-static builds. The table lists the crates in the dependency graph
for the `aarch64-unknown-linux-musl` target, generated with
`cargo metadata --format-version 1 --locked` and
`cargo tree --target aarch64-unknown-linux-musl -e normal`, from the
exact versions pinned in `core/Cargo.lock`. License expressions are the
SPDX values from each crate's manifest (a few crates declare the older
`MIT/Apache-2.0` form, shown here as `OR`). The graph includes
procedural-macro crates that run only at build time; they are not part
of the shipped binaries. Each crate's license text is in its source
package. The `ombra-boot` crate itself is GPL-3.0-or-later.

| Crate | Version | License |
|---|---|---|
| allocator-api2 | 0.2.21 | MIT OR Apache-2.0 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 |
| bitflags | 2.13.2 | MIT OR Apache-2.0 |
| castaway | 0.2.4 | MIT |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 |
| compact_str | 0.9.1 | MIT |
| convert_case | 0.10.0 | MIT |
| core_maths | 0.1.1 | MIT |
| critical-section | 1.2.0 | MIT OR Apache-2.0 |
| crossterm | 0.29.0 | MIT |
| darling | 0.24.1 | MIT |
| darling_core | 0.24.1 | MIT |
| darling_macro | 0.24.1 | MIT |
| derive_more | 2.1.1 | MIT |
| derive_more-impl | 2.1.1 | MIT |
| document-features | 0.2.12 | MIT OR Apache-2.0 |
| either | 1.19.0 | MIT OR Apache-2.0 |
| equivalent | 1.0.3 | Apache-2.0 OR MIT |
| errno | 0.3.15 | MIT OR Apache-2.0 |
| foldhash | 0.1.5 | Zlib |
| foldhash | 0.2.0 | Zlib |
| fontdue | 0.9.5 | MIT OR Apache-2.0 OR Zlib |
| hashbrown | 0.15.5 | MIT OR Apache-2.0 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 |
| heck | 0.5.0 | MIT OR Apache-2.0 |
| ident_case | 1.0.1 | MIT OR Apache-2.0 |
| indoc | 2.0.8 | MIT OR Apache-2.0 |
| instability | 0.3.14 | MIT |
| itertools | 0.14.0 | MIT OR Apache-2.0 |
| itoa | 1.0.19 | MIT OR Apache-2.0 |
| kasuari | 0.4.13 | MIT OR Apache-2.0 |
| libc | 0.2.191 | MIT OR Apache-2.0 |
| libm | 0.2.16 | MIT |
| line-clipping | 0.3.8 | MIT OR Apache-2.0 |
| linux-raw-sys | 0.12.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| litrs | 1.0.1 | MIT OR Apache-2.0 |
| lock_api | 0.4.14 | MIT OR Apache-2.0 |
| log | 0.4.35 | MIT OR Apache-2.0 |
| lru | 0.18.5 | MIT |
| memchr | 2.8.3 | Unlicense OR MIT |
| mio | 1.2.5 | MIT |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| ratatui | 0.30.2 | MIT |
| ratatui-core | 0.1.2 | MIT |
| ratatui-crossterm | 0.1.2 | MIT |
| ratatui-widgets | 0.3.2 | MIT |
| rustix | 1.1.6 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| rustversion | 1.0.23 | MIT OR Apache-2.0 |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 |
| serde_core | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |
| signal-hook | 0.3.18 | Apache-2.0 OR MIT |
| signal-hook-mio | 0.2.5 | MIT OR Apache-2.0 |
| signal-hook-registry | 1.4.8 | MIT OR Apache-2.0 |
| smallvec | 1.16.5 | MIT OR Apache-2.0 |
| static_assertions | 1.1.0 | MIT OR Apache-2.0 |
| strsim | 0.11.1 | MIT |
| strum | 0.28.0 | MIT |
| strum_macros | 0.28.0 | MIT |
| syn | 2.0.119 | MIT OR Apache-2.0 |
| syn | 3.0.10 | MIT OR Apache-2.0 |
| thiserror | 2.0.21 | MIT OR Apache-2.0 |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 |
| ttf-parser | 0.25.1 | MIT OR Apache-2.0 |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| unicode-segmentation | 1.13.3 | MIT OR Apache-2.0 |
| unicode-truncate | 2.0.1 | MIT OR Apache-2.0 |
| unicode-width | 0.2.3 | MIT OR Apache-2.0 |
| zeroize | 1.9.1 | Apache-2.0 OR MIT |
| zmij | 1.0.23 | MIT |

## Ombra-authored overrides of upstream metadata

- `desktop/rootfs/usr/share/plasma/plasmoids/org.kde.plasma.clipboard/metadata.json`
  is an Ombra-modified copy of KDE's clipboard applet metadata (from
  plasma-workspace). The modification removes the notification-area
  category and sets `EnabledByDefault` to false so the clipboard-history
  applet never loads. The file keeps KDE's translations and its
  upstream `License` field (GPL-2.0+); Ombra's changes to it are
  GPL-3.0-or-later.
- The Panel Colorizer plasmoid (`luisbocanegra.panel.colorizer/`) is
  installed with upstream's files verbatim; Ombra changes none of them.

## Vendoring deltas and display naming

Vendored Colloid-kde themes ship with their display names renamed to
Ombra, so the names a user sees on screen say Ombra. The internal
project identifiers (for example `com.github.vinceliuice.*`) and the
licenses are unchanged, and the author fields of the look-and-feel,
Plasma style and SDDM theme credit the upstream author ("Vince Liuice
(Colloid-kde), modified for Ombra"). The licenses travel verbatim, and each asset's upstream source, tag/commit, archive
hash and license are recorded in
`desktop/rootfs/usr/share/ombra-assets/README.md`.

## Source headers in the SDDM theme

The vendored `sddm/themes/Colloid-dark/*.qml` files are KDE sources
carrying `SPDX-License-Identifier: LGPL-2.0-or-later`. They are kept
verbatim; the theme as a whole remains GPL-3.0 via Colloid-kde, which is
compatible with LGPL-2.0-or-later components.

## Terminus font license text

The embedded Terminus console font is covered by the SIL Open Font
License 1.1; the full text ships as
`desktop/rootfs/usr/share/ombra-assets/Terminus-OFL-1.1.txt`.

## Wallets

Two wallets ship on the desktop: Electrum (sha256-pinned upstream release) and
Feather (sha256-pinned upstream AppImage). Both are listed in the table
above.
