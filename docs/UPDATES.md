# Updates

Ombra updates itself in place. Nothing is applied until you start it. Debian's security updates are separate and are only fetched when you ask.

## For users

| Step | What happens |
|---|---|
| Notice | About three minutes after boot, then once a day, each machine fetches one small signed file through Tor. If a newer version exists, the desktop shows a notification and the gateway report shows an Update line |
| Tor notice | The gateway also checks, at boot and daily, whether Debian has a newer Tor than the one installed, and the desktop shows a notice. To install it: at the gateway console, in Persistent mode, `sudo ombra-update security --no-rollback` |
| Start | Desktop: open **Update Ombra** from the menu and enter your password. Gateway: `sudo ombra-update apply` at the console |
| Mode | Updates need Persistent mode. In Amnesic mode the command refuses and says why |
| Verify | The bundle is checked against an Ed25519 signature, its signed manifest and its hash before anything is written |
| Safety net | The desktop takes an LVM snapshot of the whole root volume first, plus copies of `/boot` and the EFI partition (their own partitions, outside the snapshot); the gateway keeps copies of the files the update replaces |
| Finish | Restart. A rollback stays available for ten minutes after the next boot, then it is dropped. It is never dropped in the boot the update ran in, in an Amnesic boot, or after an update that did not finish |
| Undo | `pkexec ombra-update rollback` on the desktop (restart twice before updating again), `sudo ombra-update rollback` on the gateway |

Debian security updates:

| Step | What happens |
|---|---|
| Start | Desktop: **Update Ombra** → **Check Debian security updates** (offered when Ombra itself is up to date), or `pkexec ombra-update security`. Gateway: `sudo ombra-update security --no-rollback` |
| When | Only when you start it. The daily check never contacts Debian |
| Network | `apt-get` through Tor (desktop: the gateway's SOCKS port; gateway: its own). Debian's archive signatures are checked as usual |
| Refused | Amnesic mode; another update waiting for its commit; a plan that would remove a package or touch a package in `/etc/ombra/update-hold`; on the desktop, more than 600 MB to download. Nothing is changed |
| Safety net | Desktop: the same rollback point as an Ombra update; undo it the same way, until ten minutes after the next restart. Gateway: **none**: package upgrades cannot be undone there, hence `--no-rollback` |
| Restart | Asked for when a kernel, initramfs, libc, systemd, udev, OpenSSL or Tor package changed, or `/run/reboot-required` exists. Otherwise programs pick the fixes up when reopened |
| Afterwards | Package lists and downloaded packages are deleted again; images ship without them. Ombra updates wait until the rollback point is committed |
| Scope | The packages of the machine it runs on |

App updates:

| Step | What happens |
|---|---|
| What | Tor Browser, Feather, SimpleX and Electrum, the apps Debian does not ship or ships too old. Each comes from its own project, so a fix does not wait for an Ombra release |
| Notice | The same check that looks for Ombra updates fetches a small signed app list (`updates/apps.txt`). When a listed version is newer than the installed one and Ombra itself is up to date, the desktop shows a notice (an Ombra update comes first) |
| Start | Update Ombra → **Update apps**, or `pkexec ombra-update apps apply` |
| Verify | The app list is signed with Ombra's key and names each file's sha256 and size; the maintainer checks the project's own signature before listing a version. A download that does not match is discarded |
| Network | Downloads go through Tor, from the project's own site (Tor Project, GitHub releases, electrum.org) |
| Install | Tor Browser, Feather and Electrum are unpacked next to the old copy in `/opt` and swapped in only when complete; a swap cut off by a power loss is finished or undone at the next check. SimpleX is a Debian package installed with dpkg, refused if it would change any other package. An app that is open is left for later; one that fails keeps working at its previous version. No restart, no rollback point of its own; within ten minutes of an Ombra update's restart, undoing that update also takes `/opt` (apps and Tor Browser's profile) back, and app updates wait while that rollback point is more than half full |
| Your data | Profiles, bookmarks, wallets and chats stay where they are: Tor Browser's profile moves into the new browser unchanged |
| Electrum | Runs the electrum.org release from `/opt/electrum` on Debian's Python, Qt 6, cryptography and libsecp256k1; missing ones are installed in place from Debian through Tor the first time (refused if that would remove a package) |
| Mode | Persistent mode only |

What an update does to your data:

| Machine | Update | Undo (rollback) |
|---|---|---|
| Desktop | Does not change your files | Returns the system to the moment before the update; the home folder is on its own volume and is not affected |
| Desktop, failed update | The update undoes itself at the next restart | Not needed |
| Gateway | Replaces system files only | Restores the files the update replaced and removes the ones it added. Changes made by bundled Debian packages (`dpkg -i`) and by `security` are not undone |

What Update Ombra and `ombra-update check` report:

