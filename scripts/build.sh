#!/bin/bash
# Guided build of Ombra from source on an Apple Silicon Mac with VMware Fusion.
#
#   curl -fsSL https://ombra-os.org/build.sh | bash
#   bash scripts/build.sh [--dir PATH] [--yes] [--isos-only]
#
# Environment: OMBRA_REPO_URL overrides the clone source.

set -euo pipefail

REPO_URL="${OMBRA_REPO_URL:-https://github.com/ombra-os/ombra}"
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
VMROOT="$HOME/Virtual Machines.localized"
NEED_GB=50

DIR=""
ASSUME_YES=0
ISOS_ONLY=0

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; X=$'\033[0m'
else
  B=""; D=""; G=""; R=""; Y=""; X=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$X" "$*"; }
warn() { printf '  %s!!%s    %s\n' "$Y" "$X" "$*"; }
die()  { printf '\n%sFAILED%s %s\n' "$R" "$X" "$*" >&2; exit 1; }

ask() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply=""
  if [ -r /dev/tty ]; then
    printf '%s [y/N] ' "$1" > /dev/tty
    read -r reply < /dev/tty || true
  fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
  say "usage: build.sh [--dir PATH] [--yes] [--isos-only]"
  say "  --dir PATH    where to clone and build (default: ~/ombra)"
  say "  --yes         answer yes to every prompt"
  say "  --isos-only   stop after building the two installer ISOs"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) [ "$#" -ge 2 ] || die "--dir needs a path"; DIR="$2"; shift 2 ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --isos-only) ISOS_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
}

check_host() {
  step "Checking this Mac"
  [ "$(uname -s)" = Darwin ] || die "this builds Ombra on macOS"
  [ "$(uname -m)" = arm64 ] || die "Apple Silicon is required (this Mac reports $(uname -m))"
  [ "$(id -u)" != 0 ] || die "do not run as root"
  ok "Apple Silicon Mac"
  if [ "$ISOS_ONLY" = 0 ]; then
    [ -x "$VMRUN" ] || die "VMware Fusion not found; install it from vmware.com, then run this again"
    ok "VMware Fusion"
  fi
  local free_gb
  free_gb="$(df -g "$HOME" | awk 'NR==2{print $4}')"
  [ "${free_gb:-0}" -ge "$NEED_GB" ] || die "need about ${NEED_GB} GB free, found ${free_gb:-0} GB"
  ok "${free_gb} GB free"
}

ensure_tools() {
  step "Checking tools"
  local missing=""
  command -v git >/dev/null 2>&1 || missing="$missing git"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  command -v xorriso >/dev/null 2>&1 || missing="$missing xorriso"
  command -v rustup >/dev/null 2>&1 || missing="$missing rustup"
  if [ -z "$missing" ]; then
    ok "git, python3, xorriso, rustup"
    return 0
  fi
  warn "missing:$missing"
  case "$missing" in *git*|*python3*) die "install the Xcode command line tools first: xcode-select --install" ;; esac
  command -v brew >/dev/null 2>&1 || die "Homebrew is needed to install$missing: https://brew.sh"
  ask "Install$missing with Homebrew?" || die "install$missing, then run this again"
  case "$missing" in *xorriso*) brew install xorriso ;; esac
  case "$missing" in *rustup*) brew install rustup ;; esac
  command -v xorriso >/dev/null 2>&1 || die "xorriso is still missing"
  if ! command -v rustup >/dev/null 2>&1; then
    local prefix
    prefix="$(brew --prefix rustup 2>/dev/null || true)"
    [ -x "$prefix/bin/rustup" ] && export PATH="$prefix/bin:$PATH"
  fi
  command -v rustup >/dev/null 2>&1 || die "rustup is still missing"
  ok "tools installed"
}

get_source() {
  step "Getting the source"
  if [ -z "$DIR" ]; then
    if [ -f "core/build.sh" ] && [ -f "build/make-install-iso.sh" ]; then
      DIR="$PWD"
    else
      DIR="$HOME/ombra"
    fi
  fi
  if [ -d "$DIR/.git" ]; then
    ok "using $DIR"
  else
    [ ! -e "$DIR" ] || die "$DIR exists and is not an Ombra checkout"
    git clone --depth 1 "$REPO_URL" "$DIR"
    ok "cloned to $DIR"
  fi
  cd "$DIR"
}

LOG=""
run() {
  local label="$1"; shift
  [ -n "$LOG" ] || { mkdir -p build/logs; LOG="$PWD/build/logs/build.log"; : > "$LOG"; }
  if ! "$@" >> "$LOG" 2>&1; then
    tail -n 25 "$LOG" >&2
    die "$label failed (full log: $LOG)"
  fi
}

pin() { awk -F= -v k="$2" '$1==k{print substr($0, index($0,"=")+1)}' "$1"; }

