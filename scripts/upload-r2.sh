#!/bin/bash
# Upload release files to a Cloudflare R2 bucket over its S3 API, then verify the public URL. Every file must first pass
# the OPSEC gate (scripts/release-opsec-check.sh), which records each passed file's sha256 in build/releases/.opsec-ok.
# usage: bash scripts/upload-r2.sh [file ...]
#          default: every build/releases/*.vmwarevm.zip and *.utm.zip, then SHA256SUMS.txt and SHA256SUMS.txt.sig.
#          Nothing is uploaded unsigned: SHA256SUMS.txt and its .sig (scripts/update/sign-sums.sh) must exist and verify
#          against build/update-pubkey.pem, every archive uploaded must match its line, and the sums and .sig go together.
#        bash scripts/upload-r2.sh --prefix updates/ [file ...]
#          update files only (*.update, latest.txt, apps.txt and their .sig; apps.txt alone for an app-only release;
#          default: build/releases/updates/), uploaded under
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
  # nothing goes out unsigned: every archive must be named in SHA256SUMS.txt, and SHA256SUMS.txt must carry a
  # signature that verifies against the shipped public key, before any file is uploaded
  [ -f "$SUMS" ] || { echo "FATAL: build/releases/SHA256SUMS.txt is missing: nothing is uploaded unsigned" >&2; exit 1; }
  [ -f "$SUMS.sig" ] || { echo "FATAL: SHA256SUMS.txt.sig is missing: sign first (scripts/update/sign-sums.sh); nothing is uploaded unsigned" >&2; exit 1; }
  ed25519_ok "$SUMS" "$SUMS.sig" || { echo "FATAL: SHA256SUMS.txt.sig does not verify against build/update-pubkey.pem (re-sign after the last export)" >&2; exit 1; }
  # every archive the published sums name must exist here, or the bucket would list hashes for files it lacks
  while read -r _ n; do
    [ -z "${n:-}" ] || [ -f "$REPO/build/releases/$n" ] || { echo "FATAL: SHA256SUMS.txt names $n, which is missing in build/releases" >&2; exit 1; }
  done < "$SUMS"
  # the checksums and their signature go up together, never one without the other
  has_sums=0; has_sig=0
  for f in "${FILES[@]}"; do
    case "$(basename "$f")" in SHA256SUMS.txt) has_sums=1 ;; SHA256SUMS.txt.sig) has_sig=1 ;; esac
  done
  [ "$has_sums" = "$has_sig" ] || { echo "FATAL: SHA256SUMS.txt and SHA256SUMS.txt.sig are uploaded together" >&2; exit 1; }
else
  if [ "$#" -gt 0 ]; then IN=("$@"); else
    U="$REPO/build/releases/updates"; IN=("$U"/*.update "$U/latest.txt" "$U/latest.txt.sig")
    [ ! -f "$U/apps.txt" ] || IN+=("$U/apps.txt" "$U/apps.txt.sig")
  fi
  BUNDLES=(); IDX=""; IDXSIG=""; APPS=""; APPSSIG=""
  for f in ${IN[@]+"${IN[@]}"}; do
    [ -f "$f" ] || { echo "FATAL: $f not found" >&2; exit 1; }
    case "$(basename "$f")" in
      *.update) BUNDLES+=("$f") ;;
      latest.txt) IDX=$f ;;
      latest.txt.sig) IDXSIG=$f ;;
      apps.txt) APPS=$f ;;
      apps.txt.sig) APPSSIG=$f ;;
      *) echo "FATAL: $f is not an update file (*.update, latest.txt, apps.txt and their .sig)" >&2; exit 1 ;;
    esac
  done
  # an app-only release uploads apps.txt and its .sig alone; anything else needs the index pair
  if [ -n "$IDX$IDXSIG" ] || [ "${#BUNDLES[@]}" -gt 0 ] || [ -z "$APPS$APPSSIG" ]; then
    [ -n "$IDX" ] && [ -n "$IDXSIG" ] || { echo "FATAL: --prefix updates/ needs latest.txt and latest.txt.sig" >&2; exit 1; }
    ed25519_ok "$IDX" "$IDXSIG" || { echo "FATAL: latest.txt.sig does not verify against build/update-pubkey.pem" >&2; exit 1; }
    grep -qx 'type=index' "$IDX" || { echo "FATAL: latest.txt has no type=index line (make it with make-index.sh)" >&2; exit 1; }
  fi
  if [ -n "$APPS$APPSSIG" ]; then
    [ -n "$APPS" ] && [ -n "$APPSSIG" ] || { echo "FATAL: apps.txt and apps.txt.sig go together" >&2; exit 1; }
    ed25519_ok "$APPS" "$APPSSIG" || { echo "FATAL: apps.txt.sig does not verify against build/update-pubkey.pem" >&2; exit 1; }
    grep -qx 'type=apps' "$APPS" || { echo "FATAL: apps.txt has no type=apps line (make it with make-apps.sh)" >&2; exit 1; }
  fi
  # every bundle the index names must be uploaded in this run and match the index
  for key in $( [ -z "$IDX" ] || awk -F= '$1 ~ /\.bundle$/ {print $1}' "$IDX"); do
    role=${key%.bundle}; name=$(awk -F= -v k="$key" '$1==k{print $2}' "$IDX"); want=$(awk -F= -v k="$role.sha256" '$1==k{print $2}' "$IDX")
    hit=""
    for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do [ "$(basename "$b")" = "$name" ] && hit=$b; done
    [ -n "$hit" ] || { echo "FATAL: latest.txt names $name, which is not among the files to upload" >&2; exit 1; }
    [ "$(shasum -a 256 "$hit" | cut -d' ' -f1)" = "$want" ] || { echo "FATAL: $name does not match latest.txt" >&2; exit 1; }
  done
  # bundles first, so the index never names a file that is not there yet
  FILES=(${BUNDLES[@]+"${BUNDLES[@]}"})
  [ -z "$IDX" ] || FILES+=("$IDX" "$IDXSIG")
  [ -z "$APPS" ] || FILES+=("$APPS" "$APPSSIG")
fi

SUMS="$REPO/build/releases/SHA256SUMS.txt"
# the OPSEC gate (scripts/release-opsec-check.sh) must have passed every file, exactly as it is now
GATE="$REPO/build/releases/.opsec-ok"
for f in "${FILES[@]}"; do
  rel="$PREFIX$(basename "$f")"
  [ -f "$GATE" ] && [ "$(grep -c -x -F "$(shasum -a 256 "$f" | cut -d' ' -f1)  $rel" "$GATE" || true)" = 1 ] \
    || { echo "FATAL: $rel has not passed the OPSEC gate as it is now: run bash scripts/release-opsec-check.sh" >&2; exit 1; }
done
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  case "$f" in *-test*|*TEST*) echo "FATAL: refusing a test build: $f" >&2; exit 1 ;; esac
  ctype=application/octet-stream
  case "$name" in SHA256SUMS.txt|latest.txt|apps.txt) ctype="text/plain; charset=utf-8" ;; esac
  if [ -z "$PREFIX" ] && [ "$name" != SHA256SUMS.txt ] && [ "$name" != SHA256SUMS.txt.sig ]; then
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
