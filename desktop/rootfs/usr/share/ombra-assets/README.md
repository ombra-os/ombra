# Vendored upstream assets — provenance, pins, licenses

Everything visual on the Ombra desktop is vendored in this overlay.
Nothing downloads at install time or at runtime: no KDE Store (the
look-and-feel metadata's `kns://` links are inert declarations that
upstream ships, and nothing in Ombra calls them) and no Get New Stuff
network access. The files were fetched once from the pinned upstream
tags and commits below and committed to this repository. Hashes are of
the exact downloaded archives (`shasum -a 256`).

| Asset | Upstream | Pinned at | Archive sha256 | License |
|---|---|---|---|---|
| Colloid-kde (look-and-feel, desktoptheme, aurorae, color scheme, Kvantum, SDDM greeter) | github.com/vinceliuice/Colloid-kde | commit `b768904d10ba9fcb95abfb59538eab100b1fed1e` (main head 2025-07-06; upstream stopped tagging releases in 2022 — commit-pinned) | `007964b43d1c8a1635c970d7d5f00b6687f532f061c71df0c401b0a1d13f15e5` | GPL-3.0 (`Colloid-kde-GPL-3.0` in this dir) |
| Phinger cursors (light variant) | github.com/phisch/phinger-cursors | tag `v2.1`, release asset `phinger-cursors-variants.tar.bz2` | `ddb7310c62bf8e0e2798a24f8a867e4af7b17a39757ba45c85e13f3988f646fc` | CC-BY-SA-4.0 (`phinger-cursors-CC-BY-SA-4.0` in this dir) |
| JetBrains Mono Nerd Font (6 core weights) | github.com/ryanoasis/nerd-fonts | release `v3.5.1`, asset `JetBrainsMono.tar.xz` | `04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf` | SIL OFL 1.1 (`OFL.txt` shipped beside the fonts) |
| Panel Colorizer plasmoid | github.com/luisbocanegra/plasma-panel-colorizer | release `v8.0.0` (`.plasmoid` package) | `93f737af4d6291f2c84800090258c77511270817d7a5ecc56de45a6af966b2ee` | GPL-3.0 (`plasma-panel-colorizer-GPL-3.0` in this dir) |
| Kaze icons (dark variant) | github.com/2O48/Kaze | commit `ab77c4d1cbfbb1fc9de1a125a3f9ed74c2513cd3` (main head 2026-07-07; upstream has no releases/tags — commit-pinned, tarball sha256 also in `build/pins/kaze.txt`) | `4a0c92682cef5e7299abe00474db69bf6503925050e2f26067646abd0393aa2a` | GPL-3.0 (`Kaze-GPL-3.0` in this dir) |

## Vendoring deltas from upstream (everything else is verbatim)

- **Colloid-kde**: only the DARK variant is vendored (light/nord
  variants dropped). The SDDM theme is the `sddm/6.0` (Qt6 — trixie's
  sddm is a Qt6 build) variant, renamed `Colloid-dark` per upstream's
  own installer seds, and `background.png` is OMBRA's
  `backgrounds/ombra/ombra-02-4k.png`, not Colloid's preview image.
  `contents/layouts/org.kde.plasma.desktop-layout.js` is Ombra's own
  dock layout REPLACING upstream's (same filename as upstream — the
  loader asks for `$(shell)-layout.js` exactly). The Kvantum theme is re-laid as the canonical
  one-dir-per-theme layout (`Kvantum/ColloidDark/`).
- **Phinger cursors**: only the light (white) variant ships
  (`icons/phinger-cursors-light/`), verbatim — the dark and left-handed
  variants were dropped. `phinger-cursors-light` is upstream's own
  recommended default.
- **Icons: Kaze-dark** (a Breeze refresh): only the dark
  variant ships, verbatim (light/twilight dropped). Kaze inherits
  `breeze,gnome,hicolor` — all from Debian packages a Plasma desktop
  already carries (`breeze-icon-theme`, `adwaita-icon-theme`).
- **Fonts**: only JetBrainsMonoNerdFont-{Regular,Bold,Italic,BoldItalic,Medium,MediumItalic};
  UI font Noto Sans comes from Debian's `fonts-noto-core` package
  (pkgsel), NOT vendored.
- **Panel Colorizer**: installed verbatim; deliberately NOT wired into
  the default panel layout (its "hide widget" default would put a
  visible widget blob in the dock — the user enables it in two clicks
  from the panel's Add Widgets sheet).

Update procedure: bump the pin, re-download, re-apply the deltas
above, re-hash, update this file.

## The boot console font (vendored in `core/assets/`, NOT this overlay)

The unlock and welcome screens load their own PSF console font from
inside the Rust binaries (`core/src/psf.rs`, KDFONTOP + PIO_UNIMAP —
no console-setup, no initramfs hook, nothing fetched or configured at
install/boot). The bytes are embedded via `include_bytes!`, so the
provenance lives here with the rest of the visual assets:

| Field | Value |
|---|---|
| Asset | `Uni2-Terminus16.psf` — Terminus 8x16 console font, PSF1, 512 glyphs, embedded Unicode map |
| Source package | Debian trixie `console-setup-linux` 1.242~deb13u1 (source `console-setup`), arch all |
| Downloaded from | `https://deb.debian.org/debian/pool/main/c/console-setup/console-setup-linux_1.242~deb13u1_all.deb`, path `./usr/share/consolefonts/Uni2-Terminus16.psf.gz` |
| Pinned at | package version `1.242~deb13u1` (trixie point release; pool filename above is the pin) |
| Archive sha256 | `76b38323e80e09cd44a4ca4b0eaa681101874f208b8b5ba00c8c594cfd3b91c2` (`Uni2-Terminus16.psf.gz`, 4104 bytes) |
| Vendored file sha256 | `002f331400ea0257f894a6b81fafa7a0ab8ba8b816149b81487043dbf2d37e1a` (`Uni2-Terminus16.psf`, 10804 bytes — the .psf.gz decompressed, NO edits) |
| License | The console-setup compiled console fonts are "public domain by nature" per the source package's `debian/copyright`; the glyphs are Terminus Font by Dimitar Toshkov Zhelev, SIL Open Font License 1.1 upstream (recorded here under the stricter of the two) |

Why this exact file: full coverage of every glyph the boot TUIs draw —
the rounded corners U+256D..U+2570 (the whole box-drawing block,
actually), the U+00B7 mask, the U+2588 caret and all printable ASCII —
in an 8x16 cell, which is the stock console's geometry, so loading it
changes zero rows/columns. The coverage is test-enforced against the
theme's glyph set (`core/src/psf.rs` tests; the ISO suite re-parses the
font out of the shipped binaries).

