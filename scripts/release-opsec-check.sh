#!/bin/bash
# release-opsec-check.sh [release-dir]
# The release gate: nothing about the builder may reach a file users download. Run it on build/releases (the default)
# after the last export and before any upload; scripts/upload-r2.sh refuses files this gate has not passed.
#
# What it looks for, in every *.zip, *.iso, updates/*.update and the checksum files:
#   - the builder's identity, read from THIS Mac at run time and never written down or printed: macOS user and full
#     name, computer, local host and host names, the home folder path, LAN and VMware NAT addresses (any address in
#     the NAT networks the installers ran on), Wi-Fi/Ethernet MAC addresses, the R2 credentials
#   - private keys, test builds (file names, the cpio marker entry, preseeded passwords or disk passphrases)
#   - metadata: zip owner and extended-time fields, macOS litter (._*, __MACOSX, .DS_Store), ISO and cpio owners,
#     ISO publisher/preparer fields
# Plain-text parts of the disks are scanned byte for byte (the gateway disk, the desktop's /boot and EFI partition).
# The desktop's encrypted volume cannot be read here; its installer zeroes build-network residue and parks on a live
# hit (desktop/late-command.sh, phase residue).
# On success writes <release-dir>/.opsec-ok: the sha256 of every file that passed. Prints categories, never values.
set -euo pipefail
shopt -s nullglob
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="${1:-$REPO/build/releases}"
R="$(cd "$R" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
for t in xorriso unzip zipinfo shasum; do command -v "$t" >/dev/null || { echo "FATAL: $t not found" >&2; exit 1; }; done

T=$(mktemp -d); chmod 700 "$T"; trap 'rm -rf "${T:?}"' EXIT
FAIL=0
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
pass() { echo "ok    $*"; }

# ---- identifiers, from this Mac (fixed strings, one per line; never echoed) ------------------------------------------
P="$T/fixed"; : > "$P"
add() { [ -n "${1:-}" ] && [ "${#1}" -ge 4 ] && printf '%s\n' "$1" >> "$P" || true; }
add "$HOME/"
add "$(id -un)@"
add "$(id -F 2>/dev/null || true)"
for k in ComputerName LocalHostName HostName; do add "$(scutil --get "$k" 2>/dev/null || true)"; done
add "$(hostname -s 2>/dev/null || true)"
ifconfig | awk '$1 == "ether" {print $2}' | sort -u | while read -r m; do
  add "$m"; add "$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]')"
done
if [ -f "$REPO/build/local/r2.env" ]; then
  ( set -a; . "$REPO/build/local/r2.env"; set +a
    for v in "${R2_ACCESS_KEY_ID:-}" "${R2_SECRET_ACCESS_KEY:-}" "${R2_ENDPOINT:-}"; do add "$v"; done )
fi
# the signing key's own text, if its location is given (OMBRA_SIGNING_KEY): a leaked key file would show up here
[ -z "${OMBRA_SIGNING_KEY:-}" ] || [ ! -f "$OMBRA_SIGNING_KEY" ] || sed -n '2p' "$OMBRA_SIGNING_KEY" >> "$P"
sort -u -o "$P" "$P"
# address patterns: this Mac's own LAN addresses, and every address in its VMware networks (where installs ran)
E="$T/regex"; : > "$E"
ifconfig | awk '$1 == "inet" && $2 !~ /^127\./ {print $2}' | sort -u | while read -r a; do
  printf '(^|[^0-9.])%s([^0-9]|$)\n' "$(printf '%s' "$a" | sed 's/\./\\./g')" >> "$E"
done
ifconfig | awk '/^vmnet[0-9]*:/ {v=1} /^[a-z]/ && !/^vmnet/ {v=0} v && $1 == "inet" {print $2}' | awk -F. '{print $1"."$2"."$3}' | sort -u \
  | while read -r n; do printf '(^|[^0-9.])%s\\.[0-9]{1,3}([^0-9]|$)\n' "$(printf '%s' "$n" | sed 's/\./\\./g')" >> "$E"; done
# one pattern file for ripgrep: the identifiers as literals, the address patterns, and a real PEM private key (its
# header and the first base64 line; upstream libraries carry the bare header text)
command -v rg >/dev/null || { echo "FATAL: ripgrep not found (brew install ripgrep)" >&2; exit 1; }
ALL="$T/all"
sed 's/[][\\.*^$+?(){}|/-]/\\&/g' "$P" > "$ALL"
cat "$E" >> "$ALL"
printf '%s\n' '-----BEGIN [A-Z ]*PRIVATE KEY-----\r?\n[A-Za-z0-9+/]{60,}' >> "$ALL"
nfixed=$(wc -l < "$P" | tr -d ' '); nre=$(wc -l < "$E" | tr -d ' ')
[ "$nfixed" -ge 5 ] && [ "$nre" -ge 1 ] || { echo "FATAL: could not read this Mac's identifiers" >&2; exit 1; }
echo "gate: $nfixed builder identifiers and $nre address patterns from this Mac (values not shown)"

