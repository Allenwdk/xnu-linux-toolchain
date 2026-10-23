#!/usr/bin/env bash
#
# Build the Linux XNU build toolchain into a prefix.
#
#   ./bootstrap.sh [--prefix DIR] [--jobs N] [--fetch-only]
#
# Produces:
#   $PREFIX/bin/        the shims (iig, plutil, xcrun, ld, ar, ...) plus the
#                       tools built here: mig, migcom, lzfse, unifdef, tcsh
#   $PREFIX/cctools/    cctools-port: Apple's ld64, ar, strip, nm, otool,
#                       lipo, libtool, nmedit, codesign_allocate, ranlib
#
# Everything outside $PREFIX is a system dependency; the checklist is in
# README.md. Run this once, then `source env.sh`.
#
set -euo pipefail

PREFIX=${XNU_LINUX_PREFIX:-$HOME/.local/xnu-linux}
JOBS=${JOBS:-$(nproc)}
FETCH_ONLY=0
WORK=${XNU_LINUX_WORK:-$PREFIX/src}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=$2; shift 2;;
    --jobs) JOBS=$2; shift 2;;
    --fetch-only) FETCH_ONLY=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "bootstrap.sh: unknown option $1" >&2; exit 2;;
  esac
done

log() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "bootstrap.sh: missing $1 -- $2" >&2; exit 1; }; }

log "checking system dependencies"
need git    'install git'
need cmake  'install cmake'
need make   'install make'
need clang  'install clang 10 or newer'
need python3 'install python3'
need flex   'install flex'
need bison  'install bison'
need autoconf 'install autoconf'
need automake 'install automake'
need pkg-config 'install pkg-config'

# cctools-port's ld64 needs a blocks runtime and libdispatch. Distro packages
# are fine; the fallback is the sources named in README.md.
if ! ldconfig -p 2>/dev/null | grep -q libdispatch; then
  echo "bootstrap.sh: libdispatch not found -- install it (Arch: pacman -S libdispatch)" >&2
  exit 1
fi

mkdir -p "$PREFIX/bin" "$PREFIX/cctools" "$WORK"

clone() { # <dir> <url> <branch>
  if [ ! -d "$WORK/$1/.git" ]; then
    git clone --depth 1 ${3:+--branch "$3"} "$2" "$WORK/$1"
  fi
}

if [ "$FETCH_ONLY" = 1 ]; then
  log "fetching sources"
  clone mig https://github.com/markmentovai/bootstrap_cmds.git cross_platform
  clone cctools-port https://github.com/tpoechtrager/cctools-port.git
  clone lzfse https://github.com/lzfse/lzfse.git
  clone unifdef https://github.com/fanf2/unifdef.git
  clone tcsh https://github.com/tcsh-org/tcsh.git
  exit 0
fi

log "building mig / migcom (bootstrap_cmds)"
clone mig https://github.com/markmentovai/bootstrap_cmds.git cross_platform
(
  cd "$WORK/mig"
  autoreconf --install >/dev/null
  ./configure --prefix="$PREFIX" >/dev/null
  make -j"$JOBS" >/dev/null
  install -m755 migcom.tproj/migcom "$PREFIX/bin/migcom"
  install -m755 migcom.tproj/mig.sh "$PREFIX/bin/mig"
)

log "building lzfse"
clone lzfse https://github.com/lzfse/lzfse.git
(
  cd "$WORK/lzfse"
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
  cmake --build build -j"$JOBS" >/dev/null
  install -m755 build/lzfse "$PREFIX/bin/lzfse"
)

log "building unifdef"
clone unifdef https://github.com/fanf2/unifdef.git
(
  cd "$WORK/unifdef"
  make -j"$JOBS" >/dev/null
  install -m755 unifdef "$PREFIX/bin/unifdef"
)

log "building tcsh (xnu's SETUP/config/doconf is a csh script)"
clone tcsh https://github.com/tcsh-org/tcsh.git
if [ -x "$WORK/tcsh/configure" ] || [ -f "$WORK/tcsh/configure.ac" ]; then
  (
    cd "$WORK/tcsh"
    [ -x ./configure ] || sh ./configure.gnu >/dev/null 2>&1 || autoreconf --install >/dev/null
    ./configure --prefix="$PREFIX" >/dev/null
    make -j"$JOBS" >/dev/null
    install -m755 tcsh "$PREFIX/bin/tcsh"
  )
fi

log "building cctools-port"
clone cctools-port https://github.com/tpoechtrager/cctools-port.git
(
  cd "$WORK/cctools-port/cctools"
  ./configure --prefix="$PREFIX/cctools" >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
  # the kernel's SETUP tools include <mach-o/*.h>; cctools ships them but its
  # `make install` does not
  mkdir -p "$PREFIX/cctools/include"
  cp -r include/. "$PREFIX/cctools/include/"
)

log "installing shims"
cp -f "$REPO"/toolchain/* "$PREFIX/bin/"
cp -f "$REPO/env.sh" "$PREFIX/env.sh"
chmod +x "$PREFIX/bin/"*
ln -sf tcsh "$PREFIX/bin/csh" 2>/dev/null || true

log "done"
echo
echo "  prefix : $PREFIX"
echo "  next   : source $REPO/env.sh"
echo
"$PREFIX/bin/migcom" -version 2>/dev/null | head -1 || true
"$PREFIX/cctools/bin/ld" -v 2>&1 | head -1 || true
