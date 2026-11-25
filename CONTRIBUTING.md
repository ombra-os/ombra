# Contributing

## Before you start

| Topic | Rule |
|---|---|
| Vulnerabilities | Use the Security tab; see [SECURITY.md](SECURITY.md) |
| Scope | Read the [design](docs/DESIGN.md) and the [threat model](docs/THREAT_MODEL.md) first |
| Discussion | Open an issue before large changes |

## Rules the project enforces

| Rule | Detail |
|---|---|
| Boot chain | The unlock and first-use flow is security-critical; keep changes small and tested |
| Supply chain | Release images download no software at install or boot; runtime requests are limited to the list in the [threat model](docs/THREAT_MODEL.md#designed-runtime-probes); vendored assets record source, tag, hash and license; pinned downloads carry a sha256 in `build/pins/` |
| Privacy | No telemetry; no exit IP on any screen or log |
| Surfaces | No version numbers on human-facing output |
| Comments | One line at most, and only for a constraint the code cannot express |

## Checks

```sh
cd core && cargo test
python3 tests/build/late-command-walker.py
bash tests/build/test-install-iso.sh
bash tests/build/test-public-hygiene.sh
bash tests/build/test-update.sh
bash tests/build/test-update-logic.sh
bash tests/build/test-crypttab-wiring.sh
bash tests/build/test-verify-iso.sh
bash tests/build/test-utm-verify.sh
bash core/verify-dist.sh
```

| Script | Checks | Needs |
|---|---|---|
| `late-command-walker.py` | Installer scripts for parse errors `bash -n` misses | `python3` |
| `test-install-iso.sh` | ISO builder for gateway and desktop | `xorriso` and the pinned netinst in `build/isos/` |
| `test-public-hygiene.sh` | Tracked files for personal leaks and internal naming | |
| `test-update.sh` | Update signing tooling and updater static checks | |
| `test-update-logic.sh` | The real `ombra-update` against a fake root, with stubbed system tools | |
| `test-crypttab-wiring.sh` | The keyscript wiring in `desktop/late-command.sh` | |
| `test-verify-iso.sh` | `build/verify-iso.sh` | |
| `test-utm-verify.sh` | The UTM bundle verifier | `qemu-img` (`brew install qemu`) |
| `core/verify-dist.sh` | `core/dist/aarch64/` and the overlay copies match a fresh build of the source | The Rust toolchain and the aarch64 musl target (`core/build.sh` once) |

Building the installers:

```sh
bash build/make-install-iso.sh gateway
bash build/make-install-iso.sh desktop
```

After changing Rust code, run `core/build.sh` and copy the binaries into the
overlays as shown in [docs/INSTALL.md](docs/INSTALL.md); the ISO build fails
if an overlay binary differs from `core/dist/aarch64/`.
`core/verify-dist.sh` checks that `core/dist/aarch64/` matches the source.

## Pull requests

| Item | Detail |
|---|---|
| Commits | Say what changed and why |
| License | Contributions are licensed GPL-3.0-or-later |
