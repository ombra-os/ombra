#!/bin/bash
# check-pins.sh
# Compares every pinned download in build/pins/ with its project's current stable release, from each project's own
# release source. Prints one line per pin: current, BEHIND (with the upstream version) or UNKNOWN (the source could
# not be read). Exit 0 only when every pin is current; 1 when any pin is behind; 2 when any source could not be read.
# A release is not built or signed unless this exits 0: Ombra does not ship an app with a newer upstream release.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PINS="$HERE/../build/pins"
pin() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$PINS/$1.txt"; }
get() { curl -fsSL --max-time 30 -A "check-pins" "$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

upstream() { # <pin> -> latest stable version on stdout, or nothing
  case "$1" in
    torbrowser) get https://aus1.torproject.org/torbrowser/update_3/release/downloads.json \
                  | json "d['version'] if 'linux-aarch64' in d['downloads'] else ''" ;;
    electrum)   get https://electrum.org/version | json "d['version']" ;;
    feather)    get https://api.github.com/repos/feather-wallet/feather/releases/latest | json "d['tag_name'].lstrip('v')" ;;
    simplex)    get https://api.github.com/repos/simplex-chat/simplex-chat/releases/latest | json "d['tag_name'].lstrip('v')" ;;
    debian-netinst-arm64)
                get https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS \
                  | sed -n 's/.*debian-\([0-9.]*\)-arm64-netinst\.iso$/\1/p' | head -1 ;;
  esac
}
pinned() { # <pin> -> pinned version
  case "$1" in
    debian-netinst-arm64) pin "$1" filename | sed -n 's/^debian-\([0-9.]*\)-arm64-netinst\.iso$/\1/p' ;;
    *) pin "$1" version ;;
  esac
}

rc=0
printf '%-22s %-10s %-10s %s\n' PIN PINNED UPSTREAM STATE
for p in torbrowser feather simplex electrum debian-netinst-arm64; do
  [ -f "$PINS/$p.txt" ] || { echo "FATAL: build/pins/$p.txt missing" >&2; exit 2; }
  have=$(pinned "$p"); want=$(upstream "$p" 2>/dev/null)
  if ! [[ "$want" =~ ^[0-9]+(\.[0-9]+)+$ ]] || [ -z "$have" ]; then
    state=UNKNOWN; [ "$rc" = 1 ] || rc=2
  elif [ "$have" = "$want" ] || [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | tail -1)" = "$have" ]; then
    state=current
  else
    state=BEHIND; rc=1
  fi
  printf '%-22s %-10s %-10s %s\n' "$p" "${have:-?}" "${want:-?}" "$state"
done
# build/pins/kaze.txt pins an upstream commit: the project publishes no releases, so there is no version to compare
exit "$rc"
