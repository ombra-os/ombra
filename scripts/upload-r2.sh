#!/bin/bash
# Upload release files to a Cloudflare R2 bucket over its S3 API, then verify the public URL.
# usage: bash scripts/upload-r2.sh [file ...]
#          default: every build/releases/*.vmwarevm.zip and *.utm.zip, then SHA256SUMS.txt and SHA256SUMS.txt.sig.
#          Every archive SHA256SUMS.txt names must be here and match; a missing .sig is warned about loudly
#          (scripts/update/sign-sums.sh writes it), a .sig that does not verify against build/update-pubkey.pem stops it.
#        bash scripts/upload-r2.sh --prefix updates/ [file ...]
#          update files only (*.update, latest.txt, latest.txt.sig; default: build/releases/updates/), uploaded under
#          updates/: bundles first, then the index and its signature back to back. The index signature and every
#          bundle it names are checked first; the SHA256SUMS check does not apply.
# Settings come from an env file (default build/local/r2.env, git-ignored; override with R2_ENV_FILE):
#   R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_PUBLIC_BASE
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PUBKEY="$REPO/build/update-pubkey.pem"
PREFIX=""
if [ "${1:-}" = --prefix ]; then
  [ "${2:-}" = updates/ ] || { echo "FATAL: the only prefix is updates/" >&2; exit 2; }
  PREFIX=updates/; shift 2
fi

ENV_FILE="${R2_ENV_FILE:-$REPO/build/local/r2.env}"
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${R2_ACCESS_KEY_ID:?fill R2_ACCESS_KEY_ID in r2.env}"
: "${R2_SECRET_ACCESS_KEY:?fill R2_SECRET_ACCESS_KEY in r2.env}"
: "${R2_ENDPOINT:?}" "${R2_BUCKET:?}" "${R2_PUBLIC_BASE:?}"
command -v aws >/dev/null || { echo "FATAL: aws CLI not found (brew install awscli)" >&2; exit 1; }

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

