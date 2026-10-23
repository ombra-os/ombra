# Updates

Ombra updates itself in place. Nothing is applied until you start it.

## For users

| Step | What happens |
|---|---|
| Notice | A few minutes after boot, and daily, each machine fetches one small signed file through Tor. If a newer version exists, the desktop shows a notification and the gateway report shows an Update line |
| Start | Desktop: open **Update Ombra** from the menu and enter your password. Gateway: `sudo ombra-update apply` at the console |
| Mode | Updates need Persistent mode. In Amnesic mode the command refuses and says why |
| Verify | The bundle is checked against an Ed25519 signature, its signed manifest and its hash before anything is written |
| Safety net | The desktop takes an LVM snapshot of the root volume first; the gateway keeps copies of the files it replaces |
| Finish | Restart. A rollback stays available for ten minutes after the next boot, then it is dropped |
| Undo | `pkexec ombra-update rollback` on the desktop (restart twice before updating again), `sudo ombra-update rollback` on the gateway |

Your home folder, keys, wallets and chats are never touched by an update.

## For the maintainer

| Item | Detail |
|---|---|
| Signing key | Ed25519. `scripts/update/keygen.sh <dir>` creates it once. The private key signs every release and never leaves you; losing it means no installed machine can accept an update again, leaking it means anyone can update every machine. Only `build/update-pubkey.pem` ships |
| Payload | A tree of files that overlay `/` on the target, plus an optional `usr/local/lib/ombra-update/post.sh` that runs once after the files land |
| Bundle | `scripts/update/make-bundle.sh <role> <version> <min-from> <payload-dir> <out-dir> <private-key>` writes `ombra-<role>-<version>.update` (signed manifest, signature, payload) |
| Index | `scripts/update/make-index.sh <private-key> <out-dir> <valid-days> desktop=<bundle> gateway=<bundle>` writes `latest.txt` and `latest.txt.sig`. The index expires, so a frozen mirror cannot hold machines back forever |
| Publish | Upload `latest.txt`, `latest.txt.sig` and the bundles to `updates/` next to the release downloads. Nothing else is needed: the machines read plain files |
| Compatibility | `min-from` names the oldest version the bundle applies to. Test every release as an upgrade from the previous one, not only as a fresh install |
| Limits | An update cannot change the disk layout or the boot menu. Those need a new image |

## Privacy and trust

| Topic | Detail |
|---|---|
| Network | Every fetch goes through Tor. The server sees a Tor exit asking for a public file |
| Frequency | One small index request a few minutes after boot and once a day while running. The download happens only when you run Update |
| Trust root | The public key in the image. A compromised download host can withhold updates but cannot forge one |
| Not covered | A machine that never updates keeps its bugs; the check only tells you |
