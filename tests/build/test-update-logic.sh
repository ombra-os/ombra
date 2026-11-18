#!/bin/bash
# Runs the real ombra-update against a fake root on the build Mac: its fixed paths are rewritten into a temp dir,
# system tools (curl, lvm, dpkg, findmnt, flock, GNU-only flags of tar/sed/stat) are stubbed first in PATH, and a
# throwaway Ed25519 key signs fixture indexes and bundles. Read-only with respect to the repo.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== updater logic =="
OSSL=""
for c in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl; do
    [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 || continue
    "$c" genpkey -algorithm ed25519 -out "$T/probe.key" >/dev/null 2>&1 && "$c" pkey -in "$T/probe.key" -pubout -out "$T/probe.pub" 2>/dev/null \
        && echo x > "$T/probe" && "$c" pkeyutl -sign -inkey "$T/probe.key" -rawin -in "$T/probe" -out "$T/probe.sig" 2>/dev/null \
        && "$c" pkeyutl -verify -pubin -inkey "$T/probe.pub" -rawin -in "$T/probe" -sigfile "$T/probe.sig" >/dev/null 2>&1 \
        && { OSSL=$(command -v "$c"); break; }
done
if [ -z "$OSSL" ]; then
    echo "  SKIP no openssl here can sign/verify raw Ed25519 (macOS's LibreSSL cannot): brew install openssl@3"
    exit 0
fi
SHELL_UNDER_TEST=sh; command -v dash >/dev/null 2>&1 && SHELL_UNDER_TEST=dash

# ---- stubs ----
S="$T/stub"; mkdir -p "$S" "$T/ossl"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$OSSL" > "$T/ossl/openssl"; cp "$T/ossl/openssl" "$S/openssl"
cat > "$S/curl" <<'EOF'
#!/bin/bash
# serves $SRV for https://upd.test/; logs every call
out=""; max=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -w|--proto|--proto-redir|--max-redirs|--socks5-hostname|--connect-timeout|--max-time) shift ;; --max-filesize) max=$2; shift ;; -*) ;; *) url=$1 ;; esac; shift; done
echo "max=${max:-none} $url" >> "$CURL_LOG"
[ -z "${FAKE_CURL_FAIL:-}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
f="$SRV/${url#https://upd.test/}"
[ -f "$f" ] || { printf 404; exit 0; }
if [ -n "$max" ] && [ "$(wc -c < "$f")" -gt "$max" ]; then echo "curl: (63) Maximum file size exceeded" >&2; exit 63; fi
cp "$f" "$out"; printf 200
EOF
cat > "$S/dpkg" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/bin
case "$1" in
    --audit) printf '%s' "${FAKE_DPKG_AUDIT:-}"; exit 0 ;;
    --force-confold) echo "dpkg $*" >> "$APT_LOG"; exit 0 ;;
esac
[ "$1" = --compare-versions ] || exit 2
[ "$2" = "$4" ] && { case "$3" in ge|le|eq) exit 0 ;; *) exit 1 ;; esac; }
hi=$(printf '%s\n%s\n' "$2" "$4" | sort -V | tail -n1)
case "$3" in gt|ge) [ "$hi" = "$2" ] ;; lt|le) [ "$hi" = "$4" ] ;; *) exit 1 ;; esac
EOF
cat > "$S/findmnt" <<'EOF'
#!/bin/sh
case "$*" in
    *SOURCE*/home*) echo "${FAKE_HOME_SRC:-/dev/mapper/vg0-root}" ;;
    *SOURCE*) echo /dev/mapper/vg0-root ;;
    *) echo "${FAKE_FSTYPE:-ext4}" ;;
esac
EOF
cat > "$S/mountpoint" <<'EOF'
#!/bin/sh
case "$2" in
    */boot) [ -n "${FAKE_BOOT_MOUNT:-}" ] ;;
    */boot/efi) [ -n "${FAKE_EFI_MOUNT:-}" ] ;;
    *) exit 1 ;;