# an openssl that can verify Ed25519 (macOS's own LibreSSL cannot)
ed25519_ok() { # file sig
  local c
  for c in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl; do
    [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 || continue
    "$c" pkey -pubin -in "$PUBKEY" -noout >/dev/null 2>&1 || continue
    "$c" pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1; return
  done
  echo "FATAL: no openssl here can verify Ed25519 (brew install openssl@3, or set OPENSSL=)" >&2; exit 1
}

if [ -z "$PREFIX" ]; then
  if [ "$#" -gt 0 ]; then FILES=("$@"); else
    R="$REPO/build/releases"
    FILES=("$R"/*.vmwarevm.zip "$R"/*.utm.zip)
    [ -f "$R/SHA256SUMS.txt" ] && FILES+=("$R/SHA256SUMS.txt")
    [ -f "$R/SHA256SUMS.txt.sig" ] && FILES+=("$R/SHA256SUMS.txt.sig")
  fi
  [ "${#FILES[@]}" -gt 0 ] && [ -e "${FILES[0]}" ] || { echo "FATAL: nothing to upload" >&2; exit 1; }
  SUMS="$REPO/build/releases/SHA256SUMS.txt"
  if [ -f "$SUMS" ]; then
    # every archive the published sums name must exist here, or the bucket would list hashes for files it lacks
    while read -r _ n; do
      [ -z "${n:-}" ] || [ -f "$REPO/build/releases/$n" ] || { echo "FATAL: SHA256SUMS.txt names $n, which is missing in build/releases" >&2; exit 1; }
    done < "$SUMS"
    if [ -f "$SUMS.sig" ]; then
      ed25519_ok "$SUMS" "$SUMS.sig" || { echo "FATAL: SHA256SUMS.txt.sig does not verify against build/update-pubkey.pem (re-sign after the last export)" >&2; exit 1; }
    else
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
      echo "WARNING: SHA256SUMS.txt.sig is missing: the hashes go out UNSIGNED, so" >&2
      echo "anyone who controls the bucket can swap images and hashes together." >&2
      echo "Sign first: bash scripts/update/sign-sums.sh <private-key> build/releases/SHA256SUMS.txt" >&2
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    fi
  fi
else
  if [ "$#" -gt 0 ]; then IN=("$@"); else IN=("$REPO"/build/releases/updates/*.update "$REPO"/build/releases/updates/latest.txt "$REPO"/build/releases/updates/latest.txt.sig); fi
  BUNDLES=(); IDX=""; IDXSIG=""
  for f in ${IN[@]+"${IN[@]}"}; do
    [ -f "$f" ] || { echo "FATAL: $f not found" >&2; exit 1; }
    case "$(basename "$f")" in
      *.update) BUNDLES+=("$f") ;;
      latest.txt) IDX=$f ;;
      latest.txt.sig) IDXSIG=$f ;;
      *) echo "FATAL: $f is not an update file (*.update, latest.txt, latest.txt.sig)" >&2; exit 1 ;;
    esac
  done
  [ -n "$IDX" ] && [ -n "$IDXSIG" ] || { echo "FATAL: --prefix updates/ needs latest.txt and latest.txt.sig" >&2; exit 1; }
  ed25519_ok "$IDX" "$IDXSIG" || { echo "FATAL: latest.txt.sig does not verify against build/update-pubkey.pem" >&2; exit 1; }
  # every bundle the index names must be uploaded in this run and match the index
  for key in $(awk -F= '$1 ~ /\.bundle$/ {print $1}' "$IDX"); do
    role=${key%.bundle}; name=$(awk -F= -v k="$key" '$1==k{print $2}' "$IDX"); want=$(awk -F= -v k="$role.sha256" '$1==k{print $2}' "$IDX")
    hit=""
    for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do [ "$(basename "$b")" = "$name" ] && hit=$b; done
    [ -n "$hit" ] || { echo "FATAL: latest.txt names $name, which is not among the files to upload" >&2; exit 1; }
    [ "$(shasum -a 256 "$hit" | cut -d' ' -f1)" = "$want" ] || { echo "FATAL: $name does not match latest.txt" >&2; exit 1; }
  done
  # bundles first, so the index never names a file that is not there yet
  FILES=(${BUNDLES[@]+"${BUNDLES[@]}"} "$IDX" "$IDXSIG")
fi

SUMS="$REPO/build/releases/SHA256SUMS.txt"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  case "$f" in *-test*|*TEST*) echo "FATAL: refusing a test build: $f" >&2; exit 1 ;; esac
  ctype=application/octet-stream
  case "$name" in SHA256SUMS.txt|latest.txt) ctype="text/plain; charset=utf-8" ;; esac
  if [ -z "$PREFIX" ] && [ -f "$SUMS" ] && [ "$name" != SHA256SUMS.txt ] && [ "$name" != SHA256SUMS.txt.sig ]; then
    want="$(awk -v n="$name" '$2==n{print $1}' "$SUMS")"
    [ -n "$want" ] || { echo "FATAL: $name is not in SHA256SUMS.txt" >&2; exit 1; }
    have="$(shasum -a 256 "$f" | awk '{print $1}')"
    [ "$have" = "$want" ] || { echo "FATAL: $name does not match SHA256SUMS.txt" >&2; exit 1; }
  fi
  size="$(stat -f %z "$f")"
  echo "uploading $PREFIX$name ($size bytes)"
  aws s3 cp "$f" "s3://$R2_BUCKET/$PREFIX$name" --endpoint-url "$R2_ENDPOINT" --content-type "$ctype" --content-disposition attachment
  got="$(curl -sI "$R2_PUBLIC_BASE/$PREFIX$name" | awk 'tolower($1)=="content-length:"{gsub("\r","",$2); print $2}')"
  status="$(curl -sI -o /dev/null -w '%{http_code}' "$R2_PUBLIC_BASE/$PREFIX$name")"
  if [ "$status" = 200 ] && [ "$got" = "$size" ]; then
    echo "ok: $R2_PUBLIC_BASE/$PREFIX$name ($got bytes)"
  else
    echo "FAIL: $R2_PUBLIC_BASE/$PREFIX$name returned HTTP $status, content-length ${got:-none} (expected $size)" >&2
    exit 1
  fi
done
