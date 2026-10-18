#!/bin/bash
# tests/build/test-public-hygiene.sh — leak guard for a public release tree.
# Greps every git-tracked file (minus the local allowlist) for personal leaks and
# internal naming. Standalone-runnable; also invoked early by test-install-iso.sh.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ALLOWLIST="$HERE/.hygiene-allowlist"

FAILS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "FAIL: $REPO is not a git work tree"; exit 1; }

# the allowlist is a local escape hatch; tracked, it would be a leak of its own
[ -z "$(git -C "$REPO" ls-files "$ALLOWLIST")" ] \
  || { echo "FAIL: tests/build/.hygiene-allowlist is git-tracked — keep it local (.gitignore carries it)"; exit 1; }

FILES=()
while IFS= read -r f; do
  # this file carries the literal patterns it greps for
  [ "$f" = "tests/build/test-public-hygiene.sh" ] && continue
  FILES+=("$f")
done < <(git -C "$REPO" ls-files)

if [ -f "$ALLOWLIST" ]; then
  SKIP=()
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    case "$prefix" in '#'*) continue ;; esac
    SKIP+=("$prefix")
  done < "$ALLOWLIST"
  FILTERED=()
  for f in "${FILES[@]}"; do
    keep=1
    for prefix in "${SKIP[@]}"; do
      case "$f" in "$prefix"*) keep=0; break ;; esac
    done
    [ "$keep" = 1 ] && FILTERED+=("$f")
  done
  FILES=("${FILTERED[@]}")
  ok "allowlist applied ($( [ ${#SKIP[@]} -gt 0 ] && echo ${#SKIP[@]} || echo 0 ) prefixes, local only)"
fi

# 192.168 requires a digit after the dot: the leak suite's own private-range
# glob (192.168.*) is a functional guard whose text must not change
PATTERNS='hac''cer|/Us''ers/|192\.168\.[0-9]|co''dy@'
HITS=0
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || continue
  found="$(grep -InEi "$PATTERNS" -- "$REPO/$f" 2>/dev/null)" || true
  [ -z "$found" ] && continue
  while IFS= read -r line; do
    bad "leak: $f:$line"
  done <<< "$found"
  HITS=$((HITS+1))
done

if [ "$HITS" = 0 ]; then
  ok "no leak patterns in ${#FILES[@]} tracked files"
else
  echo "FAILED: $HITS file(s) with leak patterns"
  exit 1
fi
