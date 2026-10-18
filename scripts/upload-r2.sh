#!/bin/bash
# Upload release images to a Cloudflare R2 bucket over its S3 API, then verify the public URL.
# usage: bash scripts/upload-r2.sh [file ...]   (default: every build/releases/*.ova plus SHA256SUMS.txt)
# Settings come from an env file (default build/local/r2.env, git-ignored; override with R2_ENV_FILE):
#   R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_PUBLIC_BASE
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ENV_FILE="${R2_ENV_FILE:-$REPO/build/local/r2.env}"
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${R2_ACCESS_KEY_ID:?fill R2_ACCESS_KEY_ID in r2.env}"
: "${R2_SECRET_ACCESS_KEY:?fill R2_SECRET_ACCESS_KEY in r2.env}"
: "${R2_ENDPOINT:?}" "${R2_BUCKET:?}" "${R2_PUBLIC_BASE:?}"
command -v aws >/dev/null || { echo "FATAL: aws CLI not found (brew install awscli)" >&2; exit 1; }

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

if [ "$#" -gt 0 ]; then FILES=("$@"); else FILES=("$REPO"/build/releases/*.ova "$REPO"/build/releases/SHA256SUMS.txt); fi
[ -e "${FILES[0]}" ] || { echo "FATAL: nothing to upload" >&2; exit 1; }

SUMS="$REPO/build/releases/SHA256SUMS.txt"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  case "$f" in *-test*|*TEST*) echo "FATAL: refusing a test build: $f" >&2; exit 1 ;; esac
  ctype=application/octet-stream
  [ "$name" = SHA256SUMS.txt ] && ctype="text/plain; charset=utf-8"
  if [ -f "$SUMS" ] && [ "$name" != SHA256SUMS.txt ]; then
    want="$(awk -v n="$name" '$2==n{print $1}' "$SUMS")"
    [ -n "$want" ] || { echo "FATAL: $name is not in SHA256SUMS.txt" >&2; exit 1; }
    have="$(shasum -a 256 "$f" | awk '{print $1}')"
    [ "$have" = "$want" ] || { echo "FATAL: $name does not match SHA256SUMS.txt" >&2; exit 1; }
  fi
  size="$(stat -f %z "$f")"
  echo "uploading $name ($size bytes)"
  aws s3 cp "$f" "s3://$R2_BUCKET/$name" --endpoint-url "$R2_ENDPOINT" --content-type "$ctype" --content-disposition attachment
  got="$(curl -sI "$R2_PUBLIC_BASE/$name" | awk 'tolower($1)=="content-length:"{gsub("\r","",$2); print $2}')"
  status="$(curl -sI -o /dev/null -w '%{http_code}' "$R2_PUBLIC_BASE/$name")"
  if [ "$status" = 200 ] && [ "$got" = "$size" ]; then
    echo "ok: $R2_PUBLIC_BASE/$name ($got bytes)"
  else
    echo "FAIL: $R2_PUBLIC_BASE/$name returned HTTP $status, content-length ${got:-none} (expected $size)" >&2
    exit 1
  fi
done
