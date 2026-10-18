#!/bin/sh
# Cross-compile ombra-boot: aarch64, musl-static, rust-lld → dist/aarch64/
set -eu
cd "$(dirname "$0")"

rustup target add aarch64-unknown-linux-musl

# remap-path-prefix: panic locations must carry no host paths in shipped binaries
SYSROOT="$(rustc --print sysroot)"
export RUSTFLAGS="-C linker=rust-lld --remap-path-prefix=$HOME=/build --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rust --remap-path-prefix=$SYSROOT=/rustc-sysroot"
cargo build --locked --release --target aarch64-unknown-linux-musl

mkdir -p dist/aarch64
cp target/aarch64-unknown-linux-musl/release/ombra-askpass \
   target/aarch64-unknown-linux-musl/release/ombra-welcome \
   target/aarch64-unknown-linux-musl/release/ombra \
   target/aarch64-unknown-linux-musl/release/ombra-statusd \
   target/aarch64-unknown-linux-musl/release/ombra-torctl-filter \
   dist/aarch64/

ls -l dist/aarch64
file dist/aarch64/* 2>/dev/null || true
