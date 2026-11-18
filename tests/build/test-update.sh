#!/bin/bash
# Signing tooling and updater static checks: keygen, bundle, index, signature round trip, tamper detection.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "== updater =="
export OMBRA_KEY_PASS=test-only-pass
bash "$REPO/scripts/update/keygen.sh" "$T/k" >/dev/null 2>&1 && [ -s "$T/k/update-pubkey.pem" ] && ok "keygen writes a key pair" || bad "keygen"
bash "$REPO/scripts/update/keygen.sh" "$T/k" >/dev/null 2>&1 && bad "keygen overwrote an existing key" || ok "keygen refuses to overwrite a key"
mkdir -p "$T/payload/usr/local/share" && echo hello > "$T/payload/usr/local/share/ombra-test"
B=$(bash "$REPO/scripts/update/make-bundle.sh" desktop 9.9 1.1 "$T/payload" "$T/out" "$T/k/update-signing.key" 2>/dev/null | head -1)
[ -n "$B" ] && [ -f "$B" ] && ok "bundle built" || { bad "bundle build"; echo "FAILED: no bundle, the remaining checks cannot run (which openssl: $(command -v openssl))"; exit 1; }
bash "$REPO/scripts/update/make-index.sh" "$T/k/update-signing.key" "$T/idx" 30 "desktop=$B" >/dev/null 2>&1 && ok "index built and signed" || bad "index"
verify() { openssl pkeyutl -verify -pubin -inkey "$T/k/update-pubkey.pem" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1; }
verify "$T/idx/latest.txt" "$T/idx/latest.txt.sig" && ok "index signature verifies" || bad "index signature"
mkdir -p "$T/x" && tar -xf "$B" -C "$T/x" </dev/null
verify "$T/x/manifest" "$T/x/manifest.sig" && ok "manifest signature verifies" || bad "manifest signature"
[ "$(shasum -a 256 "$T/x/payload.tar.gz" | cut -d' ' -f1)" = "$(awk -F= '$1=="payload-sha256"{print $2}' "$T/x/manifest")" ] && ok "payload hash is in the manifest" || bad "payload hash"
sed -i.bak 's/9.9/9.8/' "$T/idx/latest.txt" && ! verify "$T/idx/latest.txt" "$T/idx/latest.txt.sig" && ok "a tampered index fails verification" || bad "tampered index verified"
bash "$REPO/scripts/update/keygen.sh" "$T/other" >/dev/null 2>&1
openssl pkeyutl -verify -pubin -inkey "$T/other/update-pubkey.pem" -rawin -in "$T/x/manifest" -sigfile "$T/x/manifest.sig" >/dev/null 2>&1 \
  && bad "a different key verified the manifest" || ok "another key cannot verify the manifest"
