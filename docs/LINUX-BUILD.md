# 在 Linux 上用 cctools-port 编译 XNU 内核

这份文档记录一次可行性研究：把 `build-kernel.yml` 里跑在 GitHub `macos-latest`
runner 上的内核编译步骤，搬到 Linux 宿主（本机或 Linux runner）上，用
cctools-port 作为 Mach-O 工具链。

结论先说：**可行**。最难的一环——Apple ld64 在 Linux 上按 XNU 的完整 ARM64
内核链接选项产出正确的 Mach-O——已经在本机跑通。MIG 的 Linux 移植也跑通了，
并且处理了真实的 xnu `.defs`。剩下的工作是工具映射、少量补丁和一条
`libfirehose_kernel` 的非 `xcodebuild` 构建规则。

文中所有“已验证”都指在本机（Arch Linux, x86_64, clang 23.1.3, GCC 16.2.1）
实际跑通，命令在下文可复现。

---

## 1. 现状：macOS 具体卡在哪

`UniXNU-uke/.github/workflows/build-kernel.yml` 的注释写的是：

> The kernel step needs macOS: xnu's own makefiles are driven with `xcodebuild`
> and the iPhoneOS SDK, and MIG ships only inside Xcode.

这句话有两处已经不准确，一处仍然成立：

| 说法 | 实际情况 |
| --- | --- |
| xnu 的 makefile 要用 `xcodebuild` 驱动 | **不准确**。`scripts/build-xnu-4k-baseline.sh:822` 直接调 `make`，`xcodebuild` 只用在 `scripts/build-firehose.sh`（`libdispatch.xcodeproj` 的 `libfirehose_kernel` target）。 |
| 需要 iPhoneOS SDK | **基本不成立**。补丁 `patches/xnu/kernel-sdk-root.patch` 已经把 `INCFLAGS_SDK` / `INCFLAGS_PLATFORM` / `LDFLAGS_KERNEL_SDK` 全部重定向到 `KERNEL_SDKROOT`（也就是 `.cache/fakeroot`）。内核编译用到的头文件全部来自 xnu 自己的 `installhdrs` + libplatform/libdispatch 头。 |
| MIG 只在 Xcode 里 | **曾经成立**。Apple 确实没把 MIG 放进 `apple-oss-distributions/cctools`，但它在 **`apple-oss-distributions/bootstrap_cmds`** 的 `migcom.tproj/` 里，而且有人做好了跨平台分支（见 §3）。 |

真正的硬依赖是 **Apple ld64**。内核链接命令（`makedefs/MakeInc.def` +
`MakeInc.kernel`）用了一批 ld64 专有选项，见 §4 的对照表。

---

## 2. 工具链映射表

`makedefs/MakeInc.cmd` 里每个工具都是 `ifeq ($(origin X),undefined)` 再去
`xcrun -find` 找——也就是说**全部可以通过环境变量注入**，不需要改 xnu 的
makefile。这一点是本次研究最重要的结构性发现。

| xnu 变量 | macOS 来源 | Linux 替代 | 状态 |
| --- | --- | --- | --- |
| `CC` / `CXX` | `xcrun -find clang` | `clang` / `clang++`（宿主 LLVM） | 已验证 |
| `MIG` / `MIGCOM` | `xcrun -find mig` / `migcom` | `bootstrap_cmds` 的 `mig.sh` + `migcom` | 已验证 |
| `MIGCC` | `$(CC)` | 同 `CC` | 已验证 |
| `STRIP` | `xcrun -find strip` | cctools-port `strip` | 已验证 |
| `LIBTOOL` | `xcrun -find libtool` | cctools-port `libtool` | 未跑通全量（仅 `BUILD_XNU_LIBRARY` 用到） |
| `LIPO` | `xcrun -find lipo` | cctools-port `lipo` | 单架构路径不经过 |
| `OTOOL` | `xcrun -find otool` | cctools-port `otool` | 已验证 |
| `NM` | `xcrun -find nm` | cctools-port `nm` 或 `llvm-nm` | 未实测 |
| `NMEDIT` | `xcrun -find nmedit` | cctools-port `nmedit` | 已安装 |
| `UNIFDEF` | `xcrun -find unifdef` | 发行版 `unifdef`（Arch `extra/unifdef`） | 已确认可装 |
| `DSYMUTIL` | `xcrun -find dsymutil` | 宿主 `dsymutil`（= `llvm-dsymutil`） | 已验证 LLVM 23 可用 |
| `HOST_CC` / `HOST_FLEX` / `HOST_BISON` / `HOST_GM4` | `xcrun` | `gcc` / `flex` / `bison` / `m4` | 已验证（SETUP 主机工具） |
| `HOST_CODESIGN` / `HOST_CODESIGN_ALLOCATE` | `/usr/bin/codesign` | **需要 shim 或补丁**，见 §5 | 未解决 |
| `CTFCONVERT` / `CTFMERGE` / `CTFDUMP` | Apple DTrace CTF | **无开源实现**，但可关闭，见 §5 | 可绕过 |
| `CTFINSERT` | `xcrun -find ctf_insert` | cctools-port 自带 `ctf_insert` | 已安装 |
| `PLUTIL` | `/usr/bin/plutil` | **需要 shim**，见 §5 | 未解决（补丁很小） |
| `SDKROOT` / `SDKVERSION` / `PLATFORM` | `xcrun -show-sdk-*` | 设 `SDKROOT_RESOLVED` 等环境变量直接短路 | 已分析 |
| `HOST_OS_VERSION` | `sw_vers -productVersion` | 环境变量注入 | 已分析 |
| `PAX` | `/bin/pax` | 只在 `installsrc`/cscope 目标用，**`make build` 不经过** | 不需要 |
| `XCRUN` | `/usr/bin/xcrun`（硬编码） | 上面全部注入后**不再被调用** | 已分析 |

