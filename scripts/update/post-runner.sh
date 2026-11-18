#!/bin/sh
# post.sh for update payloads: ombra-update runs /usr/local/lib/ombra-update/post.sh once after the files land
# (every installed version since 1.1 does). This runner runs each step in post.d in name order, stops at the
# first failure (ombra-update then rolls the whole update back) and removes the steps once all succeeded.
set -eu
D=/usr/local/lib/ombra-update/post.d
[ -d "$D" ] || exit 0
for step in "$D"/*; do
    [ -f "$step" ] || continue
    echo "post step: ${step##*/}"
    sh "$step" "$@"
done
rm -rf "$D"
