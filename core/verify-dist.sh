#!/bin/sh
# Rebuild ombra-boot into a throwaway target dir with build.sh's flags and fail if dist/aarch64 or any
# rootfs copy differs from the fresh build. Read-only: nothing under the repo is written.
set -eu
cd "$(dirname "$0")"
CORE="$(pwd)"
REPO="$(cd .. && pwd)"
TRIPLE=aarch64-unknown-linux-musl

# must stay byte-identical to the RUSTFLAGS line in build.sh (checked below)
FLAGS_LINE='export RUSTFLAGS="-C linker=rust-lld --remap-path-prefix=$HOME=/build --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rust --remap-path-prefix=$SYSROOT=/rustc-sysroot"'
grep -qxF "$FLAGS_LINE" build.sh || {
    echo "verify-dist: build.sh RUSTFLAGS changed; update verify-dist.sh to match" >&2
    exit 1
}
rustup target list --installed | grep -qx "$TRIPLE" || {
    echo "verify-dist: target $TRIPLE not installed (run build.sh once)" >&2
    exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ombra-verify-dist.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

SYSROOT="$(rustc --print sysroot)"
export RUSTFLAGS="-C linker=rust-lld --remap-path-prefix=$HOME=/build --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rust --remap-path-prefix=$SYSROOT=/rustc-sysroot"
cargo build --locked --release --target "$TRIPLE" --target-dir "$TMP"
FRESH="$TMP/$TRIPLE/release"

fail=0
# bin  copy-path...  (dist first, then every rootfs copy scripts/build.sh installs)
check() {
    bin="$1"
    shift
    for copy in "$@"; do
        if [ ! -f "$copy" ]; then
            echo "MISSING  $copy"
            fail=1
        elif ! cmp -s "$FRESH/$bin" "$copy"; then
            echo "DIFFERS  $copy"
            fail=1
        elif [ ! -x "$copy" ]; then
            echo "NOT +x   $copy"
            fail=1
        else
            echo "ok       $copy"
        fi
    done
}
check ombra "$CORE/dist/aarch64/ombra" \
    "$REPO/gateway/rootfs/usr/local/bin/ombra" \
    "$REPO/desktop/rootfs/usr/local/bin/ombra"
check ombra-torctl-filter "$CORE/dist/aarch64/ombra-torctl-filter" \
    "$REPO/gateway/rootfs/usr/local/bin/ombra-torctl-filter"
check ombra-statusd "$CORE/dist/aarch64/ombra-statusd" \
    "$REPO/desktop/rootfs/usr/local/bin/ombra-statusd"
check ombra-tproxy "$CORE/dist/aarch64/ombra-tproxy" \
    "$REPO/desktop/rootfs/usr/local/bin/ombra-tproxy"
check ombra-askpass "$CORE/dist/aarch64/ombra-askpass" \
    "$REPO/desktop/rootfs/usr/local/libexec/ombra/ombra-askpass"
check ombra-welcome "$CORE/dist/aarch64/ombra-welcome" \
    "$REPO/desktop/rootfs/usr/local/libexec/ombra/ombra-welcome"

if [ "$fail" -ne 0 ]; then
    echo "verify-dist: shipped binaries do not match a fresh build; rerun build.sh and recopy" >&2
    exit 1
fi
echo "verify-dist: all shipped binaries match a fresh build"