### xnu 自己构建的主机工具

`SETUP/` 下的 `setsegname`、`kextsymboltool`、`decomment`、`installfile`、
`replacecontents` 用 `HOST_CC` 编译，在 Linux 上就是普通 ELF，没问题。
`config/newvers.pl` 是 Perl，`generate_combined_symbolsets_plist.sh` 是
POSIX shell，都可移植。`genassym` 是编译成 `.s` 再 sed 抽常量，不需要在宿主
上执行目标代码。

---

## 3. 已验证（一）：MIG 在 Linux 上可用

Apple 开源的 MIG 在 **`apple-oss-distributions/bootstrap_cmds`**（`migcom.tproj/`），
不是 cctools。cctools-port 里**没有** mig——`cctools/` 只有 `ar as otool ld64
libmacho libstuff misc efitools gprof`，`misc/` 里有 lipo/strip/libtool/nm 但没有 mig。

`markmentovai/bootstrap_cmds` 的 `cross_platform` 分支就是为“在非 macOS 上
给 Apple 平台交叉开发”做的，autoconf 化，带 `compat/non_apple/` 垫片。本机构建：

```bash
git clone --depth 1 --branch cross_platform \
    https://github.com/markmentovai/bootstrap_cmds.git
cd bootstrap_cmds
autoreconf --install
sh configure
make
# 产出：migcom.tproj/migcom   驱动脚本：migcom.tproj/mig.sh
```

依赖：`autoconf automake flex bison make cc bash`。**零补丁，一次通过。**

拿真实的 xnu `.defs` 试（注意 `mig.sh` 的 `-I` 必须写成 `-I<path>` 连写，
它把分开的 `-I` 后面那个词当成文件名）：

```bash
cd /path/to/xnu
MIGCC=clang MIGCOM=/path/to/bootstrap_cmds/migcom.tproj/migcom \
  bash /path/to/bootstrap_cmds/migcom.tproj/mig.sh \
    -arch arm64 -isysroot /nonexistent \
    -Iosfmk -Iosfmk/mach -Iosfmk/EXTERNAL_HEADERS \
    -novouchers -DMACH_KERNEL_PRIVATE -DKERNEL_SERVER=1 -mach_msg2 \
    -server mach_portServer.c -user mach_portUser.c -header mach_port.h \
    libsyscall/mach/mach_port.defs
```

产出 `mach_port.h`（99 KB）、`mach_portServer.c`（268 KB）、
`mach_portUser.c`（175 KB），内容含现代 MIG 特性
（`mig_strncpy_zerofill_support`）。`-mach_msg2` 被接受——这正是 piano port
在 `macos-14` / Xcode 15.4 上撞到的 `mig: fatal: no SubSystem declaration`
那个坑，这个分支没有。

---

## 4. 已验证（二）：cctools-port 的 ld64 能按 XNU 的选项链接

先说为什么**不能**用 LLVM 自带的 `ld64.lld`。逐项对照 XNU 的链接选项：

| ld64 选项 | 出处（`makedefs/MakeInc.def`） | `ld64.lld` | cctools-port ld64 |
| --- | --- | --- | --- |
| `-alias_list` | `LDFLAGS_KERNEL_ONLY` | ✗ 缺 | ✓ |
| `-segment_order` | `LDFLAGS_KERNEL_SEGARM64` | ✗ 缺 | ✓ |
| `-version_load_command` | `LDFLAGS_KERNEL_GEN` | ✗ 缺 | ✓ |
| `-image_base` | `LDFLAGS_KERNEL_GENARM64` | ✗ 缺 | ✓ |
| `-segaddr` | `LDFLAGS_KERNEL_GENARM64` | ✗ 缺 | ✓ |
| `-new_linker` | `LDFLAGS_KERNEL_GEN` | ✗ 缺 | ✓ |
| `-ios_version_min` | `DEPLOYMENT_LINKER_FLAGS` | ✗（只有 `-platform_version`） | ✓ |
| `-sectalign` / `-segprot` / `-sectcreate` | 各处 | ✓ | ✓ |
| `-rename_section` / `-rename_segment` | `LDFLAGS_KERNEL_GENARM64` | ✓ | ✓ |
| `-exported_symbols_list` | `LDFLAGS_KERNEL_ONLY_CONFIG_RELEASEARM64` | ✓ | ✓ |
| `-function_starts` / `-headerpad` / `-filelist` / `-force_load` | 各处 | ✓ | ✓ |
| `-pie` / `-e` / `-pagezero_size` | `LDFLAGS_KERNEL_GEN*` | ✓ | ✓ |

`ld64.lld` 缺 7 个，其中 6 个直接出现在 ARM64 内核链接行上。**结论：cctools-port
是必要的，不是偏好。**

### 构建 cctools-port

依赖除了 clang 10+ / C++20 之外还要 `libBlocksRuntime` 和 `libdispatch`
（`ld64` 用 blocks + dispatch）。Arch 上直接 `pacman -S libdispatch` 即可；
本机因为没法 sudo，改用源码：

