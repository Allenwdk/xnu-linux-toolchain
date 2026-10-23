#!/usr/bin/env bash
# Apply the UniXNU XNU patch series to a scratch clone exactly the way
# build-xnu-4k-baseline.sh does, and report the first patch that fails.
#   scripts/check-xnu-patches.sh [device-repo]
set -uo pipefail
CORE=${UNIXNU_CORE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DEVICE=${1:-$CORE/../UniXNU-uke}
XNU_SRC=${XNU_SRC:-$CORE/out/uke/tree/refer/xnu}
if [ ! -d "$XNU_SRC/.git" ]; then
  # The driver re-clones refer/xnu into the tree on each run and the assembled
  # tree can be rebuilt out from under us; the pinned feed is the same tree.
  XNU_SRC=$(ls -d "$CORE"/out/feeds/xnu-*/ 2>/dev/null | head -1)
fi
WORK=${WORK:-/tmp/xnu-patch-check}

if [ ! -d "$XNU_SRC/.git" ]; then
  echo "check-xnu-patches: $XNU_SRC is not an xnu clone" >&2
  exit 2
fi
rm -rf "$WORK"
git clone --quiet --shared "$XNU_SRC" "$WORK"
git -C "$WORK" checkout -q d8b80295118ef25ac3a784134bcf95cd8e88109f

apply() {
  local patch=$1
  if git -C "$WORK" apply --reverse --check "$patch" >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$WORK" apply --check "$patch" 2>/tmp/xnu-patch-err; then
    echo "FAIL $(basename "$patch"): $(head -1 /tmp/xnu-patch-err)"
    return 1
  fi
  git -C "$WORK" apply "$patch" || { echo "FAIL $(basename "$patch"): apply"; return 1; }
}

# Same order as build-xnu-4k-baseline.sh: the audit patch first, then the fork
# set and the device set in sorted order, with the two late patches reversed
# when the cached tree already carries them.
AUDIT=$CORE/patches/xnu/offline-owner-root-binding-audit.patch
if [ -f "$AUDIT" ] && ! grep -q 'native_owner_root_apple_autherr' "$WORK/bsd/kern/bsd_init.c"; then
  apply "$AUDIT" || exit 1
fi

for dir in "$CORE/patches/xnu" "$DEVICE/patches/xnu" "$DEVICE/kits/NativePrelink/patches"; do
  [ -d "$dir" ] || continue
  while IFS= read -r patch; do
    [ "$patch" = "$AUDIT" ] && continue
    apply "$patch" || exit 1
  done < <(find "$dir" -maxdepth 1 -name '*.patch' | sort)
done

echo "all patches applied cleanly to $WORK"