## First-party art (not vendored — nothing to pin)

The white Ombra ring on brand black (1424x1424 master, not shipped) is
first-party. The two derived files the desktop ships are plain downscaled
PNGs of it (Lanczos, no recolour, no
retouch — the same bytes at 512px):

| Shipped as | What reads it |
|---|---|
| `usr/share/sddm/faces/ombra.face.icon` | the SDDM greeter's avatar for the login screen. sddm looks up `<username>.face.icon` in its `FacesDir` (`/usr/share/sddm/faces`); the username is the fixed `ombra` (core/src/welcome.rs `USER`), so the system-wide copy covers every boot without touching a home directory |
| `etc/skel/.face.icon` | the same ring as the session user's own face, so Plasma's user model, the lock screen and About Me show the emblem instead of a generic silhouette — and so it holds even if the account is ever renamed (sddm falls back to `$HOME/.face.icon`) |

## First-party wallpapers

Created for Ombra and licensed GPL-3.0-or-later, the same terms as the
repository. The wallpaper package's `metadata.json` declares the same
license. Shipped files and
their sha256:

| Shipped as | sha256 |
|---|---|
| `usr/share/backgrounds/ombra/ombra-01-4k.png` | `2304f951cf3624d982a181afe5acd6ecd19fe20d2c86a7e5e8f91b577be1c982` |
| `usr/share/backgrounds/ombra/ombra-02-4k.png` (also the SDDM `background.png`) | `1e8511ddbf96f892dbb368be9f6d56322186193f5b611273362b5a1c9e4aef33` |
| `usr/share/backgrounds/ombra/ombra-dark.png` | `6f702fccdf0ebdac5995cd5cbf3c4c6efeb5c9b50878bf537ebc140222099753` |
| `usr/share/backgrounds/ombra/ombra-grub.png` | `c6debdeebb988f3cfbb3f93deadc26866d21aba2b9e15f4a42e7e3518ef3098b` |
| `usr/share/wallpapers/Colloid-dark/contents/images/3840x2160.png` (the default wallpaper package, named for the theme it replaces) | `b1b118c8b0e346217de39ece4919f6285de1ce2b598e1eada12fdb8b79e9e0a3` |

The 4K PNGs are derived from first-party source images that are not shipped in the repository.

## Tor Browser icon

`usr/local/share/icons/hicolor/128x128/apps/tor-browser.png` (sha256
`1dac790ea6437642d06d5555dd636c286ab2fec3dc524b8bf08ad0f7fc2b7d3b`) is
derived from the icon shipped inside the pinned Tor Browser bundle; it
carries the Tor Project's licensing for that artwork (upstream: the
browser's MPL-2.0 distribution; "Tor" and the onion logo are Tor Project
trademarks, used here only to identify the unmodified Tor Browser
launcher). The 48x48 icon the installer copies out of the bundle is the
upstream file itself.

## Terminus font license

The embedded `Uni2-Terminus16.psf` is covered by the SIL Open Font
License 1.1; the full text ships beside this file as
`Terminus-OFL-1.1.txt`.

## SDDM theme source headers

The vendored `sddm/themes/Colloid-dark/*.qml` files are KDE sources
carrying `SPDX-License-Identifier: LGPL-2.0-or-later` (copyright:
Aleix Pol Gonzalez, David Edmundson, Boudhayan Gupta, as stamped in each
file). They are kept verbatim; the theme as a whole remains GPL-3.0 via
Colloid-kde, which is compatible with LGPL-2.0-or-later components.

## Boot-screen pixel assets (core/assets)

The framebuffer face of the unlock and first-boot screens embeds three
files, compiled into the binaries:

| File | Derived from | sha256 |
|---|---|---|
| `OmbraUI-Regular.ttf` | JetBrains Mono Nerd Font `v3.5.1` Regular (row above), subset with fonttools `pyftsubset` to U+0020-007E, U+00A0-017F, U+2010-2026, U+2190-2193, U+25CF, U+2588; hinting and layout features dropped | `9747938fc878e21da6551a9fcae106810e9837e709a5b80cef35c8253436142d` |
| `OmbraUI-Bold.ttf` | the same, Bold | `1f02516548f321896121266892d3eb3a405b2557a862ef8863174a113a2acc26` |
| `logo-alpha.a8` | `ombra-logo.svg` of the project site rendered at 640 px tall (630x640), alpha channel only, 8-bit raw | `2340eb181f1dc2bdd75f3aa20e9848d4a6acefa8bc3b7b8dd432e5a2baadb9a7` |

License: SIL OFL 1.1 for the font subsets (`OFL.txt` beside the full
fonts); the logo is the project's own mark.