```bash
# BlocksRuntime（约 10 秒）
git clone --depth 1 https://github.com/mackyle/blocksruntime.git
cd blocksruntime && ./buildlib && cd ..

# swift-corelibs-libdispatch（新 clang 下要关掉项目自带的 -Werror）
git clone --depth 1 https://github.com/apple/swift-corelibs-libdispatch.git
cd swift-corelibs-libdispatch
sed -i 's/:-Werror>)/:-Werror> $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-error>)/' \
    cmake/modules/DispatchCompilerWarnings.cmake
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/tmp/darwin-tc-deps -DBUILD_TESTING=OFF \
      -DINSTALL_PRIVATE_HEADERS=ON \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build -j"$(nproc)"
cmake --install build
cp /path/to/blocksruntime/libBlocksRuntime.a /tmp/darwin-tc-deps/lib/

# cctools-port（tapi 不需要：内核不链接任何 .tbd 存根）
git clone --depth 1 https://github.com/tpoechtrager/cctools-port.git
cd cctools-port/cctools
./configure --prefix=/tmp/darwin-tc \
    --with-libblocksruntime=/tmp/darwin-tc-deps \
    --with-libdispatch=/tmp/darwin-tc-deps
make -j"$(nproc)" && make install
```

**注意不要传 `--target=…`**：传了会得到 `x86_64-apple-darwin-ld` 这种带前缀
的名字；不传得到裸的 `ld`/`strip`/`nm`/`otool`/`lipo`/`libtool`/`nmedit`/
`codesign_allocate`/`ctf_insert`，更容易接进 xnu 的 make 变量。

`tapi` 默认关闭即可——`--enable-tapi-support` 只在要链接带 `.tbd` 的 SDK 存根
时才需要，内核链接只碰自己的 `.o` 和 fakeroot 里的 `.a`。

### 实测：按 XNU 的完整 ARM64 内核选项链接

把 `LDFLAGS_KERNEL_GEN` + `LDFLAGS_KERNEL_GENARM64` + `LDFLAGS_KERNEL_SEGARM64`
+ `LDFLAGS_KERNEL_ONLY` 原样拼成命令行，链接两个 arm64 目标文件：

```bash
clang -target arm64-apple-ios17.0 -c -nostdinc t1.c -o t1.o
clang -target arm64-apple-ios17.0 -c -nostdinc t2.c -o t2.o
printf 't1.o\nt2.o\n' > link.filelist
: > empty.bin && : > all-alias.exp
printf '<plist version="1.0"></plist>\n' > symbolsets.plist

ld -arch arm64 -ios_version_min 17.0 -e _start \
  -sectalign __TEXT __text 0x1000 -sectalign __DATA __common 0x1000 \
  -sectalign __DATA __bss 0x1000 \
  -sectcreate __PRELINK_TEXT __text empty.bin -segprot __PRELINK_TEXT r-x r-x \
  -sectcreate __PRELINK_INFO __info empty.bin \
  -new_linker -pagezero_size 0x0 -version_load_command -function_starts \
  -headerpad 152 -pie -static \
  -segaddr __PRELINK_TEXT 0xfffffff004004000 -image_base 0xfffffff007004000 \
  -rename_section __HIB __text __TEXT_EXEC __hib_text \
  -rename_segment __HIB __HIBDATA \
  -sectalign __DATA __const 0x4000 \
  -rename_section __DATA __const __DATA_CONST __const -segprot __DATA_CONST r-- r-- \
  -rename_section __TEXT __text __TEXT_EXEC __text \
  -sectcreate __PLK_TEXT_EXEC __text empty.bin \
  -sectcreate __PRELINK_DATA __data empty.bin \
  -sectcreate __PLK_DATA_CONST __data empty.bin \
  -sectcreate __PLK_LLVM_COV __llvm_covmap empty.bin \
  -sectcreate __PLK_LINKEDIT __data empty.bin \
  -rename_section __PPLDATA __const __PPLDATA_CONST __const \
  -segment_order __TEXT:__DATA_CONST:__DATA_SPTM:__LINKEDIT:__TEXT_EXEC:__TEXT_BOOT_EXEC:__KLD:__PPLTEXT:__PPLTRAMP:__PPLDATA_CONST:__LASTDATA_CONST:__LAST:__PPLDATA:__KLDDATA:__DATA:__HIBDATA:__BOOTDATA \
  -segprot __TEXT r-- r-- -alias_list all-alias.exp \
  -sectcreate __LINKINFO __symbolsets symbolsets.plist -segprot __LINKINFO r-- r-- \
  -filelist link.filelist -o t.kext
```

结果：

```
t.kext: Mach-O 64-bit arm64 executable, flags:<NOUNDEFS|PIE>
  segname __TEXT / __TEXT_EXEC / __PRELINK_TEXT / __PRELINK_INFO
  segname __PLK_TEXT_EXEC / __PRELINK_DATA / __PLK_DATA_CONST
  segname __PLK_LLVM_COV / __PLK_LINKEDIT / __LINKINFO / __LINKEDIT
    minos 17.0
      sdk 17.0
```

内核需要的 prelink 段（`__PRELINK_TEXT` / `__PRELINK_INFO` / `__PLK_*` /
`__LINKINFO`）全部按 `-segment_order` 出现，`LC_BUILD_VERSION` 的 minos/sdk
正确。走 `clang -fuse-ld=<cctools-ld> -nostdlib -Wl,…` 的驱动路径同样通过，
`strip` 也正常。

顺带确认了另外两件小事：`clang -target arm64-apple-ios17.0` 接受
`-miphoneos-version-min=17.0`，xnu 的 `osfmk/arm64/bcopy.s` 能交叉汇编成
Mach-O。

---

## 5. 还需要动手的四件事

按工作量从小到大：

### 5.1 `plutil` shim（很小）

`config/Makefile` 在 `symbolsets.plist` 上调 `plutil -lint -s` 和
`plutil -convert binary1 -s`，而 `symbolsets.plist` 是 `LDFILES_KERNEL_ONLY`
之一，跑不掉。Python 标准库就能做：

