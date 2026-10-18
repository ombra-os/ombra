## Change

## Why

## Checks

- [ ] `cd core && cargo test` passes with no warnings
- [ ] `python3 tests/build/late-command-walker.py` passes
- [ ] `bash tests/build/test-install-iso.sh` passes
- [ ] No new network fetch at install, boot or runtime
- [ ] No exit IP, telemetry or version string on a human surface
- [ ] New vendored assets have source, tag, hash and license recorded
