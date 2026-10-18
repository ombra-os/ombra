# Security Policy

Read the [threat model](docs/THREAT_MODEL.md) first. Behavior it lists as
out of scope is not a vulnerability.

## Supported releases

| Release | Supported |
|---|---|
| Latest tag | Yes |
| Earlier tags | No: no fixes, and their images are not kept |

## Reporting

Use **GitHub Security Advisories**: the repository's Security tab, then
"Report a vulnerability". Do not open a public issue.

Include:

| Item | Detail |
|---|---|
| Version | Release tag or commit |
| Component | Gateway VM, desktop VM, installer, build tooling or `core/` binaries |
| Impact | What an attacker gains, and the preconditions |
| Reproduction | Steps or a proof of concept |
| Leak evidence | What leaves the guest and where it goes, identifying details redacted |

## Process

| Step | What happens |
|---|---|
| 1 | Acknowledgment, then a verdict on scope |
| 2 | Fix developed privately |
| 3 | Coordinated disclosure after a reasonable window; credit at your preference |

## Out of scope

| Item | Reason |
|---|---|
| Compromised macOS host | Defeats the guests entirely; documented and by design |
| Public build passphrase (`ombra-disk`) on a fresh image | Published by design; it only opens a machine that has not been set up. A copy of an image taken before first boot opens with it and the original volume key. Failures of the first-use flow that replaces them are in scope |
| Accounts | Born locked (`*`) on both machines; no public login credential exists. First use sets the desktop user's password |
| Unlimited unlock attempts at the console | Each guess costs argon2id time; accepted under the physical-attacker model |
| Fixed argon2id parameters (1 GiB, 4 iterations, 2 threads) | Not benchmarked, so first-use setup stays bounded in a VM |