```python
# plutil 替代：-convert binary1 / -lint
import plistlib, sys
data = open(sys.argv[-2], 'rb').read()
obj = plistlib.loads(data)                 # 同时充当 -lint
open(sys.argv[-1], 'wb').write(plistlib.dumps(obj, fmt=plistlib.FMT_BINARY))
```

已验证 `plistlib` 会写 `bplist00` 魔数。`MakeInc.kernel:288` 的另一处 `plutil`
只在 `RC_DARWIN_KERNEL_VERSION` 未设置时才跑，而 `build-xnu-4k-baseline.sh:828`
已经显式传了 `RC_DARWIN_KERNEL_VERSION`，不受影响。

### 5.2 关掉 CTF 和 `codesign`（很小）

`makedefs/MakeInc.cmd:273` 在找不到 `ctfmerge` 时自动 `DO_CTFMERGE := 0`，
`ctf_convert`/`ctfmerge`/`ctfdump` 都是 Apple 的 DTrace 工具，没有开源实现，
但整条 CTF 支路会被跳过。**这不影响本项目**：`build-xnu-4k-baseline.sh:834`
消费的就是 `mach.development.bcm2837.unstripped.noctf`——本来就用的是 no-CTF
产物。

`SETUP/*/Makefile:21` 会给刚编好的主机工具跑
`codesign -s - $@`（配合 `codesign_allocate`）。这些是给 Linux 用的 ELF，
签名无意义。两条路选一：

- 给 `HOST_CODESIGN` 注入一个空 shim（`exit 0`），`HOST_CODESIGN_ALLOCATE`
  指向 cctools-port 的 `codesign_allocate`；或
- 在 `patches/xnu/` 加一个小补丁，把 `SETUP/*/Makefile` 的 codesign 行做成
  条件编译。

第二种更干净，也符合仓库现有的补丁风格（参考 `local-availability.patch`）。

### 5.3 `libfirehose_kernel` 的非 xcodebuild 构建（中等）

`LD_KERNEL_ARCHIVES` 里有 `-lfirehose_kernel`，现在靠
`scripts/build-firehose.sh` 调 `xcodebuild install -project
libdispatch.xcodeproj -target libfirehose_kernel -sdk iphoneos`。

源码很小、完全可移植：`libdispatch/src/firehose/{firehose_buffer.c,
firehose_server.c,firehose_server_object.m}` + `firehose.defs` /
`firehose_reply.defs` / `firehose_types.defs`。xcconfig 里的编译参数是：

```
GCC_PREPROCESSOR_DEFINITIONS = KERNEL=1 DISPATCH_USE_DTRACE=0
OTHER_MIGFLAGS = -novouchers
OTHER_CFLAGS = -mkernel -nostdinc -Wno-packed
```

也就是说：**用刚验证过的 Linux 版 MIG 跑那三个 `.defs`，再用 clang
`-target arm64-apple-ios17.0 -mkernel -nostdinc -DKERNEL=1` 编两个 `.c`，
`libtool -static` 打包**。这一步把 `xcodebuild` 彻底从内核路径上拿掉，
`unixnu/kernel.py:76` 的 `tool('xcodebuild', …)` 检查也可以删。

### 5.4 `SDKROOT` 的 `xcrun` 短路（很小，可选）

`MakeInc.cmd` 用 `$(shell $(XCRUN) -sdk $(SDKROOT) -show-sdk-path)` 解析
SDK。`XCRUN` 本身是硬编码 `=`，但每次 `xcrun` 调用都包在
`ifeq ($(origin X),undefined)` 里，所以在环境里预置这些变量就不会触发：

```bash
export SDKROOT_RESOLVED=/path/to/.cache/fakeroot
export HOST_SDKROOT_RESOLVED=/path/to/.cache/fakeroot
export SDKVERSION=17.0
export PLATFORM=iPhoneOS
export CC=clang CXX=clang++ MIG=… MIGCOM=… MIGCC=clang
export STRIP=… LIPO=… LIBTOOL=… OTOOL=… NM=… NMEDIT=… UNIFDEF=… DSYMUTIL=…
export HOST_CC=gcc HOST_FLEX=flex HOST_BISON=bison HOST_GM4=m4
export HOST_OS_VERSION=1.0
```

不传的话，`/usr/bin/xcrun` 不存在会让 `$(shell …)` 返回空，进而
`SDKROOT_RESOLVED` 为空、`INCFLAGS_SDK` 变成 `-I/usr/local/include/kernel`
——会以一种很难查的方式失败。所以**必须**注入，或者写个假 `xcrun` 放进
`PATH` 返回预设值（对其他脚本里散落的 `xcrun nm` / `xcrun dwarfdump`
也顺手覆盖了）。

假 `xcrun` 方案更省事：`scripts/` 下已经有 200+ 处 `xcrun nm` / `xcrun
dwarfdump` 调用（`audit-*.py` 一族），这些在 Linux 上可分别换成 `llvm-nm` /
`llvm-dwarfdump`，但一个 shim 能一次性把它们全接住。

---

## 6. 内核路径之外

`build-kernel.yml` 的两个 job 里，只有内核这一步需要 macOS。其余要么本来就在
Linux 上跑（UEFI、bootimg、payload），要么有明确替代：

| 步骤 | 现状 | Linux 替代 |
| --- | --- | --- |
| `unixnu fetch` / `ipsw fetch` | 已在 Linux 可用 | — |
| payload / bootimg | 文档里已写明在 Linux 上做 | — |
| userdata 镜像 | `hdiutil`（30 处） | `dmg` 转换（`docs/MACOS-BUILD.md` 已注明是 known gap） |
| IPSW 成员解压 | `compression_tool` | 开源 `lzfse` / `lzss` |
| userland fixture 签名 | `codesign`（92 处） | 不在内核路径；需要时再议 |
| 审计脚本 | `xcrun nm` / `xcrun dwarfdump` | `llvm-nm` / `llvm-dwarfdump` |
| `ditto`（`build-xnu-4k-baseline.sh` 3 处） | macOS | `cp -a` |

