#!/usr/bin/env bash
#
# Copy the xnu portability patches into a UniXNU device repository (or any tree
# whose build applies patches from a patches/xnu/ directory).
#
#   scripts/sync-patches.sh /path/to/UniXNU-uke
#
# This repository is the source of truth for those patches; the device tree
# carries a copy because build-xnu-4k-baseline.sh applies the series from
# <device>/patches/xnu/ with `find | sort`.
#
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEST=${1:-}

if [ -z "$DEST" ]; then
  echo "usage: sync-patches.sh <device-repo>" >&2
  exit 2
fi
if [ ! -d "$DEST/patches/xnu" ]; then
  echo "sync-patches.sh: $DEST/patches/xnu does not exist" >&2
  exit 1
fi

for patch in "$REPO"/patches/xnu/*.patch; do
  name=$(basename "$patch")
  if [ -f "$DEST/patches/xnu/$name" ] && cmp -s "$patch" "$DEST/patches/xnu/$name"; then
    echo "same   $name"
    continue
  fi
  cp "$patch" "$DEST/patches/xnu/$name"
  echo "synced $name"
done
