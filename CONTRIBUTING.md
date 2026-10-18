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
| Supply chain | Nothing fetches at install, boot or runtime; vendored assets record source, tag, hash and license |
| Privacy | No telemetry; no exit IP on any screen or log |
| Surfaces | No version numbers on human-facing output |
| Comments | One line at most, and only for a constraint the code cannot express |

## Checks

```sh
cd core && cargo test
python3 tests/build/late-command-walker.py
bash tests/build/test-install-iso.sh
bash tests/build/test-public-hygiene.sh
```

After changing Rust code, run `core/build.sh` and copy the binaries into the
overlays as shown in [docs/INSTALL.md](docs/INSTALL.md); the ISO build fails
if they differ.

## Pull requests

| Item | Detail |
|---|---|
| Commits | Say what changed and why |
| License | Contributions are licensed GPL-3.0-or-later |