---

## 7. 替换 GitHub Actions

`build-kernel.yml` 的两个 job（`kernel` / `full`）都可以搬到 `ubuntu-latest`，
结构不变：

1. **工具链层**：把 §3 / §4 的 bootstrap 脚本放进
   `scripts/bootstrap-linux-toolchain.sh`，产物装到 `~/.cache/darwin-tc/`，
   按 `hashFiles` 键缓存（cctools-port + bootstrap_cmds + BlocksRuntime +
   libdispatch 的版本戳）。冷构建约 5–8 分钟，之后走 cache。
2. **环境层**：一个 `scripts/linux-build-env.sh`，导出 §5.4 的工具变量 +
   `plutil` shim 的 `PATH`，让 `build-xnu-4k-baseline.sh` 不用改。
3. **补丁层**：`patches/xnu/` 加 codesign 条件补丁（§5.2）；
   `scripts/build-firehose.sh` 增加 Linux 分支（§5.3）。
4. **workflow**：`runs-on: ubuntu-latest`，去掉 `brew install`，改成
   `apt`/`pacman` 等价物（`clang llvm lld cmake ninja unifdef device-tree-compiler
   mtools flex bison autoconf automake libdispatch`）。缓存键沿用现在的
   “源码身份”设计（`CACHE_SCHEMA` + fork commit + patch hashes）。

值得保留的现有设计：`CACHE_SCHEMA`、补丁变更即 cache miss、
`workflow_dispatch` 才跑昂贵的内核构建。这些跟宿主无关。

预期收益：GitHub 的 macOS runner 计费是 Linux 的 10 倍，240 分钟超时在
macOS 上是硬约束；Linux runner 还能跑更大并行，冷构建时间大概率从
15–17 分钟降下来。更重要的是**本机可以复现**——现在的 `MACOS-BUILD.md`
要求把三个树拷进 macOS VM，之后可以直接在开发机上 `make`。

---

## 8. 未验证 / 风险

- **没有端到端编出 `kernel.macho`**。已验证的是链路上的四个关键环节
  （MIG、clang 交叉编译、ld64 完整选项链接、strip），以及 xnu makefile 变量
  可注入的机制。真正跑通 `./unixnu build kernel` 还要先落地 §5。
- **`libtool -static` / `nmedit` / `nm`** 在 cctools-port 里已安装，但没有在
  内核路径上实测（`libtool` 只在 `BUILD_XNU_LIBRARY` 用）。
- **`migcom` 对新版 `.defs` 的覆盖率**：只测了 `mach_port.defs`。xnu 里共
  82 个 `.defs`，内核路径大约十几个，建议全量跑一遍作为验收。
- **`-fapple-kext`** 只在 C++/ObjC++ 上生效（clang 已警告），与 macOS 行为
  一致，但 xnu 里 kext 相关的 C++ 目标文件需要在真实构建里确认。
- **`ld64` 版本**：cctools-port 当前是 ld64 956.6，对应较新的 Xcode。若
  `macos-latest` 上的 Xcode 26 ld64 行为有差异，需要对照 `otool -l` 输出
  做一次等价性检查（这是 CI 迁移时唯一需要认真比对的地方）。
- **`markmentovai/bootstrap_cmds` 是第三方 fork**，不是 Apple 上游。fork 与
  `apple-oss-distributions/bootstrap_cmds` 的差异需要纳入仓库的 pin 机制
  （`feeds.toml` / `unixnu.lock` 已有先例）。如果不想依赖 fork，也可以从
  Apple 上游 `migcom.tproj` + `compat/non_apple` 自己打补丁。

---

## 9. 参考

