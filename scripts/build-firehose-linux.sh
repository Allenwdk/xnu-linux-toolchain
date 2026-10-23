#!/usr/bin/env bash
# Build libfirehose_kernel without xcodebuild.
#
# The Xcode target compiles exactly one file, src/firehose/firehose_buffer.c,
# which needs two MIG outputs (firehose.h from firehose.defs as a client, and
# firehose_replyServer.h from firehose_reply.defs as a server). Everything else
# it includes comes from the fakeroot KERNEL_SDKROOT that build-xnu-4k-baseline.sh
# assembles.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [ ! -d .cache/libdispatch-work/.git ]; then
  git clone --shared refer/libdispatch .cache/libdispatch-work
fi
SRC=.cache/libdispatch-work
OUT=$ROOT/build/firehose/linux
FAKEROOT=$ROOT/.cache/fakeroot
XNU=$ROOT/.cache/xnu-work
mkdir -p "$OUT" "$FAKEROOT/usr/local/lib/kernel"

CC=${CC:-$(command -v clang)}
MIG=${MIG:-$(command -v mig)}
MIGCOM=${MIGCOM:-$(command -v migcom)}
LIBTOOL=${LIBTOOL:-$(command -v libtool)}

# The firehose private headers (chunk_private.h, tracepoint_private.h,
# firehose_types_private.h) are SDK private headers, not part of libdispatch or
# of xnu's installhdrs output. They live under $FAKEROOT/usr/local/include/firehose.
for header in chunk_private.h tracepoint_private.h firehose_types_private.h; do
  if [ ! -f "$FAKEROOT/usr/local/include/firehose/$header" ]; then
    echo "build-firehose-linux: $FAKEROOT/usr/local/include/firehose/$header missing" >&2
    exit 1
  fi
done

# sys/types.h pulls in the SDK's sys/_pthread/_pthread_*.h typedef headers.
# They are not part of xnu's installhdrs output; stage them from the one
# xnu does ship (EXTERNAL_HEADERS/sys/_pthread/_pthread_types.h) so the
# include chain resolves.
PTHREAD_DIR=$FAKEROOT/usr/include/sys/_pthread
if [ ! -f "$PTHREAD_DIR/_pthread_attr_t.h" ]; then
  mkdir -p "$PTHREAD_DIR"
  cp "$XNU/EXTERNAL_HEADERS/sys/_pthread/_pthread_types.h" "$PTHREAD_DIR/" 2>/dev/null || true
  for spec in attr_t:pthread_attr_t cond_t:pthread_cond_t \
              condattr_t:pthread_condattr_t mutex_t:pthread_mutex_t \
              mutexattr_t:pthread_mutexattr_t once_t:pthread_once_t \
              rwlock_t:pthread_rwlock_t rwlockattr_t:pthread_rwlockattr_t \
              t:pthread_t key_t:pthread_key_t; do
    name=${spec%%:*}; type=${spec##*:}
    guard=$(echo "_SYS__PTHREAD_${name}_H_" | tr '[:lower:]' '[:upper:]')
    darwin=$(echo "__darwin_${type}")
    cat > "$PTHREAD_DIR/_pthread_${name}.h" <<EOF
#ifndef $guard
#define $guard
#include <sys/_pthread/_pthread_types.h>
typedef $darwin $type;
#endif
EOF
  done
fi

MIGFLAGS=(-novouchers -DOS_FIREHOSE_SPI=1 -DKERNEL=1 -D__MACH30__)
INC="-I$SRC -I$SRC/src -I$SRC/src/firehose -I$SRC/os -I$OUT"

run_mig() {
  local defs=$1; shift
  MIGCC="$CC" MIGCOM="$MIGCOM" bash "$MIG" -arch arm64 \
    -isysroot "$FAKEROOT" "${MIGFLAGS[@]}" $INC "$@" "$defs"
}

# firehose.defs is used as a client from the kernel side (firehose_register).
run_mig "$SRC/src/firehose/firehose.defs" \
  -header "$OUT/firehose.h" -user /dev/null -server /dev/null
# firehose_reply.defs is served by the kernel (the firehose_flush reply).
run_mig "$SRC/src/firehose/firehose_reply.defs" \
  -header /dev/null -user /dev/null -server /dev/null \
  -sheader "$OUT/firehose_replyServer.h"

cat > "$OUT/firehose_compat.h" <<'EOF'
#ifndef __FIREHOSE_COMPAT_H
#define __FIREHOSE_COMPAT_H
#ifdef __cplusplus
extern "C" {
#endif
extern void panic(const char *, ...) __attribute__((noreturn, format(printf, 1, 2)));
#ifdef __cplusplus
}
#endif
#endif
EOF

CFLAGS=(
  -target arm64-apple-ios17.0
  -include "$OUT/firehose_compat.h"
  -mkernel -nostdlibinc -Wno-packed
  -DKERNEL=1 -DKERNEL_PRIVATE -DXNU_KERNEL_PRIVATE -DPRIVATE -DIOKIT_KERNEL_PRIVATE -DDISPATCH_USE_DTRACE=0 -DOS_FIREHOSE_SPI=1
  -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI
  -I"$SRC" -I"$SRC/src" -I"$SRC/src/firehose" -I"$SRC/os"
  -I"$OUT"
  -I"$FAKEROOT/usr/include"
  -I"$FAKEROOT/usr/local/include"
  -I"$FAKEROOT/usr/local/include/os"
  -I"$FAKEROOT/usr/local/include/firehose"
  -I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/Headers"
  -I"$FAKEROOT/System/Library/Frameworks/Kernel.framework/PrivateHeaders"
  -I"$XNU/EXTERNAL_HEADERS"
  -c
)

"$CC" "${CFLAGS[@]}" "$SRC/src/firehose/firehose_buffer.c" -o "$OUT/firehose_buffer.o"

"$LIBTOOL" -static -o "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" \
  "$OUT/firehose_buffer.o"

echo "build-firehose-linux: $FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a"