esac
EOF
cat > "$S/apt-get" <<'EOF'
#!/bin/sh
# Debian's mirror as seen through Tor: lists, a plan (FAKE_APT_PLAN), download sizes, and an upgrade that touches /boot
PATH=/usr/bin:/bin
echo "apt-get $*" >> "$APT_LOG"
# like apt: a local package is only taken by a path ending in .deb (anything else is looked up as a package name)
for a in "$@"; do case "$a" in /*) case "$a" in *.deb) ;; *) echo "E: Unable to locate package $a"; exit 100 ;; esac ;; esac; done
sim=""; uris=""; cmd=""
for a in "$@"; do case "$a" in -s) sim=1 ;; --print-uris) uris=1 ;; update|upgrade) cmd=$a ;; esac; done
case "$cmd" in
update)
    [ -z "${FAKE_APT_UNREACHABLE:-}" ] || { echo "Err:1 http://deb.debian.org/debian trixie InRelease"; echo "  Could not connect to 10.55.10.1:9050 (10.55.10.1). - connect (111: Connection refused)"; exit 100; }
    [ -z "${FAKE_APT_BADSIG:-}" ] || { echo "Err:1 http://deb.debian.org/debian trixie InRelease"; echo "  The following signatures were invalid: BADSIG 6ED0E7B82643E131"; exit 100; }
    mkdir -p "$R/var/lib/apt/lists/partial"; echo x > "$R/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_InRelease"; exit 0 ;;
upgrade)
    if [ -n "$sim" ]; then
        printf '%s\n' "${FAKE_APT_PLAN-Inst curl [8.14.1-2] (8.14.1-2+deb13u1 Debian-Security:13/stable-security [arm64])}" "Conf curl (8.14.1-2+deb13u1 Debian-Security:13/stable-security [arm64])"
        exit 0
    fi
    if [ -n "$uris" ]; then echo "'http://deb.debian.org/debian-security/pool/x.deb' x.deb ${FAKE_APT_BYTES:-2048000} SHA256:00"; exit 0; fi
    [ -e "$R/var/lib/ombra-update/boot.tar" ] && echo "boot-saved" >> "$APT_LOG"
    [ -e "$LV/snap" ] && echo "snap-present" >> "$APT_LOG"
    mkdir -p "$R/var/cache/apt/archives"; echo deb > "$R/var/cache/apt/archives/curl.deb"
    [ -d "$R/boot" ] && { echo new > "$R/boot/vmlinuz"; echo new > "$R/boot/vmlinuz-new"; echo new > "$R/boot/efi/EFI/debian/grubaa64.efi"; echo new > "$R/boot/efi/EFI/debian/new.efi"; }
    [ -z "${FAKE_APT_FAIL:-}" ] || { echo "E: Sub-process /usr/bin/dpkg returned an error code (1)"; exit 100; }
    echo upgraded > "$R/upgraded"; exit 0 ;;
esac
exit 0
EOF
cat > "$S/dpkg-query" <<'EOF'
#!/bin/sh
# -W -f '${Version}' <pkg>: FAKE_VER_<pkg>; -W -f '${Status}' <pkg>: installed unless named in FAKE_MISSING
eval "p=\${$#}"
case "$*" in
    *Status*) case " ${FAKE_MISSING:-} " in *" $p "*) exit 1 ;; esac
              case " ${FAKE_HALF:-} " in *" $p "*) printf 'install reinstreq half-installed'; exit 0 ;; esac
              printf 'install ok installed' ;;
    *) v=$(eval "printf '%s' \"\${FAKE_VER_$(printf '%s' "$p" | tr -c 'a-z0-9\n' _):-}\""); [ -n "$v" ] || exit 1; printf '%s' "$v" ;;
esac
EOF
printf '#!/bin/sh\n[ -z "${FAKE_RUN_FILE:-}" ] || [ ! -e "$FAKE_RUN_FILE" ] || exit 0\ncase "$*" in *"${FAKE_RUNNING:-@none@}"*) exit 0 ;; esac\nexit 1\n' > "$S/pgrep"
printf '#!/bin/sh\necho 0\n' > "$S/id"
printf '#!/bin/sh\n[ -z "${FAKE_LOCKED:-}" ]\n' > "$S/flock"
printf '#!/bin/sh\nshasum -a 256 "$@"\n' > "$S/sha256sum"
cat > "$S/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfake 99999999 1 %s 1%% /\n' "${FAKE_FREE:-99999999}"
EOF
cat > "$S/tar" <<'EOF'
#!/bin/sh
# bsdtar lacks these GNU-only flags; their behaviour does not matter for the fake root
for a in "$@"; do shift; case "$a" in --keep-directory-symlink|--no-overwrite-dir|--warning=*|--quoting-style=*) ;; *) set -- "$@" "$a" ;; esac; done
exec /usr/bin/tar "$@"
EOF
cat > "$S/sed" <<'EOF'
#!/bin/sh
[ "$1" = -i ] && { shift; exec /usr/bin/sed -i '' "$@"; }
exec /usr/bin/sed "$@"
EOF
cat > "$S/stat" <<'EOF'
#!/bin/sh
[ "$1" = -c ] && [ "$2" = %Y ] && exec /usr/bin/stat -f %m "$3"
exec /usr/bin/stat "$@"
EOF
cat > "$S/lvs" <<'EOF'
#!/bin/sh
case "$*" in *lv_attr*root-pre*) if [ -n "${FAKE_SNAP_INVALID:-}" ]; then echo "  swi-I-s---"; else echo "  swi-a-s---"; fi; exit 0 ;; esac
case "$*" in *lv_attr*) echo "  -wi-ao----"; exit 0 ;; esac
case "$*" in *root-pre*) [ -e "$LV/snap" ] ;; *) exit 0 ;; esac
EOF
printf '#!/bin/sh\ntouch "$LV/snap"\n' > "$S/lvcreate"
printf '#!/bin/sh\nrm -f "$LV/snap"\n' > "$S/lvremove"
printf '#!/bin/sh\n[ -z "${FAKE_MERGE_FAIL:-}" ] || exit 5\ntouch "$LV/merge"\n' > "$S/lvconvert"
printf '#!/bin/sh\nexit 0\n' > "$S/dmsetup"
printf '#!/bin/sh\nexit 0\n' > "$S/sync"
chmod 0755 "$S"/* "$T/ossl/openssl"

# ---- the updater, with its fixed paths moved into the fake root ----
R="$T/root"; U="$T/ombra-update"; export R
sed -e 's|/etc/|@ROOT@/etc/|g; s|/usr/|@ROOT@/usr/|g; s|/var/lib/|@ROOT@/var/lib/|g; s|/var/cache/|@ROOT@/var/cache/|g; s|/run/|@ROOT@/run/|g; s|/proc/|@ROOT@/proc/|g; s|/opt/|@ROOT@/opt/|g; s|/var/tmp/|@ROOT@/var/tmp/|g; s|^BOOTDIR=/boot$|BOOTDIR=@ROOT@/boot|' \
    -e 's|-C / |-C @ROOT@/ |g; s|"/\$f"|"@ROOT@/$f"|g; s|/\.ombra-rw-test|@ROOT@/.ombra-rw-test|g' \
    -e '1s|^#!@ROOT@|#!|' -e "s|@ROOT@|$R|g" "$REPO/update/rootfs/usr/local/sbin/ombra-update" > "$U"
grep -qE '(^|[^X])/(etc|usr|var/lib|var/cache|var/tmp|opt|run|proc)/|^BOOTDIR=/' <(sed "s|$R|@ROOTX|g" "$U" | grep -v '^ *#') && bad "a fixed path escaped the rewrite" || ok "every fixed path is inside the fake root"

# ---- keys and fixtures ----
"$OSSL" genpkey -algorithm ed25519 -out "$T/sign.key" 2>/dev/null; "$OSSL" pkey -in "$T/sign.key" -pubout -out "$T/pub.pem"
OPATH="$T/ossl:$PATH"
SRV="$T/srv"; LV="$T/lv"; CURL_LOG="$T/curl.log"; APT_LOG="$T/apt.log"
export SRV LV CURL_LOG APT_LOG
sign() { PATH="$OPATH" bash "$REPO/scripts/update/sign.sh" "$T/sign.key" "$1" >/dev/null; }
NOW=$(date +%s)

reset_root() { # role version
    chmod -R u+rwX "$R" 2>/dev/null; rm -rf "$R" "$LV" "$SRV"; mkdir -p "$R/etc/ombra" "$R/usr/share/ombra" "$R/usr/lib" "$R/proc/sys/kernel/random" "$R/var/lib" "$R/run" "$LV" "$SRV/updates"
    echo "$1" > "$R/etc/ombra/role"; echo "$2" > "$R/etc/ombra/version"
    echo "BASE_URL=https://upd.test/updates" > "$R/etc/ombra/update.conf"
    cp "$T/pub.pem" "$R/usr/share/ombra/update-pubkey.pem"
    printf 'NAME="Ombra"\nVERSION_ID=%s\n' "$2" > "$R/usr/lib/os-release"
    printf 'DISTRIB_ID="Ombra"\nDISTRIB_RELEASE="%s"\n' "$2" > "$R/etc/lsb-release"
    echo boot-one > "$R/proc/sys/kernel/random/boot_id"
    echo "btime $((NOW - 3600))" > "$R/proc/stat"
    echo "quiet" > "$R/proc/cmdline"
    : > "$CURL_LOG"; : > "$APT_LOG"
}
run() { env PATH="$S:$PATH" "$SHELL_UNDER_TEST" "$U" "$@" > "$T/out" 2>&1; RC=$?; }
state() { head -n1 "$R/run/ombra/update" 2>/dev/null; }
index() { # writes and signs latest.txt from the given lines (type=index first unless the lines name a type)
    { case "${1:-}" in type=*) ;; *) echo type=index ;; esac; printf '%s\n' "$@"; } > "$SRV/updates/latest.txt"; sign "$SRV/updates/latest.txt"
}
mkbundle() { # role version payload-dir out [payload.tar.gz to use as is]
    local d; d=$(mktemp -d "$T/b.XXXX")
    if [ -n "${5:-}" ]; then cp "$5" "$d/payload.tar.gz"; else COPYFILE_DISABLE=1 /usr/bin/tar -czf "$d/payload.tar.gz" --uid 0 --gid 0 -C "$3" .; fi
    printf 'role=%s\nversion=%s\nmin-from=1.0\npayload-sha256=%s\n' "$1" "$2" "$(shasum -a 256 "$d/payload.tar.gz" | cut -d' ' -f1)" > "$d/manifest"
    sign "$d/manifest"
    COPYFILE_DISABLE=1 /usr/bin/tar -cf "$4" -C "$d" manifest manifest.sig payload.tar.gz
}
h() { shasum -a 256 "$1" | cut -d' ' -f1; }
sz() { wc -c < "$1" | tr -d ' '; }
mkdir -p "$T/pl/usr/local/share"; echo new > "$T/pl/usr/local/share/ombra-test"

# ---- check ----
reset_root desktop 1.1
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=x.update" "desktop.sha256=00"
run check; check "a valid index reports available" '[ "$RC" = 0 ] && [ "$(state)" = available ] && [ "$(sed -n 2p "$R/run/ombra/update")" = 9.9 ]'
check "the index and its signature are fetched with a 64 KB cap" 'grep -q "max=65536 https://upd.test/updates/latest.txt$" "$CURL_LOG" && grep -q "max=65536 https://upd.test/updates/latest.txt.sig$" "$CURL_LOG"'
check "the accepted issued value is stored" '[ "$(cat "$R/var/lib/ombra-update/issued")" = "$NOW" ]'
echo "desktop.version=99" >> "$SRV/updates/latest.txt"
run check; check "a tampered index is invalid (exit 1)" '[ "$RC" = 1 ] && [ "$(state)" = invalid ]'
rm -f "$SRV/updates/latest.txt"
run check; check "a 404 index is no-index, not current (exit 0)" '[ "$RC" = 0 ] && [ "$(state)" = no-index ]'
FAKE_CURL_FAIL=1 run check; check "a transport failure is unreachable (exit 75, retried by the unit)" '[ "$RC" = 75 ] && [ "$(state)" = unreachable ]'
reset_root desktop 1.1; index "issued=$NOW" "desktop.version=9.9"
run check; check "a missing expires is stale" '[ "$RC" = 0 ] && [ "$(state)" = stale ]'
reset_root desktop 1.1; index "issued=$NOW" "expires=soon" "desktop.version=9.9"
run check; check "a garbage expires is stale" '[ "$(state)" = stale ]'
reset_root desktop 1.1; index "issued=$NOW" "expires=$((NOW - 10))" "desktop.version=9.9"
run check; check "an expired index is stale" '[ "$(state)" = stale ]'
reset_root desktop 1.1; index "expires=$((NOW + 86400))" "desktop.version=9.9"
run check; check "an index without issued is accepted while none was seen (1.1 compatibility)" '[ "$(state)" = available ] && [ ! -e "$R/var/lib/ombra-update/issued" ]'
index "issued=2000" "expires=$((NOW + 86400))" "desktop.version=9.9"; run check
index "issued=1000" "expires=$((NOW + 86400))" "desktop.version=9.9"; run check
check "a replayed index with a lower issued is stale" '[ "$(state)" = stale ] && [ "$(cat "$R/var/lib/ombra-update/issued")" = 2000 ]'
index "expires=$((NOW + 86400))" "desktop.version=9.9"; run check
check "an index without issued is stale once one was seen" '[ "$(state)" = stale ]'
index "issued=2000" "expires=$((NOW + 86400))" "desktop.version=9.9"; run check
check "the same issued again is accepted" '[ "$(state)" = available ]'
index "issued=1000" "expires=$((NOW + 86400))" "desktop.version=9.9"; run apply
check "apply refuses a replayed index" '[ "$RC" = 1 ] && [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/pending" ]'

# ---- apply refusals: nothing may change ----
unchanged() { [ "$RC" = 1 ] && [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && [ "$(cat "$R/etc/ombra/version")" = 1.1 ] && [ ! -e "$R/usr/local/share/ombra-test" ]; }
reset_root desktop 1.1; mkbundle desktop 9.9 "$T/pl" "$SRV/updates/d.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=d.update" "desktop.sha256=$(printf '%064d' 0)"
run apply; check "apply refuses a bundle whose hash does not match the index" 'unchanged && grep -q checksum "$T/out"'
mkbundle gateway 9.9 "$T/pl" "$SRV/updates/g.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=g.update" "desktop.sha256=$(h "$SRV/updates/g.update")"
run apply; check "apply refuses a bundle for the other machine" 'unchanged && grep -q "different machine" "$T/out"'
mkdir -p "$T/evil/a"; echo x > "$T/evil/a/f"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$T/evil.tgz" -s ',^a/f$,../../etc/evil,' -C "$T/evil" a/f
mkbundle desktop 9.9 "" "$SRV/updates/e.update" "$T/evil.tgz"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=e.update" "desktop.sha256=$(h "$SRV/updates/e.update")"
run apply; check "apply refuses a payload with a traversal path" 'unchanged && grep -q "unsafe paths" "$T/out"'
COPYFILE_DISABLE=1 /usr/bin/tar -czPf "$T/abs.tgz" "$T/evil/a/f"
mkbundle desktop 9.9 "" "$SRV/updates/a.update" "$T/abs.tgz"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=a.update" "desktop.sha256=$(h "$SRV/updates/a.update")"
run apply; check "apply refuses a payload with an absolute path" 'unchanged && grep -q "unsafe paths" "$T/out"'
mkbundle desktop 9.9 "$T/pl" "$SRV/updates/d.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=d.update" "desktop.sha256=$(h "$SRV/updates/d.update")" "desktop.size=$(sz "$SRV/updates/d.update")"
: > "$CURL_LOG"; FAKE_FREE=1000 run apply; check "apply checks free space before downloading" 'unchanged && grep -q "free space" "$T/out" && ! grep -q d.update "$CURL_LOG"'
FAKE_LOCKED=1 run apply; check "apply refuses while another ombra-update holds the lock" 'unchanged && grep -q "another ombra-update" "$T/out"'
FAKE_FSTYPE=overlay run apply; check "apply refuses in an Amnesic boot" 'unchanged'

# ---- a good desktop apply, then commit ----
: > "$CURL_LOG"; run apply
check "a good desktop apply succeeds" '[ "$RC" = 0 ] && [ -e "$LV/snap" ] && [ "$(cat "$R/usr/local/share/ombra-test")" = new ] && [ "$(state)" = applied ]'
check "the bundle download is capped at the size the index names" 'grep -q "max=$(sz "$SRV/updates/d.update") https://upd.test/updates/d.update" "$CURL_LOG"'
check "version, os-release and lsb-release move together" '[ "$(cat "$R/etc/ombra/version")" = 9.9 ] && grep -q "^VERSION_ID=9.9$" "$R/usr/lib/os-release" && grep -q "^DISTRIB_RELEASE=\"9.9\"$" "$R/etc/lsb-release"'
check "pending holds this boot id and applying is gone" '[ "$(cat "$R/var/lib/ombra-update/pending")" = boot-one ] && [ ! -e "$R/var/lib/ombra-update/applying" ]'
run commit; check "commit in the same boot keeps the rollback point" '[ "$RC" = 0 ] && [ -e "$LV/snap" ] && [ -e "$R/var/lib/ombra-update/pending" ]'
echo boot-two > "$R/proc/sys/kernel/random/boot_id"
FAKE_FSTYPE=overlay run commit; check "commit in an Amnesic boot keeps the rollback point" '[ "$RC" = 0 ] && [ -e "$LV/snap" ] && [ -e "$R/var/lib/ombra-update/pending" ]'
FAKE_LOCKED=1 run commit; check "commit exits 0 quietly while locked and keeps the rollback point" '[ "$RC" = 0 ] && [ -e "$LV/snap" ]'
: > "$R/var/lib/ombra-update/applying"
run commit; check "commit refuses while an apply never finished and says to roll back" '[ "$RC" = 1 ] && [ -e "$LV/snap" ] && grep -q "ombra-update rollback" "$T/out"'
rm -f "$R/var/lib/ombra-update/applying"
run commit; check "commit after a restart drops the rollback point" '[ "$RC" = 0 ] && [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/pending" ]'

# ---- 1.1.0's empty pending ----
: > "$R/var/lib/ombra-update/pending"; touch "$LV/snap"
echo "btime $(($(date +%s) + 60))" > "$R/proc/stat"
run commit; check "an empty (1.1.0) pending older than this boot commits" '[ "$RC" = 0 ] && [ ! -e "$R/var/lib/ombra-update/pending" ]'
: > "$R/var/lib/ombra-update/pending"; touch "$LV/snap"
echo "btime $((NOW - 3600))" > "$R/proc/stat"
run commit; check "an empty pending written in this boot does not commit" '[ "$RC" = 0 ] && [ -e "$R/var/lib/ombra-update/pending" ]'

# ---- failure paths and exit codes ----
mkdir -p "$T/plf/usr/local/lib/ombra-update"; printf '#!/bin/sh\nexit 1\n' > "$T/plf/usr/local/lib/ombra-update/post.sh"; chmod 0755 "$T/plf/usr/local/lib/ombra-update/post.sh"
cp -R "$T/pl/usr/local/share" "$T/plf/usr/local/"
reset_root desktop 1.1; mkbundle desktop 9.9 "$T/plf" "$SRV/updates/f.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=f.update" "desktop.sha256=$(h "$SRV/updates/f.update")"
run apply; check "a failed desktop post step exits 3 and schedules the merge" '[ "$RC" = 3 ] && [ -e "$LV/merge" ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && grep -q "restart" "$T/out"'
reset_root desktop 1.1; mkbundle desktop 9.9 "$T/plf" "$SRV/updates/f.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=f.update" "desktop.sha256=$(h "$SRV/updates/f.update")"
FAKE_MERGE_FAIL=1 run apply; check "a failed rollback exits 4 and keeps pending and applying" '[ "$RC" = 4 ] && [ -e "$R/var/lib/ombra-update/pending" ] && [ -e "$R/var/lib/ombra-update/applying" ] && grep -q "could not be rolled back" "$T/out"'
run commit; check "commit then refuses (applying)" '[ "$RC" = 1 ] && [ -e "$LV/snap" ]'
run rollback; check "rollback on the desktop warns about the home folder" '[ "$RC" = 0 ] && grep -q "home folder" "$T/out" && [ ! -e "$R/var/lib/ombra-update/applying" ]'

reset_root gateway 1.1; mkdir -p "$R/usr/local/share"; echo old > "$R/usr/local/share/ombra-test"
mkbundle gateway 9.9 "$T/plf" "$SRV/updates/gf.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "gateway.version=9.9" "gateway.bundle=gf.update" "gateway.sha256=$(h "$SRV/updates/gf.update")"
run apply; check "a failed gateway post step exits 3 and restores the replaced files" '[ "$RC" = 3 ] && [ "$(cat "$R/usr/local/share/ombra-test")" = old ] && [ "$(cat "$R/etc/ombra/version")" = 1.1 ] && grep -q "^DISTRIB_RELEASE=\"1.1\"$" "$R/etc/lsb-release"'
reset_root gateway 1.1; mkdir -p "$R/usr/local/share"; echo old > "$R/usr/local/share/ombra-test"; chmod 000 "$R/usr/local/share/ombra-test"
mkbundle gateway 9.9 "$T/pl" "$SRV/updates/g.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "gateway.version=9.9" "gateway.bundle=g.update" "gateway.sha256=$(h "$SRV/updates/g.update")"
if [ "$(id -u)" = 0 ]; then echo "  skip gateway backup failure (root can read a mode-000 file)"; else
run apply; check "a gateway backup that fails aborts before anything changes (exit 1)" '[ "$RC" = 1 ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && [ "$(cat "$R/etc/ombra/version")" = 1.1 ] && grep -q "back up" "$T/out"'
fi
chmod 644 "$R/usr/local/share/ombra-test"
run apply; check "a good gateway apply succeeds" '[ "$RC" = 0 ] && [ "$(cat "$R/usr/local/share/ombra-test")" = new ] && grep -q "^DISTRIB_RELEASE=\"9.9\"$" "$R/etc/lsb-release"'
run rollback; check "gateway rollback restores files and version" '[ "$RC" = 0 ] && [ "$(cat "$R/usr/local/share/ombra-test")" = old ] && [ "$(cat "$R/etc/ombra/version")" = 1.1 ] && grep -q "^DISTRIB_RELEASE=\"1.1\"$" "$R/etc/lsb-release"'

# ---- info, edition and home layout ----
reset_root desktop 1.1
run info; check "info prints the two-VM desktop's facts" '[ "$RC" = 0 ] && grep -qx edition=two-vm "$T/out" && grep -qx role=desktop "$T/out" && grep -qx update_role=desktop "$T/out" && grep -qx version=1.1 "$T/out" && grep -qx mode=persistent "$T/out" && grep -qx home_on_root=yes "$T/out"'
FAKE_HOME_SRC=/dev/mapper/vg0-home run info; check "info sees a separate home volume" 'grep -qx home_on_root=no "$T/out"'
FAKE_FSTYPE=overlay run info; check "info reports an Amnesic boot" 'grep -qx mode=amnesic "$T/out"'
echo single > "$R/etc/ombra/edition"
run info; check "info on the single edition: role desktop, update role single" 'grep -qx edition=single "$T/out" && grep -qx role=desktop "$T/out" && grep -qx update_role=single "$T/out"'
echo bogus > "$R/etc/ombra/edition"; run info; check "an unknown edition is a usage error (exit 2)" '[ "$RC" = 2 ]'
reset_root gateway 1.1; echo single > "$R/etc/ombra/edition"; run info; check "a single-edition gateway role is refused (exit 2)" '[ "$RC" = 2 ]'

reset_root desktop 1.1; mkbundle desktop 9.9 "$T/pl" "$SRV/updates/d.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=d.update" "desktop.sha256=$(h "$SRV/updates/d.update")"
run apply; FAKE_HOME_SRC=/dev/mapper/vg0-home run rollback
check "rollback with a separate home volume says the home folder is not affected" '[ "$RC" = 0 ] && grep -q "not affected" "$T/out" && ! grep -q "is lost" "$T/out"'

# ---- the single edition ----
mkdir -p "$T/pls/var/lib/ombra" "$T/pls/usr/share/ombra"; echo image-v2 > "$T/pls/var/lib/ombra/gateway.img"
printf '%s  gateway.img\n' "$(h "$T/pls/var/lib/ombra/gateway.img")" > "$T/pls/usr/share/ombra/gateway.img.sha256"
reset_root desktop 1.1; echo single > "$R/etc/ombra/edition"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.8" "single.version=9.9"
run check; check "the single edition reads single.* from the index" '[ "$(state)" = available ] && [ "$(sed -n 2p "$R/run/ombra/update")" = 9.9 ]'
mkbundle desktop 9.9 "$T/pl" "$SRV/updates/d.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "single.version=9.9" "single.bundle=d.update" "single.sha256=$(h "$SRV/updates/d.update")"
run apply; check "the single edition refuses a two-VM desktop bundle" 'unchanged && grep -q "different machine" "$T/out"'
mkbundle single 9.9 "$T/pls" "$SRV/updates/s.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "single.version=9.9" "single.bundle=s.update" "single.sha256=$(h "$SRV/updates/s.update")"
run apply; check "a single bundle with a matching gateway image applies and says the restart picks it up" '[ "$RC" = 0 ] && [ -e "$LV/snap" ] && [ "$(cat "$R/var/lib/ombra/gateway.img")" = image-v2 ] && grep -q "gateway image was replaced" "$T/out"'
reset_root desktop 1.1; echo single > "$R/etc/ombra/edition"
cp -R "$T/pls" "$T/plb"; printf '%064d  gateway.img\n' 0 > "$T/plb/usr/share/ombra/gateway.img.sha256"
mkbundle single 9.9 "$T/plb" "$SRV/updates/s.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "single.version=9.9" "single.bundle=s.update" "single.sha256=$(h "$SRV/updates/s.update")"
run apply; check "a gateway image that does not match its checksum fails the update (exit 3, merge scheduled)" '[ "$RC" = 3 ] && [ -e "$LV/merge" ] && grep -q "does not match its checksum" "$T/out"'
reset_root desktop 1.1; mkbundle desktop 9.9 "$T/pls" "$SRV/updates/d.update"
index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=9.9" "desktop.bundle=d.update" "desktop.sha256=$(h "$SRV/updates/d.update")"
run apply; check "the two-VM desktop does not check a gateway image" '[ "$RC" = 0 ] && ! grep -q "gateway image" "$T/out"'

# ---- Debian updates (security) ----
mkboot() { mkdir -p "$R/boot/grub" "$R/boot/efi/EFI/debian"; echo old > "$R/boot/vmlinuz"; echo cfg > "$R/boot/grub/grub.cfg"; echo esp > "$R/boot/efi/EFI/debian/grubaa64.efi"; }
nothing_sec() { [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && [ ! -e "$R/upgraded" ] && [ ! -e "$R/var/lib/ombra-update/boot.tar" ] && [ -z "$(ls -A "$R/var/lib/apt/lists" 2>/dev/null)" ]; }
reset_root desktop 1.1
FAKE_FSTYPE=overlay run security; check "security refuses in an Amnesic boot and contacts nobody" '[ "$RC" = 1 ] && nothing_sec && [ ! -s "$APT_LOG" ]'
FAKE_LOCKED=1 run security; check "security refuses while another ombra-update holds the lock" '[ "$RC" = 1 ] && nothing_sec && grep -q "another ombra-update" "$T/out"'
FAKE_APT_UNREACHABLE=1 run security; check "an unreachable mirror is exit 75 and changes nothing" '[ "$RC" = 75 ] && nothing_sec'
FAKE_APT_BADSIG=1 run security; check "a bad Debian signature is exit 1 and changes nothing" '[ "$RC" = 1 ] && nothing_sec && grep -q "signature check" "$T/out"'
FAKE_APT_PLAN="$(printf 'Inst curl [1] (2 Debian-Security:13 [arm64])\nRemv tor [0.4]')" run security
check "a plan that removes a package is refused" '[ "$RC" = 1 ] && nothing_sec && grep -q "remove packages (tor )" "$T/out"'
printf '# comment\nopenssl   # pinned\n' > "$R/etc/ombra/update-hold"
FAKE_APT_PLAN="Inst openssl:arm64 [3.5.1-1] (3.5.1-1+deb13u1 Debian-Security:13 [arm64])" run security
check "a plan touching a held package is refused" '[ "$RC" = 1 ] && nothing_sec && grep -q "held packages (openssl )" "$T/out"'
FAKE_APT_PLAN="Inst curl [1] (2 Debian-Security:13 [arm64])" run security
check "the hold list does not block other packages" '[ "$RC" = 0 ] && [ -e "$R/upgraded" ]'
reset_root desktop 1.1
FAKE_APT_PLAN="" run security; check "nothing pending is exit 0, changes nothing and says so" '[ "$RC" = 0 ] && nothing_sec && grep -q "no Debian updates are pending" "$T/out"'
FAKE_APT_BYTES=900000000 run security; check "a download too large for the snapshot is refused" '[ "$RC" = 1 ] && nothing_sec && grep -q "too large" "$T/out"'
run security --no-rollback; check "the desktop refuses --no-rollback (exit 2)" '[ "$RC" = 2 ] && nothing_sec'
mkboot
FAKE_BOOT_MOUNT=1 FAKE_EFI_MOUNT=1 run security
check "a desktop security run succeeds and records applied-security" '[ "$RC" = 0 ] && [ -e "$R/upgraded" ] && [ "$(state)" = applied-security ] && [ -z "$(sed -n 2p "$R/run/ombra/update")" ]'
check "the snapshot and the /boot copy exist before the upgrade runs" 'grep -qx snap-present "$APT_LOG" && grep -qx boot-saved "$APT_LOG"'
check "/boot and the ESP are copied separately" '/usr/bin/tar -tf "$R/var/lib/ombra-update/boot.tar" | grep -q vmlinuz && ! /usr/bin/tar -tf "$R/var/lib/ombra-update/boot.tar" | grep -q efi && /usr/bin/tar -tf "$R/var/lib/ombra-update/efi.tar" | grep -q grubaa64.efi'
check "lists and downloaded packages are cleared afterwards" '[ -z "$(ls -A "$R/var/lib/apt/lists")" ] && [ -z "$(ls -A "$R/var/cache/apt/archives")" ]'
check "pending holds this boot id and applying is gone" '[ "$(cat "$R/var/lib/ombra-update/pending")" = boot-one ] && [ ! -e "$R/var/lib/ombra-update/applying" ]'
check "apt goes through the desktop SOCKS port with fixed options" 'grep "upgrade" "$APT_LOG" | grep -v -- " -s " | grep -- "-y" | grep -q "Acquire::http::Proxy=socks5h://10.55.10.1:9050" && grep -q -- "--error-on=any" "$APT_LOG" && grep -q "Dpkg::Options::=--force-confold" "$APT_LOG" && grep -q "Dpkg::Options::=--force-confdef" "$APT_LOG" && grep -q -- "--with-new-pkgs upgrade" "$APT_LOG"'
check "apt is never told to accept unsigned data" '! grep -qiE "allow-unauthenticated|AllowInsecure|AllowUnauthenticated|AllowDowngrade" "$APT_LOG" "$REPO/update/rootfs/usr/local/sbin/ombra-update"'
FAKE_BOOT_MOUNT=1 run security; check "a second run waits for the first to be committed" '[ "$RC" = 1 ] && grep -q "already waiting" "$T/out"'
echo boot-two > "$R/proc/sys/kernel/random/boot_id"
run commit; check "commit after a restart drops the snapshot and the /boot and ESP copies" '[ "$RC" = 0 ] && [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/boot.tar" ] && [ ! -e "$R/var/lib/ombra-update/efi.tar" ] && [ ! -e "$R/var/lib/ombra-update/pending" ]'

reset_root desktop 1.1; mkboot
FAKE_APT_PLAN="Inst libc6:arm64 [2.41-12] (2.41-12+deb13u1 Debian-Security:13 [arm64])" FAKE_BOOT_MOUNT=1 run security
check "a libc upgrade asks for a restart" '[ "$RC" = 0 ] && [ "$(sed -n 2p "$R/run/ombra/update")" = restart ] && grep -q "Restart to finish" "$T/out"'
reset_root desktop 1.1; : > "$R/run/reboot-required"
run security; check "/run/reboot-required asks for a restart" '[ "$RC" = 0 ] && [ "$(sed -n 2p "$R/run/ombra/update")" = restart ]'
reset_root desktop 1.1
FAKE_SNAP_INVALID=1 run security; check "an overflowed snapshot is dropped and the output says the run cannot be undone" '[ "$RC" = 0 ] && [ ! -e "$LV/snap" ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && grep -q "cannot be undone" "$T/out"'

reset_root desktop 1.1; mkboot
FAKE_APT_FAIL=1 FAKE_BOOT_MOUNT=1 FAKE_EFI_MOUNT=1 run security
check "a failed upgrade after the snapshot exits 3 and schedules the merge" '[ "$RC" = 3 ] && [ -e "$LV/merge" ] && [ ! -e "$R/var/lib/ombra-update/pending" ] && [ ! -e "$R/var/lib/ombra-update/applying" ]'
check "the failed upgrade restores /boot and the ESP and removes what it added" '[ "$(cat "$R/boot/vmlinuz")" = old ] && [ ! -e "$R/boot/vmlinuz-new" ] && [ "$(cat "$R/boot/grub/grub.cfg")" = cfg ] && [ "$(cat "$R/boot/efi/EFI/debian/grubaa64.efi")" = esp ] && [ ! -e "$R/boot/efi/EFI/debian/new.efi" ]'
reset_root desktop 1.1; mkboot
FAKE_APT_FAIL=1 FAKE_BOOT_MOUNT=1 run security
check "without a separate ESP mount, /boot is restored whole (ESP included in its copy)" '[ "$RC" = 3 ] && [ "$(cat "$R/boot/efi/EFI/debian/grubaa64.efi")" = esp ] && [ ! -e "$R/boot/efi/EFI/debian/new.efi" ]'
check "the failed upgrade still clears the lists" '[ -z "$(ls -A "$R/var/lib/apt/lists")" ]'
reset_root desktop 1.1; mkboot
FAKE_APT_FAIL=1 FAKE_MERGE_FAIL=1 FAKE_BOOT_MOUNT=1 run security
check "a failed upgrade whose rollback fails exits 4 and keeps applying" '[ "$RC" = 4 ] && [ -e "$R/var/lib/ombra-update/applying" ]'

reset_root gateway 1.1
run security; check "the gateway refuses without --no-rollback and says why" '[ "$RC" = 1 ] && [ ! -s "$APT_LOG" ] && grep -q "cannot undo" "$T/out"'
run security --no-rollback
check "the gateway runs with --no-rollback through its own SOCKS port and keeps no rollback state" '[ "$RC" = 0 ] && [ -e "$R/upgraded" ] && grep -q "socks5h://127.0.0.1:9050" "$APT_LOG" && [ ! -e "$R/var/lib/ombra-update/pending" ] && [ ! -e "$LV/snap" ] && grep -q "cannot undo" "$T/out" && [ "$(state)" = applied-security ]'
reset_root gateway 1.1
FAKE_DPKG_AUDIT="half-configured: tor" run security --no-rollback
check "the gateway first finishes an interrupted dpkg run" '[ "$RC" = 0 ] && grep -q "dpkg --force-confold --force-confdef --configure -a" "$APT_LOG"'
reset_root gateway 1.1
FAKE_APT_FAIL=1 run security --no-rollback; check "a failed gateway upgrade exits 4 and says it cannot be undone" '[ "$RC" = 4 ] && grep -q "cannot undo" "$T/out"'
reset_root desktop 1.1; run check >/dev/null
check "the automatic check never contacts Debian" '[ ! -s "$APT_LOG" ]'

# ---- the index generator ----
mkbundle gateway 9.9 "$T/pl" "$SRV/updates/g.update"
PATH="$OPATH" bash "$REPO/scripts/update/make-index.sh" "$T/sign.key" "$T/mi" 30 "gateway=$SRV/updates/g.update" >/dev/null 2>&1
check "make-index writes issued, expires and size" 'grep -qE "^issued=[0-9]+$" "$T/mi/latest.txt" && grep -qE "^expires=[0-9]+$" "$T/mi/latest.txt" && grep -qE "^gateway.size=$(sz "$SRV/updates/g.update")$" "$T/mi/latest.txt"'
PATH="$OPATH" bash "$REPO/scripts/update/make-index.sh" "$T/sign.key" "$T/mi2" 0 "gateway=$SRV/updates/g.update" >/dev/null 2>&1 && bad "make-index accepted 0 valid days" || ok "make-index refuses a non-positive validity"

# ---- release sums signing ----
mkdir -p "$T/rel"; echo img > "$T/rel/ombra-x.utm.zip"; (cd "$T/rel" && shasum -a 256 ombra-x.utm.zip > SHA256SUMS.txt)
PATH="$OPATH" bash "$REPO/scripts/update/sign-sums.sh" "$T/sign.key" "$T/rel/SHA256SUMS.txt" >/dev/null 2>&1
OPENSSL="$OSSL" bash "$REPO/scripts/update/verify-sums.sh" "$T/pub.pem" "$T/rel/SHA256SUMS.txt" >/dev/null 2>&1 && ok "sign-sums and verify-sums round trip" || bad "sums round trip"
echo tampered > "$T/rel/ombra-x.utm.zip"
OPENSSL="$OSSL" bash "$REPO/scripts/update/verify-sums.sh" "$T/pub.pem" "$T/rel/SHA256SUMS.txt" >/dev/null 2>&1 && bad "verify-sums passed a changed archive" || ok "verify-sums catches a changed archive"
PATH="$OPATH" bash "$REPO/scripts/update/sign-sums.sh" "$T/sign.key" "$T/rel/SHA256SUMS.txt" >/dev/null 2>&1 && bad "sign-sums signed sums that do not match" || ok "sign-sums refuses sums that do not match the archives"

# ---- app updates (apps.txt) ----
A="$T/apps"; mkdir -p "$A/e/Electrum-4.8.3" "$A/tb/tor-browser/Browser"
printf '#!/bin/sh\n' > "$A/e/Electrum-4.8.3/run_electrum"
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$A/electrum.tar.gz" -C "$A/e" Electrum-4.8.3
echo bin > "$A/tb/tor-browser/Browser/firefox"
COPYFILE_DISABLE=1 /usr/bin/tar -cJf "$A/tb.tar.xz" -C "$A/tb" tor-browser
apps_list() { # app list from lines, signed (type=apps first unless the lines name a type)
    { case "${1:-}" in type=*) ;; *) echo type=apps ;; esac; printf '%s\n' "$@"; } > "$SRV/updates/apps.txt"; sign "$SRV/updates/apps.txt"
}
apps_root() {
    reset_root desktop 1.2.1; mkdir -p "$SRV/dl" "$R/opt/tor-browser/Browser/TorBrowser/Data/Browser" "$R/opt/tor-browser/Browser/distribution" "$R/var/tmp"
    cp "$A/electrum.tar.gz" "$A/tb.tar.xz" "$SRV/dl/"
    printf '{"version":"16.0.1"}\n' > "$R/opt/tor-browser/Browser/tbb_version.json"
    echo bookmarks > "$R/opt/tor-browser/Browser/TorBrowser/Data/Browser/places"; echo '{}' > "$R/opt/tor-browser/Browser/distribution/policies.json"
    index "issued=$NOW" "expires=$((NOW + 86400))" "desktop.version=1.2.1" "desktop.bundle=x.update" "desktop.sha256=00"
    E="electrum.version=4.8.3 electrum.url=https://upd.test/dl/electrum.tar.gz electrum.sha256=$(h "$A/electrum.tar.gz") electrum.size=$(sz "$A/electrum.tar.gz")"
}
export FAKE_VER_electrum=4.5.8+ds-5 FAKE_VER_simplex=7.1.4-1~noble
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E "torbrowser.version=16.0.1" "torbrowser.url=https://upd.test/dl/tb.tar.xz" "torbrowser.sha256=$(h "$A/tb.tar.xz")" "torbrowser.size=$(sz "$A/tb.tar.xz")"
run check; check "check lists app updates newer than installed (Electrum 4.5.8 -> 4.8.3), not current ones (Tor Browser)" '[ "$RC" = 0 ] && [ "$(state)" = current ] && [ "$(cat "$R/run/ombra/apps")" = "electrum 4.8.3" ]'
echo "electrum.version=9.9" >> "$SRV/updates/apps.txt"
run check; check "a tampered app list changes nothing and does not fail the Ombra check" '[ "$RC" = 0 ] && [ "$(cat "$R/run/ombra/apps")" = "electrum 4.8.3" ]'
apps_list "issued=$((NOW - 100))" "expires=$((NOW + 86400))" "electrum.version=9.9"
run check; check "an app list older than one already seen is ignored" '[ "$(cat "$R/run/ombra/apps")" = "electrum 4.8.3" ]'
apps_list "issued=$((NOW + 1))" "expires=$((NOW - 1))" "electrum.version=9.9"
run check; check "an expired app list is ignored" '[ "$(cat "$R/run/ombra/apps")" = "electrum 4.8.3" ]'
apps_list "type=index" "issued=$((NOW + 2))" "expires=$((NOW + 86400))" "electrum.version=9.9"
run check; check "a signed list that is not an app list is refused as one" '[ "$(cat "$R/run/ombra/apps")" = "electrum 4.8.3" ]'
cp "$SRV/updates/latest.txt" "$SRV/l.keep"; cp "$SRV/updates/latest.txt.sig" "$SRV/l.sig.keep"
apps_list "issued=$((NOW + 5000))" "expires=$((NOW + 86400))" "desktop.version=9.9"
cp "$SRV/updates/apps.txt" "$SRV/updates/latest.txt"; cp "$SRV/updates/apps.txt.sig" "$SRV/updates/latest.txt.sig"
run check; check "the app list served as the index is refused and does not raise the replay floor" '[ "$RC" != 0 ] && [ "$(cat "$R/var/lib/ombra-update/issued")" != "$((NOW + 5000))" ]'
cp "$SRV/l.keep" "$SRV/updates/latest.txt"; cp "$SRV/l.sig.keep" "$SRV/updates/latest.txt.sig"
rm -f "$SRV/updates/apps.txt" "$SRV/updates/apps.txt.sig"
run check; check "no app list published: no app updates" '[ ! -e "$R/run/ombra/apps" ]'

# a power cut in the middle of the browser swap: the old tree sits in .old, the profile in .next
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))"
mv "$R/opt/tor-browser" "$R/opt/tor-browser.old"; mkdir -p "$R/opt/tor-browser.next/Browser/TorBrowser"
mv "$R/opt/tor-browser.old/Browser/TorBrowser/Data" "$R/opt/tor-browser.next/Browser/TorBrowser/Data"
run check; check "an interrupted browser swap is undone at the next check, with the profile back in place" '[ "$(cat "$R/opt/tor-browser/Browser/TorBrowser/Data/Browser/places")" = bookmarks ] && [ ! -e "$R/opt/tor-browser.old" ] && [ ! -e "$R/opt/tor-browser.next" ]'
# the same picture while `apps apply` holds the lock is a swap in progress: the check must leave it alone
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))"
mv "$R/opt/tor-browser" "$R/opt/tor-browser.old"; mkdir -p "$R/opt/tor-browser.next/Browser/TorBrowser"
mv "$R/opt/tor-browser.old/Browser/TorBrowser/Data" "$R/opt/tor-browser.next/Browser/TorBrowser/Data"
FAKE_LOCKED=1 run check; check "a check during an app update (lock held) does not touch the swap in progress" '[ "$RC" = 0 ] && [ ! -e "$R/opt/tor-browser" ] && [ -d "$R/opt/tor-browser.old/Browser" ] && [ "$(cat "$R/opt/tor-browser.next/Browser/TorBrowser/Data/Browser/places")" = bookmarks ]'
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))"
mkdir -p "$R/opt/tor-browser.next/Browser/TorBrowser"
mv "$R/opt/tor-browser/Browser/TorBrowser/Data" "$R/opt/tor-browser.next/Browser/TorBrowser/Data"
run check; check "a cut before the swap moves the profile back into the installed browser" '[ "$(cat "$R/opt/tor-browser/Browser/TorBrowser/Data/Browser/places")" = bookmarks ] && [ ! -e "$R/opt/tor-browser.next" ]'
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
mkdir -p "$R/opt/electrum"; echo old > "$R/opt/electrum/run_electrum"
FAKE_RUN_FILE="$R/var/lib/ombra-update/app-electrum.tar.gz" run apps apply
check "an app opened while its download ran is left for later, unchanged (exit 6)" '[ "$RC" = 6 ] && [ "$(cat "$R/opt/electrum/run_electrum")" = old ] && [ ! -e "$R/var/lib/ombra-update/app-electrum.tar.gz" ]'
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" "simplex.version=7.1.4"
FAKE_HALF=simplex run check; check "a SimpleX install cut off inside dpkg is offered again" '[ "$(cat "$R/run/ombra/apps")" = "simplex 7.1.4" ]'
run check; check "a complete SimpleX install of the listed version is not offered" '[ ! -s "$R/run/ombra/apps" ]'
apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
run apps apply nosuchapp; check "an unknown app name is refused" '[ "$RC" != 0 ] && grep -q "unknown app" "$T/out" && [ ! -e "$R/opt/electrum" ]'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
run apps apply; check "apps apply installs Electrum into /opt/electrum with its version" '[ "$RC" = 0 ] && [ -f "$R/opt/electrum/run_electrum" ] && [ "$(cat "$R/opt/electrum/.ombra-version")" = 4.8.3 ] && grep -q "installed Electrum 4.8.3" "$T/out"'
check "the download is capped at the listed size and nothing is left behind" 'grep -q "max=$(sz "$A/electrum.tar.gz") https://upd.test/dl/electrum.tar.gz$" "$CURL_LOG" && [ ! -e "$R/var/lib/ombra-update/app-electrum" ] && [ ! -e "$R/opt/electrum.next" ]'
check "once installed, Electrum is no longer offered" '[ ! -e "$R/run/ombra/apps" ] && [ "$(env PATH="$S:$PATH" "$SHELL_UNDER_TEST" "$U" apps list 2>/dev/null)" = "" ]'
check "no Debian packages were fetched when Electrum's are installed" '! grep -q "apt-get.* install" "$APT_LOG"'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" "electrum.version=4.8.3" "electrum.url=https://upd.test/dl/electrum.tar.gz" "electrum.sha256=$(printf 0%.0s $(seq 64))" "electrum.size=$(sz "$A/electrum.tar.gz")"
mkdir -p "$R/opt/electrum"; echo old > "$R/opt/electrum/run_electrum"
run apps apply; check "a download that does not match the signed list is refused; the previous version stays (exit 1)" '[ "$RC" = 1 ] && [ "$(cat "$R/opt/electrum/run_electrum")" = old ] && grep -q "does not match the signed app list" "$T/out"'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
FAKE_RUNNING=run_electrum run apps apply; check "an open app is left for later (exit 6)" '[ "$RC" = 6 ] && [ ! -e "$R/opt/electrum" ] && grep -q "skipped Electrum 4.8.3" "$T/out"'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
FAKE_MISSING="python3-pyqt6" run apps apply; check "missing Debian packages for Electrum come from Debian through Tor, then the lists are removed" '[ "$RC" = 0 ] && grep -q "apt-get .*socks5h://10.55.10.1:9050.* update" "$APT_LOG" && grep -q "apt-get .* install python3-pyqt6" "$APT_LOG" && [ -z "$(ls "$R/var/lib/apt/lists" 2>/dev/null)" ]'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" "torbrowser.version=16.0.2" "torbrowser.url=https://upd.test/dl/tb.tar.xz" "torbrowser.sha256=$(h "$A/tb.tar.xz")" "torbrowser.size=$(sz "$A/tb.tar.xz")"
run apps apply; check "a Tor Browser update keeps the profile and Ombra's policies" '[ "$RC" = 0 ] && [ "$(cat "$R/opt/tor-browser/Browser/TorBrowser/Data/Browser/places")" = bookmarks ] && [ -f "$R/opt/tor-browser/Browser/distribution/policies.json" ] && [ -f "$R/opt/tor-browser/Browser/firefox" ] && [ ! -e "$R/opt/tor-browser.next" ] && [ ! -e "$R/opt/tor-browser.old" ]'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" "electrum.version=4.8.3" "electrum.url=http://upd.test/dl/electrum.tar.gz" "electrum.sha256=$(h "$A/electrum.tar.gz")" "electrum.size=$(sz "$A/electrum.tar.gz")"
run apps apply; check "an app download that is not https is refused" '[ "$RC" = 1 ] && [ ! -e "$R/opt/electrum" ] && ! grep -q "dl/electrum" "$CURL_LOG"'

apps_root; apps_list "issued=$NOW" "expires=$((NOW + 86400))" $E
FAKE_FSTYPE=overlay run apps apply; check "app updates refuse an Amnesic boot" '[ "$RC" = 1 ] && [ ! -e "$R/opt/electrum" ]'
apps_root; mkdir -p "$A/sx"; echo deb > "$A/sx/simplex.deb"; cp "$A/sx/simplex.deb" "$SRV/dl/simplex.deb"; mkdir -p "$R/opt/simplex/bin"; printf '#!/bin/sh\n' > "$R/opt/simplex/bin/simplex"; chmod 0755 "$R/opt/simplex/bin/simplex"
apps_list "issued=$NOW" "expires=$((NOW + 86400))" "simplex.version=7.1.5" "simplex.url=https://upd.test/dl/simplex.deb" "simplex.sha256=$(h "$A/sx/simplex.deb")" "simplex.size=$(sz "$A/sx/simplex.deb")"
run apps apply; check "a SimpleX update is installed with dpkg from a .deb file name" '[ "$RC" = 0 ] && grep -q "dpkg --force-confold -i .*app-simplex.deb" "$APT_LOG" && grep -q "installed SimpleX 7.1.5" "$T/out"'
reset_root gateway 1.2; run apps apply; check "app updates are for the desktop" '[ "$RC" = 1 ]'

[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