- `apple-oss-distributions/bootstrap_cmds` — MIG 上游源码（`migcom.tproj/`）
- [markmentovai/bootstrap_cmds `cross_platform`](https://github.com/markmentovai/bootstrap_cmds/tree/cross_platform) — MIG 的 Linux 可移植移植
- [tpoechtrager/cctools-port](https://github.com/tpoechtrager/cctools-port) — Apple cctools + ld64 的 Linux 移植
- `makedefs/MakeInc.cmd` — xnu 的工具解析逻辑（`$(origin X)` 注入点）
- `patches/xnu/kernel-sdk-root.patch` — 已有的 SDKROOT → fakeroot 重定向
- `scripts/build-xnu-4k-baseline.sh` — 内核构建入口
- `scripts/build-firehose.sh` — 唯一还在用 `xcodebuild` 的内核路径脚本

---

## 10. 实施记录（2026-10-23）

下面是把上面的方案落到本仓库之后的实际进展，以及还没走通的部分。

### 已落地

**工具链**（复用 `/home/allenwdk/xnu-linux-research/toolchain`）：
`mig`/`migcom`（bootstrap_cmds）、`iig`（Python 重实现，见 `UniXNU/scripts/linux/iig`）、
cctools 的 `ld`/`strip`/`libtool`/`nmedit`/`codesign_allocate`、LLVM 的
`nm`/`otool`/`lipo`/`dsymutil`，加上 `plutil`/`xcrun`/`codesign`/`ditto`/
`sw_vers`/`sysctl` shim。环境由 `UniXNU/scripts/linux-build-env.sh` 注入。

**补丁**（`UniXNU/patches/xnu/`，均通过 `scripts/check-xnu-patches.sh`）：

- `linux-host-tools.patch` — `XCRUN`/`PAX`/`PLUTIL`/`HOST_CODESIGN` 改为 PATH
  解析；新增 `HOST_COMPAT_CFLAGS`/`HOST_COMPAT_LIBS`/`HOST_CSH`，让 `SETUP/`
  的主机工具在 Linux 上编得动；`doconf` 改经 `$(HOST_CSH)` 调用（不动 shebang，
  macOS 不受影响）；`Makefile` 里 6 处硬编码 `/usr/sbin/sysctl` 也一并解开。
- `portable-kalloc-type-builtins.patch` — `__builtin_xnu_type_summary` /
  `__builtin_xnu_type_signature` / `__builtin_xnu_types_compatible` 是 Apple clang
  扩展，上游 LLVM 没有。回退到「只报 data 粒度」，让树内的
  `KALLOC_TYPE_IS_DATA_ONLY` 静态断言成立；代价是丢掉类型元数据快路径。
- `llvm-clang-arm64-crypto-asm.patch` — `arm64_isa_compatibility.h` 用
  `__apple_build_version__` 决定用 `qN` 还是 `vN.4s` 语法；上游 LLVM 拒绝 `qN`
  形式的 `sha256h`/`sha256su0`。改成按「是否具备解析能力」判断。
- `iig-method-forwarders.patch` — `IOService::UserSetProperties` 与
  `SendIOMessageServicePropertyChange` 由 Apple 的 iig 生成转发到 `_Impl`，
  Linux 侧改为手写声明 + 定义。

**设备补丁**：`UniXNU-uke/patches/xnu/zzzzzzzzz-uke-ramoops-print.patch` 原本
hunk 头计数与上下文行不匹配，`git apply` 拒收，已修正。

**脚本**：
- `UniXNU/scripts/check-xnu-patches.sh` — 按 `build-xnu-4k-baseline.sh` 的顺序
  在一次性克隆上验完整条补丁序列。
- `UniXNU/scripts/build-firehose-linux.sh` — `libfirehose_kernel` 只编
  `firehose_buffer.c`，用 Linux 的 MIG 出 `firehose.h` 与
  `firehose_replyServer.h`，再 `libtool -static`；`build-firehose.sh` 在非
  Darwin 上转进来，`xcodebuild` 从内核路径上移除。

### iig 宏生成（路线 1，进行中）

不再依赖 `driverkit-kernel-11.3/`。`scripts/linux/iig` 现在按 Apple 的契约自己生成：

| 产物 | 内容 | 内核侧用途 |
| --- | --- | --- |
| `X_Methods` | `public:` + `Dispatch`/`_Dispatch` + 每个方法（末尾加 `OSDispatchMethod supermethod = NULL`） | `OSDeclareDefaultStructorsWithDispatch(X)` 展开 |
| `X_KernelMethods` | `protected:` + 全部 `*_Impl(X_<Name>_Args)`（超集） | 同上 |
| `X_VirtualMethods` | `override`/`LOCALONLY`/纯虚方法 | `NATIVE` 类的类壳里展开 |
| `X_<Name>_Args` | 形参列表 | `_Impl` 声明用 |
| `NATIVE` 类壳 | `XInterface : OSInterface` + `X : Base, XInterface` + ivars 联合体 | `IODataQueueDispatchSource` 这类没有 `IOKit/*.h` 的类 |

分类规则（对着 `driverkit-kernel-11.3` 反推出来的）：`override` / `LOCALONLY` /
`= 0` 的方法**不进** `X_Methods`——它们属于 `X_VirtualMethods` 或子类。把 `init`/
`free`/`retain`/`release` 放进 `X_Methods` 会用带 `supermethod` 的重载遮蔽
`OSObject` 的生命周期方法，这是之前一整片 `no matching member function for
call to 'release'` 的根因。

生成器已经修掉的坑：

1. 注解（`LOCALONLY`/`override`）在解析前被剥掉 → 分类失效
2. `class KERNEL IOService` 里把 `KERNEL` 当成了类名
3. 宏体最后一行的续行符吞掉下一个 `#define`（分隔用的是空串，没产生换行）
4. `void` 形参被追加 `supermethod` → `'void' must be the first and only parameter`
5. 声明内的装饰（`QUEUENAME(...)`、`TARGET`、`PORTCOPYSEND`）被当成签名的一部分
6. 一次替换把 `X_KernelMethods` 的生成整段弄丢
7. `static` 工厂被剥成实例方法 → `call to non-static member function`
8. 生成内容追加在 `.iig` 自己的 `#endif` 守卫之后 → 重复包含时类重复定义

### 还没走通（更新于第二轮实施）

生成器的契约部分已经做完，剩下 4 条都是 `IOUserServer.cpp` 的定义与 `.iig` 声明
逐条对齐的问题：

| 位置 | 症状 | 性质 |
| --- | --- | --- |
| `IOUserServer.cpp:827` | `CreateWithMemoryDescriptors_Impl` 签名不匹配 | `.iig` 写 `IOMemoryDescriptor * const withDescriptors[32]`，定义写 `IOMemoryDescriptor ** const withDescriptors`，两者本身就不一致 |
| `IOUserServer.cpp:1722` | `InterruptOccurred(rpc, ...)` 传 4 个参数，声明只有 3 个 | `X_Methods` 对 `INVOKEREPLY` 方法也要前置 `const IORPC rpc`（目前只加在 `_Args` 上） |
| `IOUserServer.cpp:6148` | `CreateActionKernelCompletion` 未声明 | 来自某个 `EXTENDS` 块的方法，还没被合并进宏 |
| `IOUserServer.cpp:778` | 同 `CreateWithMemoryDescriptors` | 同上 |

本轮新增的生成器规则（对着 `driverkit-kernel-11.3` 反推并逐项对拍）：

- `X_Methods` 不带 `OSDispatchMethod supermethod`——`IOUserServer.cpp` 的定义一律不带；
  带该参数的 RPC 转发体在生成的 `.iig.cpp` 里，而内核构建不编译它
- 只有 `override` 和生命周期名（`init`/`free`/`retain`/`release`/…）不进 `X_Methods`；
  `LOCALONLY` 的工厂方法（`CreatePropertyMatchingDictionary` 等）**要进**
- 重载全部进 `X_Methods`（真正的 C++ 重载），只有 `_Args`/`*_Impl` 名字取最宽一份
- `const` 成员函数的限定符要保留（`GetProvider() const`）
- `_Args` 的 `const IORPC rpc` 前缀由 `INVOKEREPLY` 决定，且该注解标在基类的
  `.iig` 上，需要回查 `DriverKit/<Base>.iig`
- 声明尾部的 `__attribute__((availability(...)))` 有嵌套括号，注解正则要能吃进去

另外两个踩过的坑值得记一笔：改完 `iig` 必须先删掉 `build/xnu/**/DriverKit/*.h`，
否则 `make` 认为 `%.h : %.iig` 是最新的，跑的还是旧生成器的产物；并行 make 会把
clang 的诊断搅成一团，定位阶段要用 `JOBS=1 RC_XBS=YES` 跑（`RC_XBS=YES` 让
`MakeInc.cmd` 把 `VERBOSE` 打开，命令行会打出来）。


---

## 10. 实施结果（2026-10-23 第三轮）

**Linux 上已经完整编出 XNU 内核并完成 prelink。**

```
out/uke/tree/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
  Mach-O 64-bit arm64 executable   14.5 MB (stripped)
out/uke/kernel/kernel.macho        48.8 MB  sha256 b8289a7386569543…
out/uke/kernel/kernel.json         16.5 MB  prelink 计划
```

`kernel.macho` 是对着 iPad7,1 的原始 kernelcache 做过符号绑定的 prelinked 内核，
`kernel.json` 是完整的绑定计划（`native_sha256` / `original_sha256` / `slide` /
`components` / `kernel_interfaces` / `pointer_counts` / `extents`）。

### 工具链

`scripts/linux-build-env.sh` 注入，工具在 `~/xnu-linux-research/toolchain/bin`：

| 工具 | 来源 |
| --- | --- |
| `mig` / `migcom` | bootstrap_cmds `cross_platform` 分支 |
| `iig` | `scripts/linux/iig`（本仓库，见下） |
| `ld` `strip` `libtool` `nmedit` `codesign_allocate` | cctools-port |
| `nm` `otool` `lipo` `dsymutil` | LLVM |
| `plutil` `xcrun` `compression_tool` `codesign` `ditto` `sw_vers` `sysctl` | shim |
| `lzfse` | lzfse/lzfse（`compression_tool` 的后端） |

`plutil` 的 shim 要能读 **OpenStep 格式** 的 plist（`project.pbxproj` 就是），
`plistlib` 不支持；`compression_tool` 用 `-decode -a lzfse` 调 `lzfse`；
`xcrun` 要同时接受 `-sdk`/`--sdk` 这类长短选项。

### iig 生成器（`scripts/linux/iig`）

按 `driverkit-kernel-11.3` 金标准对拍出来的契约，每个 `.iig` 产出：

- `X_Methods` — `Dispatch`/`_Dispatch` 前言 + 每个方法；有 `*_Impl` 的带
  `OSDispatchMethod supermethod = NULL` 尾参（prelink 按这个符号绑定），
  `IOUserServer.cpp` 直接定义的不带
- `X_KernelMethods` — `*_Impl` 声明（签名取自 `IOUserServer.cpp` 的定义侧）+
  `X_<M>_Handler` typedef 与 `X_<M>_Invoke` 声明
- `X_VirtualMethods` — 只放 `init`/`free` 等生命周期成员
- `X_<M>_Args` — 形参表；`REPLY`/`INVOKEREPLY` 方法前置 `const IORPC rpc`
- `NATIVE` 类的类壳 + `OSDefineMetaClassAndStructors`
- `.iig.cpp` — 转发体、`_Dispatch`、`_Invoke`、元类定义

分类规则：`override` / `LOCALONLY` / `= 0` **不进** `X_Methods` 以外的东西都不变；
`init`/`free`/`retain`/`release`/`getMetaClass`/`isEqualTo`/`taggedRetain`/
`taggedRelease` 一律排除——它们由 `OSMetaClass.h` 自己声明，加进去会遮蔽。
重载全部进 `X_Methods`（真正的 C++ 重载），`_Args`/`*_Impl` 取最宽一份。

### 补丁（`UniXNU/patches/xnu/`）

- `linux-host-tools.patch` — `XCRUN`/`PAX`/`PLUTIL`/`HOST_CODESIGN` 改 PATH 解析；
  `HOST_COMPAT_CFLAGS`/`HOST_COMPAT_LIBS`/`HOST_CSH`；`doconf` 经 `$(HOST_CSH)`
  调用；`Makefile` 里 6 处硬编码 `/usr/sbin/sysctl`
- `portable-kalloc-type-builtins.patch` — `__builtin_xnu_type_*` 是 Apple clang
  扩展，回退到「只报 data 粒度」
- `llvm-clang-arm64-crypto-asm.patch` — `arm64_isa_compatibility.h` 按解析能力
  选 `qN`/`vN.4s` 语法
- `iig-method-forwarders.patch` — iig 不生成的转发体（`UserSetProperties` 等）
- `linux-link-shims.patch` — PGO 的 `__llvm_profile_*`、`__cxa_atexit`、
  `vm_tests.c` 用的旧名（`mach_vm_allocate`/`vm_map_create`）

### 已知未走通

`uke-kernel-full` 的板级 archive 链跑到 **archive 12**（`build-sheng-platform-power`）
停住：`audit-amfi-pmgr-contract` 通过，但后续的原版 ABI 对齐检查报
`Native IOPMGR/IOService entry differs at 2`。那是拿 native 的 `IOPMGR` 虚表槽位
跟原始 kernelcache 逐一对齐，槽 2 的函数符号不一致。根因是 `IOService` 的虚表布局
跟原版有差（`X_Methods` 注入的 `virtual Dispatch(...)` 位置、或缺/多一个虚函数），
不是构建系统的问题。要定位得对比两边 `__ZTV6IOPMGR` 的槽位符号。

另外记一笔：`.iig.cpp` 里 `X_<M>_Invoke` 目前是**签名正确的桩**（返回
`kIOReturnUnsupported`），没有复刻 RPC 参数解码；`_Dispatch` 转发到
`Dispatch()`，后者也是桩。这两条影响的是运行时 RPC 派发，不影响编译与 prelink
绑定。`libfirehose_kernel` 要的 SDK 私有头（`chunk_private.h` 等）仍是从
Apple SDK 提取后放在 fakeroot 里的，仓库里没有脚本负责摆放。

### 容易踩的坑

改完 `iig` 必须先删 `build/xnu/**/DriverKit/*.h`，否则 `make` 按 `%.h : %.iig`
时间戳认为是最新的。定位阶段用 `JOBS=1 RC_XBS=YES`（`RC_XBS=YES` 让
`MakeInc.cmd` 打开 `VERBOSE`），并行 make 会把 clang 诊断搅成一团。
`out/uke/tree/.cache/firmware/kernelcache.macho/` 会被 tree 装配清掉，跑 archive
之前要重新 staging。


---

## 11. `uke-kernel-full` 在 Linux 上编译成功（2026-10-23）

```
out/uke/kernel/kernel.macho    51.6 MB   Mach-O 64-bit arm64 executable
                         sha256 9cae29d066ec6f6818c9701b36fd00503a775b9fb0e12dddb5ba07a92e00c940
out/uke/kernel/kernel.json     16.9 MB   prelink 绑定计划
```

配置是 `uke-full_defconfig`：`CONFIG_XNU_BUILD_ARCHIVES=y`、`CONFIG_XNU_ARMCPU`、
`CONFIG_XNU_NATIVE_UFS`、`CONFIG_XNU_NATIVE_AES`、`CONFIG_XNU_SHENG_PMGR`、
`CONFIG_XNU_NATIVE_LEGACY_DISPLAY` 全开。板级 archive 链入的符号数：
ShengPlatformPower 191、NativeUfs 83、ArmCpu 42、NativeLegacyDisplay 49、
NativeAES 36、ArmDTPlatform 27。`__TEXT` 落在 `0xfffffff007004000`，与原版
kernelcache 一致。

### 最后一公里踩的四个坑

1. **`ld` 必须用 cctools-port 的 Apple ld64，不能用 `ld64.lld`。**
   `ld64.lld` 不支持 `-image_base`/`-segaddr`/`-segment_order`/`-alias_list`，
   内核会链到 `__TEXT` 0x0，虚表内容多出 `2^52` 偏移——`NativePrelink` 的
   `audit-amfi-pmgr-contract` 因此报 `Native IOPMGR/IOService entry differs at 2`
   （`OSObject::release(int)` 那一槽对不上）。换成 cctools ld64 后槽位逐一对齐。

2. **`ar`/`ranlib` 也要用 cctools 的。** `xcrun ar` 落到 GNU ar 会产出 GNU 格式
   归档，cctools ld64 报 `unknown-unsupported file format` 或
   `archive has no table of contents`，然后把整个 `.a` 静默丢掉。

3. **`strip`/`nm`/`otool`/`lipo`/`libtool`/`nmedit` 同理**；`llvm-strip` 会把内核
   当成 shared library 拒掉。`xcrun -find` 的解析表要路由到工具链，别硬编码
   `/usr/sbin/llvm-*`。

4. **`installhdrs` 的产物会被 tree 装配清掉。** `kernel.py` 先跑 archive 再跑内核，
   而 `installhdrs` 在内核那一步里——所以 archive 之前要保证
   `build-xnu-4k-baseline.sh` 至少跑过一次，否则 fakeroot 里没有
   `kern/kalloc.h`。删掉 `.cache/fakeroot/.xnu-*-headers` 这个 stamp 可强制重装。

另外：`plutil` 要读 OpenStep 格式的 `project.pbxproj`；`compression_tool` 用
`lzfse` 后端；`xcrun` 要吃 `--sdk`/`--show-sdk-path` 这种长短选项；
`brew --prefix llvm` 用一个 shim 指向系统 LLVM 即可（`build-native-legacy-display.py`
等脚本靠它找 `llvm-objcopy`）。

### 仍在的已知项

- `.iig.cpp` 的 `X_<M>_Invoke` 是签名正确的桩（返回 `kIOReturnUnsupported`），
  没复刻 RPC 参数解码；`_Dispatch` 转发到 `Dispatch()`，后者也是桩。影响运行时
  RPC 派发，不影响编译与 prelink 绑定。
- `libfirehose_kernel` 依赖的 SDK 私有头（`chunk_private.h`、`tracepoint_private.h`、
  `firehose_types_private.h`）仍是从 Apple SDK 提取后放在
  `.cache/fakeroot/usr/local/include/firehose/` 的，仓库里没有脚本负责摆放；
  `sys/_pthread/_pthread_*.h` 由 `build-firehose-linux.sh` 自己生成。
