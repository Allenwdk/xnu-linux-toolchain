#!/usr/bin/env bash
#
# Source this before an XNU build on Linux:
#
#   source /path/to/xnu-linux-toolchain/env.sh
#
# It puts the shims and the cctools/LLVM tools on PATH and exports the
# variables the shims read. Build-specific values -- the fakeroot that
# build-xnu-4k-baseline.sh assembles, the device name -- belong to the project
# and are layered on top; see README.md.
#
# Re-sourcing is safe.
#

XNU_LINUX_PREFIX="${XNU_LINUX_PREFIX:-$HOME/.local/xnu-linux}"
_XNL_SELF="${BASH_SOURCE[0]:-$0}"
XNU_LINUX_REPO="$(cd "$(dirname "$_XNL_SELF")" && pwd)"

if [ ! -x "$XNU_LINUX_PREFIX/bin/migcom" ]; then
  echo "env.sh: $XNU_LINUX_PREFIX is not a bootstrapped prefix" >&2
  echo "env.sh: run $XNU_LINUX_REPO/bootstrap.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# shims first so `ld`, `ar`, `strip`, `iig`, `plutil`, `xcrun` resolve here
export PATH="$XNU_LINUX_PREFIX/bin:$PATH"
export XNU_LINUX_PREFIX XNU_LINUX_REPO

# the xcrun shim resolves tools under $UNIXNU_SHIM
export UNIXNU_SHIM="$XNU_LINUX_PREFIX/bin"

# <mach-o/*.h> for xnu's SETUP host tools (kextsymboltool, setsegname)
export UNIXNU_HOST_CCTOOLS_INCLUDE="${UNIXNU_HOST_CCTOOLS_INCLUDE:-$XNU_LINUX_PREFIX/cctools/include}"

# override the C compiler the shims drive, if it is not plain `clang`
export XNU_LINUX_CLANG="${XNU_LINUX_CLANG:-clang}"

export JOBS="${JOBS:-$(nproc)}"

# IIG output is small but the .iig.cpp side is what the kernel link wants;
# leave this unset so the shim generates everything from the .iig sources.
unset UNIXNU_DRIVERKIT_KERNEL_DIR 2>/dev/null || true


# The project's own build scripts rebuild the warning set from a recorded
# command line (they strip -W* and add their own), so a compiler wrapper cannot
# inject flags and -MJ records the real compiler path. CCC_OVERRIDE_OPTIONS is
# read by the clang driver itself and appended after every other argument.
#
# toolchain/werror-exceptions.txt lists the diagnostics that fire on the
# existing sources; each becomes non-fatal. Everything else stays fatal, so a
# real problem in new driver code still stops the build.
if [ -f "$XNU_LINUX_PREFIX/bin/werror-exceptions.txt" ]; then
  _wno="$XNU_LINUX_PREFIX/bin/werror-exceptions.txt"
elif [ -f "$XNU_LINUX_REPO/toolchain/werror-exceptions.txt" ]; then
  _wno="$XNU_LINUX_REPO/toolchain/werror-exceptions.txt"
else
  _wno=""
fi
if [ -n "$_wno" ]; then
  _args=""
  while IFS= read -r _diag; do
    case "$_diag" in ''|'#'*) continue;; esac
    _args="$_args +-Wno-error=$_diag"
  done < "$_wno"
  export CCC_OVERRIDE_OPTIONS="${CCC_OVERRIDE_OPTIONS:-$_args}"
fi
unset _wno _diag _args

unset _XNL_SELF