sh -n "$REPO/update/rootfs/usr/local/sbin/ombra-update" && ok "ombra-update parses" || bad "ombra-update syntax"
openssl pkey -pubin -in "$REPO/build/update-pubkey.pem" -noout 2>/dev/null && ok "the release public key is present and valid" || bad "release public key"
grep -q 'PRIVATE' "$REPO/build/update-pubkey.pem" && bad "build/update-pubkey.pem holds a private key" || ok "no private key in the tree"
for f in role; do for r in desktop gateway; do [ -s "$REPO/$r/rootfs/etc/ombra/$f" ] || bad "$r role file missing"; done; done; ok "role files present"
grep -q "ombra-update-check.timer" "$REPO/desktop/late-command.sh" && grep -q "ombra-update-check.timer" "$REPO/gateway/late-command.sh" && ok "both machines enable the update timers" || bad "update timers not enabled"
grep -q 'guided_size string 88%' "$REPO/desktop/preseed.cfg" && ok "the desktop root volume leaves room for a rollback snapshot" || bad "no free space reserved for a snapshot"
grep -q "ENCRYPTED" "$T/k/update-signing.key" && ok "the private key is passphrase-protected" || bad "private key is not encrypted"
! grep -qE ' 0 0 -1( |$)' "$REPO/desktop/rootfs/usr/local/bin/ombra-update-notify" && ok "the notification passes no negative timeout, which busctl reads as a flag" || bad "notify passes -1, which busctl reads as a flag"
grep -q 'background_opacity' "$REPO/desktop/rootfs/usr/local/share/applications/ombra-update.desktop" && bad "the update window overrides kitty's opacity, which renders it black" || ok "the update window uses the normal terminal look"
grep -qE 'default "Update Ombra" 0 0' "$REPO/desktop/rootfs/usr/local/bin/ombra-update-notify" && ok "the update notification stays until dismissed (KDE keeps it in its history)" || bad "the update notification expires on its own"
grep -q 'shownItems org.kde.plasma.notifications' "$REPO/desktop/rootfs/usr/local/bin/ombra-led-ensure" && ok "the Notifications bell is pinned visible in the tray" || bad "the bell is not pinned in the tray"
grep -q 'updateSource' "$REPO/desktop/rootfs/usr/share/plasma/plasmoids/org.ombra.status/contents/ui/main.qml" && grep -q '1080' "$REPO/desktop/rootfs/usr/local/bin/ombra-update-notify" && ok "the dot's tooltip names an available update and the notice repeats every six hours" || bad "no tooltip or repeat for a pending update"
G="$REPO/desktop/rootfs/usr/local/bin/ombra-update-gui"; D="$REPO/desktop/rootfs/usr/local/share/applications/ombra-update.desktop"
sh -n "$G" && grep -q 'kdialog' "$G" && grep -q '^Exec=/usr/local/bin/ombra-update-gui$' "$D" && grep -q 'Undo' "$D" && ok "Update Ombra uses native dialogs with an Undo action, not a terminal" || bad "Update Ombra is not the dialog front end"
grep -q 'ombra-update-gui' "$REPO/desktop/late-command.sh" && ok "the dialog front end is made executable at install" || bad "ombra-update-gui is not chmod'ed at install"
N="$REPO/desktop/rootfs/usr/local/bin/ombra-update-notify"
grep -q 'ActionInvoked' "$N" && grep -q 'ombra-update-gui' "$N" && grep -q '"default"' "$N" && ok "clicking the update notice opens Update Ombra" || bad "the notice is not clickable"
grep -q 'ombra-update-notify.pid' "$N" && grep -q 'kill -0' "$N" && ok "only one notice watcher runs per session" || bad "a second watcher can start and double the notice"
grep -q '"$prev"' "$N" && ok "a repeated notice replaces the old one instead of stacking" || bad "repeats stack new notices"
for f in scripts/update/sign-sums.sh scripts/update/verify-sums.sh scripts/upload-r2.sh; do bash -n "$REPO/$f" || bad "$f syntax"; done
# Debian updates are user-started only, and the editions get their own bundles
UPD="$REPO/update/rootfs/usr/local/sbin/ombra-update"
! grep -rq 'security' "$REPO/update/rootfs/etc/systemd/system" && ok "no unit runs ombra-update security (Debian is only contacted when the user asks)" || bad "a unit runs ombra-update security"
H="$REPO/update/rootfs/etc/ombra/update-hold"
[ -f "$H" ] && ! grep -v '^#' "$H" | grep -q '[^[:space:]]' && ok "the hold list ships, holding nothing" || bad "update-hold missing or not empty"
! grep -qiE 'allow-unauthenticated|AllowInsecureRepositories|AllowUnauthenticated|AllowDowngradeToInsecure' "$UPD" && ok "ombra-update never relaxes apt's signature checks" || bad "ombra-update relaxes apt signature checks"
grep -q 'pkexec "$U" security' "$G" && grep -q '"$U" info' "$G" && grep -q 'Check Debian security updates' "$G" && ok "Update Ombra offers Debian security updates and reads the disk layout from ombra-update info" || bad "Update Ombra lacks the security action or info"
P="$REPO/desktop/rootfs/usr/share/polkit-1/actions/org.ombra.update.policy"
grep -q 'exec.path">/usr/local/sbin/ombra-update<' "$P" && ! grep -q 'exec.argv' "$P" && ok "the polkit action allows every ombra-update subcommand (no argument pinning)" || bad "the polkit action pins arguments: security may be refused"
mkdir -p "$T/single/var/lib/ombra" "$T/single/usr/share/ombra"; echo img > "$T/single/var/lib/ombra/gateway.img"
(cd "$T/single/var/lib/ombra" && shasum -a 256 gateway.img) > "$T/single/usr/share/ombra/gateway.img.sha256"
SB=$(bash "$REPO/scripts/update/make-bundle.sh" single 9.9 1.1 "$T/single" "$T/out" "$T/k/update-signing.key" 2>/dev/null | head -1)
[ -f "$SB" ] && tar -xOf "$SB" manifest | grep -qx role=single && ok "make-bundle builds a single-edition bundle" || bad "make-bundle single"
bash "$REPO/scripts/update/make-bundle.sh" desktop 9.9 1.1 "$T/single" "$T/out2" "$T/k/update-signing.key" >/dev/null 2>&1 && bad "make-bundle put the gateway image in a two-VM desktop bundle" || ok "only single bundles may carry the gateway image"
echo other > "$T/single/var/lib/ombra/gateway.img"
bash "$REPO/scripts/update/make-bundle.sh" single 9.9 1.1 "$T/single" "$T/out3" "$T/k/update-signing.key" >/dev/null 2>&1 && bad "make-bundle accepted a gateway image that does not match its checksum" || ok "make-bundle refuses a gateway image that does not match its checksum"
bash "$REPO/scripts/update/make-index.sh" "$T/k/update-signing.key" "$T/idx2" 30 "single=$SB" "desktop=$B" >/dev/null 2>&1 && grep -q '^single.version=9.9$' "$T/idx2/latest.txt" && ok "make-index accepts role single" || bad "make-index single"
bash "$REPO/scripts/update/make-index.sh" "$T/k/update-signing.key" "$T/idx3" 30 "desktop=$SB" >/dev/null 2>&1 && bad "make-index listed a single bundle as desktop" || ok "make-index refuses a bundle under another role"
for f in "$UPD" "$G" "$N" "$REPO/scripts/update/post-runner.sh"; do sh -n "$f" && { ! command -v dash >/dev/null || dash -n "$f"; } || bad "$f does not parse as POSIX sh"; done
bash "$REPO/tests/build/test-update-logic.sh" > "$T/logic.out" 2>&1 && ok "the updater logic suite passes (tests/build/test-update-logic.sh)" || { bad "updater logic suite"; grep FAIL "$T/logic.out"; }
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