# classify: ripgrep's matches in, one number out: identity and address matches, and private keys whose first base64
# line is not a known upstream test vector (scripts/opsec-known-keys.txt). Values are never printed.
cat > "$T/classify.py" <<'PY'
import hashlib, re, sys
known = {l.split()[0] for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")}
hdr = re.compile(rb"^-----BEGIN [A-Z ]*PRIVATE KEY-----\r?$")
bad = 0; lines = sys.stdin.buffer.read().split(b"\n"); i = 0
while i < len(lines):
    l = lines[i]
    if hdr.match(l) and i + 1 < len(lines):
        body = lines[i + 1].rstrip(b"\r")
        if hashlib.sha256(body).hexdigest() not in known: bad += 1
        i += 2; continue
    if l: bad += 1
    i += 1
print(bad)
PY
KNOWN="$HERE/opsec-known-keys.txt"
[ -f "$KNOWN" ] || { echo "FATAL: $KNOWN missing" >&2; exit 1; }

# scan <label> <file-or-dash>: one ripgrep pass over a byte stream (stdin when -)
scan() {
  local n
  # ripgrep exits 1 when nothing matches (the good case) and 2 on an error: only an error may stop the gate
  local in=-; [ "$2" = - ] || in=$2
  n=$( { rg --no-config -U -a -o -f "$ALL" "$in"; r=$?; [ "$r" -le 1 ] || echo "SCAN-ERROR"; } | python3 -I "$T/classify.py" "$KNOWN")
  if [ "${n:-1}" = 0 ]; then pass "$1: no builder identifiers or unknown keys"; else fail "$1: $n match(es): builder identifiers, build-network addresses or an unknown private key"; fi
}

OKLIST="$T/ok"; : > "$OKLIST"

# ---- zip archives ----------------------------------------------------------------------------------------------------
for z in "$R"/*.zip; do
  n=$(basename "$z"); f0=$FAIL
  case "$n" in *-test*|*TEST*) fail "$n: a test build name" ;; esac
  unzip -Z1 "$z" > "$T/list" || { fail "$n: unreadable"; continue; }
  [ "$(LC_ALL=C grep -c -E '(^|/)\._|__MACOSX|\.DS_Store' "$T/list" || true)" = 0 ] && pass "$n: no macOS litter" || fail "$n: macOS litter in the archive"
  zipinfo -v "$z" > "$T/zv"
  [ "$(grep -c -E 'Unix UID/GID|UID/GID|extended local time|UT extra|ux extra|UX extra' "$T/zv" || true)" = 0 ] \
    && pass "$n: no owner or extended-time fields" || fail "$n: owner or extended-time fields (zip without -X?)"
  [ "$(awk '/file last modified on \(DOS date\/time\)/ {print $NF}' "$T/zv" | sort -u | wc -l | tr -d ' ')" -le 1 ] \
    && pass "$n: one fixed timestamp" || fail "$n: per-file local timestamps (time zone leak)"
  scan "$n: listing" "$T/list"
  while IFS= read -r e; do
    case "$e" in */) continue ;; esac
    unzip -p "$z" "$e" | scan "$n:$e" -
  done < "$T/list"
  [ "$FAIL" = "$f0" ] && printf '%s  %s\n' "$(shasum -a 256 "$z" | cut -d' ' -f1)" "$n" >> "$OKLIST"
done