fetch_pins() {
  step "Fetching the pinned downloads"
  local filename version want file url
  filename="$(pin build/pins/debian-netinst-arm64.txt filename)"
  version="$(printf '%s' "$filename" | sed -E 's/^debian-([0-9.]+)-arm64-netinst.iso$/\1/')"
  mkdir -p build/isos build/vendor
  if bash build/verify-iso.sh >/dev/null 2>&1; then
    ok "Debian installer already verified"
  else
    say "  downloading $filename"
    curl -fL --retry 3 -o "build/isos/$filename" \
      "https://cdimage.debian.org/cdimage/archive/${version}/arm64/iso-cd/${filename}"
    bash build/verify-iso.sh >/dev/null || die "the Debian installer failed its checksum"
    ok "Debian installer verified"
  fi
  url="$(pin build/pins/torbrowser.txt url)"
  file="$(pin build/pins/torbrowser.txt file)"
  want="$(pin build/pins/torbrowser.txt sha256)"
  if [ -f "build/vendor/$file" ] && [ "$(shasum -a 256 "build/vendor/$file" | awk '{print $1}')" = "$want" ]; then
    ok "Tor Browser already verified"
  else
    say "  downloading $file"
    curl -fL --retry 3 -o "build/vendor/$file" "${url}${file}"
    [ "$(shasum -a 256 "build/vendor/$file" | awk '{print $1}')" = "$want" ] || die "Tor Browser failed its checksum"
    ok "Tor Browser verified"
  fi
}

build_isos() {
  step "Building the binaries and installer ISOs"
  run "the Rust build" bash -c 'cd core && bash build.sh'
  cp core/dist/aarch64/ombra-askpass core/dist/aarch64/ombra-welcome desktop/rootfs/usr/local/libexec/ombra/
  cp core/dist/aarch64/ombra core/dist/aarch64/ombra-statusd desktop/rootfs/usr/local/bin/
  cp core/dist/aarch64/ombra core/dist/aarch64/ombra-torctl-filter gateway/rootfs/usr/local/bin/
  ok "binaries built"
  run "the gateway ISO" bash build/make-install-iso.sh gateway
  run "the desktop ISO" bash build/make-install-iso.sh desktop
  ok "build/disks/ombra-install-gateway.iso"
  ok "build/disks/ombra-install-desktop.iso"
}

vm_running() { "$VMRUN" -T fusion list 2>/dev/null | grep -q "$1"; }

wait_for_poweroff() {
  local name="$1" seen=0 gone=0
  say "  installing $name (unattended, this takes several minutes)"
  while :; do
    if vm_running "$name.vmx"; then seen=1; gone=0; else
      [ "$seen" = 1 ] && gone=$((gone + 1))
    fi
    [ "$gone" -ge 3 ] && break
    sleep 20
  done
  ok "$name installed"
}

build_vms() {
  step "Creating the gateway"
  [ ! -e "$VMROOT/ombra-gateway.vmwarevm" ] || die "$VMROOT/ombra-gateway.vmwarevm already exists; move it away first"
  [ ! -e "$VMROOT/ombra-desktop.vmwarevm" ] || die "$VMROOT/ombra-desktop.vmwarevm already exists; move it away first"
  run "creating the gateway" bash build/fusion/create-gateway-vm.sh
  wait_for_poweroff ombra-gateway
  run "the gateway finish step" bash build/fusion/post-install-gateway.sh
  ok "gateway running"
  step "Creating the desktop"
  say "  the gateway stays running: the desktop's network goes through it"
  run "creating the desktop" bash build/fusion/create-desktop-vm.sh
  wait_for_poweroff ombra-desktop
  run "the desktop finish step" bash build/fusion/post-install-desktop.sh
  ok "desktop started"
}

finish() {
  step "Done"
  say "  1. In the desktop window, choose ${B}Persistent${X} at the boot menu"
  say "  2. Unlock with the build passphrase ${B}ombra-disk${X}"
  say "  3. Set your own disk passphrase and password; the disk re-encrypts under a new key"
  say "  4. The machine restarts; unlock with your passphrase"
  say ""
  say "  ${D}Details: docs/INSTALL.md${X}"
}

main() {
  parse_args "$@"
  say "${B}Ombra${X} builds two virtual machines on this Mac: a Tor gateway and a desktop."
  say "It downloads two pinned files, builds locally, and creates both VMs in VMware Fusion."
  ask "Continue?" || { say "Nothing was changed."; exit 0; }
  check_host
  ensure_tools
  get_source
  fetch_pins
  build_isos
  if [ "$ISOS_ONLY" = 1 ]; then
    step "Done"
    say "  ISOs are in $DIR/build/disks"
    exit 0
  fi
  build_vms
  finish
}

main "$@"