| State | Meaning |
|---|---|
| `available <version>` | A newer signed version exists |
| `current` | Up to date |
| `applied <version>` | Installed; restart to finish |
| `applied-security [restart]` | Debian updates installed by `security`; `restart` on the second line when a restart is needed |
| `invalid` | The index failed its signature check: the server or the connection may be tampered with. Nothing was installed. The desktop warns in a notice, in the tray dot's tooltip and in Update Ombra |
| `stale` | The index has expired, carries no valid expiry, or is older than one this machine already saw. Treated as no answer; `apply` refuses |
| `no-index` | The server answered but publishes no index. Could not check |
| `unreachable` | No answer through Tor. Could not check |

## For the maintainer

| Item | Detail |
|---|---|
| Check schedule | `ombra-update-check.timer`: 3 min after boot (plus up to 2 min random delay), then 1 day after the last run. When the server cannot be reached (exit 75) the service retries every 2 min, at most 8 starts per hour; a bad signature or a usage error (exit 1, 2) is not retried |
| Index fields | `issued` (signing time), `expires`, and per role `<role>.version`, `.bundle`, `.sha256`, `.size`. Written by `make-index.sh` |
| Roles | `desktop` and `gateway`, read from `/etc/ombra/role`. `/etc/ombra/edition` is `two-vm` (missing means the same); the updater refuses any other value with exit 2 in every mode |
| `info` | `ombra-update info` (no root): `edition=`, `role=`, `update_role=`, `version=`, `mode=persistent\|amnesic`, `home_on_root=yes\|no`. Update Ombra uses it for its undo warnings |
| `/boot` and ESP copies | On the desktop, right after the snapshot, `apply` and `security` tar `/boot` and `/boot/efi` (each only when it is its own mount; the ESP gets its own copy) into `/var/lib/ombra-update/`. Needs their size plus 256 MB free. `rollback` restores them in place first (removing files the update added), then schedules the merge; `commit` deletes them |
| Debian updates | `ombra-update security`: `apt-get update --error-on=any`, then a simulated `--with-new-pkgs upgrade` as the plan; refused if it removes anything, touches `/etc/ombra/update-hold`, or (desktop) downloads more than 600 MB (the 3 GB snapshot must hold the unpacked result). Then `apt-get -y --with-new-pkgs upgrade` with `--force-confold --force-confdef`, `DEBIAN_FRONTEND=noninteractive`. The proxy, retries and timeouts are passed with `-o`; nothing is written to `/etc/apt`. On the desktop the snapshot is taken before the lists are downloaded, so an undo leaves none behind. If the upgrade overflows the snapshot, the run says it cannot be undone and drops it. The gateway first finishes an interrupted dpkg run (`dpkg --configure -a`) if `dpkg --audit` reports one |
| Hold list | `/etc/ombra/update-hold`, one package name per line, `#` comments. Ships empty. A held package blocks the whole run, so it only changes through an Ombra release |
| Index expiry | `check` and `apply` treat a missing, non-numeric or past `expires` as expired (`stale`) |
| Replay | Each machine stores the highest `issued` it accepted in `/var/lib/ombra-update/issued` and refuses a lower one, or one without `issued` once it has stored one. Amnesic boots keep this in RAM only |
| Size limits | The index and its signature are capped at 64 KB. With `<role>.size`, the bundle download is capped at that size and `apply` needs twice that (bundle plus unpacked payload) plus 1 GB free before downloading; without it, 1 GB. `security` needs 1 GB plus three times the download |
| Exit codes | `0` ok (for `security`, also nothing pending); `1` failed or refused, nothing changed; `2` usage, unknown role or edition; `3` `apply` or `security` failed and was rolled back (desktop: at the next restart); `4` failed and could not be rolled back (always the case for a failed `security` on the gateway); `75` `check` could not reach the update server, or `security` could not reach Debian |
| Locking | `apply`, `security`, `rollback` and `commit` take `/run/ombra-update.lock`; a second one refuses, and a timer-run `commit` exits 0 quietly |
| Commit | `ombra-update-commit.timer` runs `commit` 10 min after boot. It commits only in a Persistent boot later than the one the update ran in (`pending` holds that boot's id), and never while `applying` exists (the apply did not finish: run `rollback`) |
| Security releases | Ombra turns off Tor Browser's updater and no user can run apt, so browser fixes reach users only as Ombra updates, and Debian fixes only as Ombra updates or a user-started `security` run. Ship an Ombra update for every Tor Browser release on the stable channel and for Debian security advisories that touch the image (`/usr/share/ombra/packages.txt` lists every package and version), and for any held package |
| Tor Browser | `scripts/update/stage-torbrowser.sh <payload-dir> <tarball> <sha256>` adds a new pinned build; on apply it replaces `/opt/tor-browser` and keeps the profile and policies. The step refuses while Tor Browser runs (Update Ombra asks the user to close it first) and can be rerun after an interruption without losing the profile. Also bump `build/pins/torbrowser.txt` for the next image |
| Debian packages | `scripts/update/stage-debs.sh <payload-dir> <file.deb>...` adds packages fetched with `apt-get download` on a trixie arm64 machine. On apply, an offline pre-flight (`apt-get -s`) must plan to install only the bundled packages; otherwise the step fails before dpkg unpacks anything. On the gateway, a `dpkg -i` failure after that point is not undone by a rollback |
| Post steps | The stagers write `post.sh` (`scripts/update/post-runner.sh`), which runs every file in `usr/local/lib/ombra-update/post.d` in name order; any failure rolls the update back (exit 3). |
| Signing key | Ed25519. `scripts/update/keygen.sh <dir>` creates it once. The private key signs every release and never leaves you; losing it means no installed machine can accept an update again, leaking it means anyone can update every machine. Only `build/update-pubkey.pem` ships |
| Payload | A tree of files that overlay `/` on the target, plus an optional `usr/local/lib/ombra-update/post.sh` that runs once after the files land |
| Bundle | `scripts/update/make-bundle.sh <desktop\|gateway> <version> <min-from> <payload-dir> <out-dir> <private-key>` writes `ombra-<role>-<version>.update` (signed manifest, signature, payload) |
| Index | `scripts/update/make-index.sh <private-key> <out-dir> <valid-days> desktop=<bundle> gateway=<bundle>` writes `latest.txt` and `latest.txt.sig`. The index expires, so a frozen mirror cannot hold machines back forever |
| App list | Pin the new version in `build/pins/<app>.txt` after checking the project's signature, put the file in `build/vendor/`, then `scripts/update/make-apps.sh <out-dir> <valid-days> [private-key]` writes `apps.txt` (and `apps.txt.sig` with a key). Publish it with the update files (the app list alone is enough for an app-only release). It carries `type=apps` and the index `type=index`, so one cannot stand in for the other; each has its own `issued` floor and an `expires` the desktop requires |
| Desktop bundles | `scripts/update/payload-desktop-from-1.2.sh <payload-dir> [ref]` builds one cumulative payload for every 1.2 desktop: the changed files, a post step that enables the new units, and a rebuilt initramfs (the disk-unlock agent lives in it), checked to carry the new agent. A failed step undoes the update. Applications are not in it |
| Gateway bundles | `scripts/update/payload-gateway-from-1.2.sh <payload-dir> <apparmor_*_arm64.deb> [ref]` builds one cumulative payload for every 1.2 gateway: the changed files, Debian's `apparmor` package (Tor's unit requires its profile), and a post step that checks the new torrc, firewall and dnsmasq files parse, loads Tor's profile and enables the new units. If the profile does not load the update is undone. Fetch the package on a trixie arm64 machine with `apt-get download apparmor` |
| Tor version notice | Each gateway asks Debian through Tor, at boot and daily, whether a newer `tor` exists, and the desktop shows a notice until it is installed. Users install it themselves: `sudo ombra-update security --no-rollback` on the gateway, in Persistent mode |
| Publish updates | Bundles, `latest.txt` and `latest.txt.sig` (and `apps.txt` with `apps.txt.sig`). The upload checks each signature and every bundle the index names, then uploads the bundles before the index |
| Release images | After the last export: `bash scripts/update/sign-sums.sh <private-key> build/releases/SHA256SUMS.txt` writes `SHA256SUMS.txt.sig`. The upload refuses the archives unless `SHA256SUMS.txt` and its `.sig` are present, the signature verifies and every archive matches its line. Every export rewrites `SHA256SUMS.txt`, so sign again after it |
| Verify a download | `bash scripts/update/verify-sums.sh update-pubkey.pem SHA256SUMS.txt`. Needs OpenSSL 3; macOS's own `/usr/bin/openssl` (LibreSSL) cannot read Ed25519 keys (`brew install openssl@3`) |
| Version files | `apply` and a gateway `rollback` set `/etc/ombra/version`, `VERSION_ID` in `/usr/lib/os-release` and `DISTRIB_RELEASE` in `/etc/lsb-release` together |
| Compatibility | `min-from` names the oldest version the bundle applies to |
| Limits | An update cannot change the disk layout or the boot menu. Those need a new image |

## Privacy and trust

| Topic | Detail |
|---|---|
| Network | Every fetch goes through Tor. The server sees a Tor exit asking for a public file |
| Frequency | One small index request about three minutes after boot and once a day while running, plus retries every 2 min (at most 8 an hour) while the server is unreachable. The download happens only when you run Update. Debian's mirrors are contacted only when you start `security` |
| Trust root | The public key in the image. A compromised download host can withhold updates but cannot forge one. An expired or older index shows as `stale`, a missing one as `no-index`; re-serving the current index unchanged goes unnoticed until it expires, so keep `valid-days` short |
| Not covered | A machine that never updates keeps its bugs; the check only tells you |