# ---- installer ISOs --------------------------------------------------------------------------------------------------
for iso in "$R"/*.iso; do
  n=$(basename "$iso"); f0=$FAIL
  case "$n" in *-test*|*TEST*) fail "$n: a test build name" ;; esac
  xorriso -indev "$iso" -pvd_info 2>/dev/null > "$T/pvd"
  if grep -E '^(Publisher Id|Preparer Id|App Id|System Id|Volume Set Id) *:' "$T/pvd" | grep -v -i -E ': *$|xorriso|libisofs|: *LINUX *$' | grep -q .; then
    fail "$n: ISO header names a publisher or preparer"; else pass "$n: ISO header fields generic"; fi
  xorriso -indev "$iso" -find / -type f -exec lsdl -- 2>/dev/null | awk '$3 != "0" || $4 != "0"' > "$T/owners"
  [ -s "$T/owners" ] && fail "$n: files not owned by root" || pass "$n: every file owned by root"
  xorriso -osirrox on -indev "$iso" -extract /install.a64/initrd.gz "$T/initrd.gz" >/dev/null 2>&1 || { fail "$n: no initrd"; continue; }
  gzip -dc "$T/initrd.gz" > "$T/initrd.cpio" 2>/dev/null || true
  python3 -I - "$T/initrd.cpio" > "$T/cpio" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=0
while (j := d.find(b'070701', i)) >= 0:
    h=d[j:j+110]
    try: uid=int(h[22:30],16); gid=int(h[30:38],16); fs=int(h[54:62],16); ns=int(h[94:102],16)
    except ValueError: i=j+6; continue
    name=d[j+110:j+110+ns-1].decode('latin1')
    print(uid, gid, name)
    p=j+110+ns; p=(p+3)&~3; p+=fs; p=(p+3)&~3; i=p
PY
  [ "$(awk '$1 != 0 || $2 != 0' "$T/cpio" | wc -l | tr -d ' ')" = 0 ] && pass "$n: initrd entries owned by root" || fail "$n: initrd entries owned by the builder"
  [ "$(LC_ALL=C grep -c -E ' (\./)?ombra/test-build$' "$T/cpio" || true)" = 0 ] && pass "$n: no test-build marker" || fail "$n: test-build marker in the initrd"
  if LC_ALL=C grep -a -E '^d-i (partman-crypto/passphrase(-again)?|passwd/(user|root)-password(-crypted|-again)?) ' "$T/initrd.cpio" \
       | grep -v -E 'password-crypted string !?\*?$|passwd/root-password-crypted string \*$' | grep -q .; then
    fail "$n: a preseeded password or disk passphrase"; else pass "$n: no preseeded secrets"; fi
  scan "$n: initrd" "$T/initrd.cpio"
  scan "$n: whole image" "$iso"
  rm -f "$T/initrd.gz" "$T/initrd.cpio"
  [ "$FAIL" = "$f0" ] && printf '%s  %s\n' "$(shasum -a 256 "$iso" | cut -d' ' -f1)" "$n" >> "$OKLIST"
done

# ---- update bundles --------------------------------------------------------------------------------------------------
for u in "$R"/updates/*.update; do
  n="updates/$(basename "$u")"; f0=$FAIL
  tar -xf "$u" -C "$T" payload.tar.gz manifest 2>/dev/null || { fail "$n: unreadable"; continue; }
  [ "$(python3 -I -c 'import sys,tarfile; print(sum(1 for m in tarfile.open(sys.argv[1]) if m.uid or m.gid))' "$T/payload.tar.gz")" = 0 ] \
    && pass "$n: payload owned by root" || fail "$n: payload files owned by the builder"
  [ "$(tar -tzf "$T/payload.tar.gz" | LC_ALL=C grep -c -E '(^|/)\._|__MACOSX|\.DS_Store' || true)" = 0 ] && pass "$n: no macOS litter" || fail "$n: macOS litter"
  gzip -dc "$T/payload.tar.gz" | scan "$n: payload" -
  scan "$n: manifest" "$T/manifest"
  rm -f "$T/payload.tar.gz" "$T/manifest"
  [ "$FAIL" = "$f0" ] && printf '%s  %s\n' "$(shasum -a 256 "$u" | cut -d' ' -f1)" "$n" >> "$OKLIST"
done

# ---- small text files ------------------------------------------------------------------------------------------------
for s in "$R"/SHA256SUMS.txt "$R"/SHA256SUMS.txt.sig "$R"/updates/latest.txt "$R"/updates/latest.txt.sig "$R"/updates/apps.txt "$R"/updates/apps.txt.sig; do
  [ -f "$s" ] || continue
  n="${s#"$R"/}"; f0=$FAIL
  scan "$n" "$s"
  [ "$FAIL" = "$f0" ] && printf '%s  %s\n' "$(shasum -a 256 "$s" | cut -d' ' -f1)" "$n" >> "$OKLIST"
done

if [ "$FAIL" -gt 0 ]; then
  rm -f "$R/.opsec-ok"
  echo "GATE FAILED: $FAIL problem(s). Nothing may be uploaded until they are fixed."
  exit 1
fi
cp "$OKLIST" "$R/.opsec-ok"
echo "GATE PASSED: $(wc -l < "$R/.opsec-ok" | tr -d ' ') file(s) recorded in $R/.opsec-ok"
