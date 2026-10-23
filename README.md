# xnu-linux-toolchain

在 Linux 上编译 XNU 内核所需的工具链与配套脚本。目标是把原来跑在 macOS
runner（`macos-latest` + Xcode）上的内核构建搬到 Linux。

**当前状态：可以完整编出 `uke-kernel-full`。** 产物是 Mach-O 64-bit arm64
内核，`__TEXT` 落在 `0xfffffff007004000`，与原版 kernelcache 布局一致，板级
archive 全部链入，prelink 通过原版 ABI 对齐审计。但**还不能直接进 CI 承担
内核构建**，原因见下面「已知缺口」。

---

## 快速开始

```bash
# 1. 系统依赖（Arch 为例，其他发行版见下）
sudo pacman -S --needed git cmake make clang python3 flex bison autoconf \
                        automake pkgconf libdispatch

# 2. 编工具链（约 5–8 分钟，装到 ~/.local/xnu-linux）
./bootstrap.sh

# 3. 进入构建环境
source env.sh
```

`bootstrap.sh --prefix DIR` 换安装位置，`--fetch-only` 只取源码不编译。
装完之后：

```
$PREFIX/bin/        shim（iig、plutil、xcrun、ld、ar、strip…）+ 这里编出来的
                    mig、migcom、lzfse、unifdef、tcsh
$PREFIX/cctools/    cctools-port：Apple 的 ld64、ar、strip、nm、otool、lipo、
                    libtool、nmedit、codesign_allocate、ranlib
```

### 系统依赖

| 包 | 用途 |
| --- | --- |
| clang 10+ / cmake / make | 编译 |
| flex / bison / autoconf / automake | 编 mig（bootstrap_cmds） |
| libdispatch + BlocksRuntime | cctools ld64 用（Arch：`pacman -S libdispatch`） |
| python3 | `iig`、`plutil` 都是 Python |
| pkg-config | cctools configure |

`unifdef`、`tcsh`、`lzfse`、`ninja` 若系统里已有，`bootstrap.sh` 会覆盖安装
一份到 `$PREFIX/bin`，也可以改成软链。

---

## 仓库布局

```
bootstrap.sh         造工具链
env.sh               source 它进构建环境
toolchain/           shim 脚本（会被拷到 $PREFIX/bin）
patches/xnu/         让 xnu 能用非 Apple 工具链编译的补丁
scripts/             firehose 的 Linux 构建、补丁序列校验
docs/LINUX-BUILD.md  完整的调研与实施记录（工具链对照、iig 契约、踩坑）
```

---

## 为什么要 cctools-port，不能用 `ld64.lld`

这是整套东西里最关键的一条。LLVM 自带的 `ld64.lld` **不支持** XNU 内核链接
要用的这几个选项：

| 选项 | 出处 | `ld64.lld` | cctools ld64 |
| --- | --- | --- | --- |
| `-image_base` | `LDFLAGS_KERNEL_GENARM64` | ✗ | ✓ |
| `-segaddr` | 同上 | ✗ | ✓ |
| `-segment_order` | `LDFLAGS_KERNEL_SEGARM64` | ✗ | ✓ |
| `-alias_list` | `LDFLAGS_KERNEL_ONLY` | ✗ | ✓ |
| `-version_load_command` / `-new_linker` | `LDFLAGS_KERNEL_GEN` | ✗ | ✓ |
| `-ios_version_min` | `DEPLOYMENT_LINKER_FLAGS` | ✗ | ✓ |

少了 `-image_base`/`-segaddr`，内核会被链到 `__TEXT` 0x0，虚表内容多出 `2^52`
的偏移——prelink 的 ABI 审计会报 `Native IOPMGR/IOService entry differs at 2`。
换成 cctools 的 ld64 之后槽位逐一对齐。

同理，`ar`/`ranlib` 也必须用 cctools 的：GNU ar 打出的归档 cctools ld64 会
报 `unknown-unsupported file format` 或 `archive has no table of contents`，
然后**静默丢掉整个 `.a`**——链接能过但缺符号，很难查。`llvm-strip` 会把内核
当 shared library 拒掉。`toolchain/` 里的 `ld`/`ar`/`strip`/`nm`/`otool`/
`lipo`/`libtool`/`nmedit`/`codesign_allocate`/`ranlib` 都是 cctools 的包装。

---

## `iig`：DriverKit 接口生成器

`toolchain/iig` 是 Apple `iig` 的重实现（Python）。xnu 的
`iokit/DriverKit/*.iig` 文件几乎是合法 C++ 头，真 iig 解析后产出：

- `#if __DOCUMENTATION__` 里的 DriverKit 类体——**不参与编译**，内核自己在
  `IOKit/*.h` 里声明这些类；
- `X_Methods` / `X_KernelMethods` 两组宏，由
  `OSDeclareDefaultStructorsWithDispatch(X)` → `_OS_ADD_METHODS_dispatch(X)`
  展开进内核自己的 `class X`；
- `.iig.cpp`：转发体、`_Dispatch`、`_Invoke`、元类定义——`iokit/conf/files`
  里就列着这些，会编进内核。

契约是拿 `driverkit-kernel-11.3` 的真实 iig 输出当金标准反推的，几条容易踩的：

- `override` / `LOCALONLY` / `= 0` 的方法**不进** `X_Methods`；`init`/`free`/
  `retain`/`release`/`getMetaClass`/`isEqualTo`/`taggedRetain`/`taggedRelease`
  一律排除——它们由 `OSMetaClass.h` 自己声明，加进去会用带 `supermethod` 的
  重载遮蔽掉。
- 有 `*_Impl`（定义在 `iokit/Kernel/IOUserServer.cpp`）的方法，`X_Methods` 要带
  `OSDispatchMethod supermethod = NULL` 尾参——**prelink 按这个符号绑定**；
  内核直接定义的（`GetProvider`、`CreatePropertyMatchingDictionary` 等）不带。
- 重载全部进 `X_Methods`（真正的 C++ 重载），`_Args` / `*_Impl` 名字取最宽一份。
- `_Args` 的 `const IORPC rpc` 前缀由 `REPLY` / `INVOKEREPLY` 注解决定，而这个
  注解标在**基类**的 `.iig` 上，要回查 `DriverKit/<Base>.iig`。
- `TYPE(...)` 注解会生成 `CreateAction<方法名>` 工厂。
- 生成内容要插在 `.iig` 自己的 `#endif` 守卫**之前**，否则重复包含时类重定义。
- `.iig` 顶部的 `#if !__IIG / #include <IOKit/Foo.h> / #endif` 必须保留——那是
  生成头把内核类定义拉进来的路径，删掉就 `base class has incomplete type`。

---

## 补丁（`patches/xnu/`）

| 补丁 | 作用 |
| --- | --- |
| `linux-host-tools.patch` | `XCRUN`/`PAX`/`PLUTIL`/`HOST_CODESIGN` 改 PATH 解析；新增 `HOST_COMPAT_CFLAGS`/`HOST_COMPAT_LIBS`/`HOST_CSH` 让 `SETUP/` 的主机工具编得动；`doconf` 经 `$(HOST_CSH)` 调用；`Makefile` 里 6 处硬编码 `/usr/sbin/sysctl` |
| `portable-kalloc-type-builtins.patch` | `__builtin_xnu_type_summary`/`_signature`/`_types_compatible` 是 Apple clang 扩展，上游 LLVM 没有；回退到「只报 data 粒度」，代价是丢掉类型元数据快路径 |
| `llvm-clang-arm64-crypto-asm.patch` | `arm64_isa_compatibility.h` 按解析能力选 `qN`/`vN.4s` 语法；上游 LLVM 拒绝 `sha256h q0, q1` |
| `iig-method-forwarders.patch` | iig 不生成的转发体（`UserSetProperties` 等） |
| `linux-link-shims.patch` | PGO 的 `__llvm_profile_*`、`__cxa_atexit`、`vm_tests.c` 用的旧 API 名 |

`scripts/check-xnu-patches.sh` 按 `build-xnu-4k-baseline.sh` 的顺序在一次性
克隆上验完整条序列。

---

## 接进构建

UniXNU 侧要改的很少：

```bash
source /path/to/xnu-linux-toolchain/env.sh
# 之后照常 ./unixnu build kernel ...
```

`patches/xnu/` 下的补丁需要出现在设备仓的 `patches/xnu/`（`build-xnu-4k-baseline.sh`
按 `find` 排序应用）。本仓库是这些补丁的**唯一来源**，同步方式见下。

---

## 已知缺口

1. **工具链要 `bootstrap.sh` 造一次**，不能只靠仓库里的脚本就跑。CI 里要把
   `$PREFIX` 做成按内容哈希缓存的 artifact。
2. **`.iig.cpp` 的 `X_<M>_Invoke` 是签名正确的桩**（返回
   `kIOReturnUnsupported`），没复刻 RPC 参数解码；`_Dispatch` 转发到 `Dispatch()`，
   后者也是桩。符号齐、能链接、能过 prelink 绑定，但**运行时 DriverKit 的
   RPC 派发不通**。要在机上驱动硬件（UFS/显示）的话这条必须补。
3. **`libfirehose_kernel` 依赖的 SDK 私有头**（`chunk_private.h`、
   `tracepoint_private.h`、`firehose_types_private.h`）是从 Apple SDK 提取的，
   现在手工放在 fakeroot 里，本仓库没有脚本摆放——冷构建会缺头，且有再分发
   问题。`sys/_pthread/_pthread_*.h` 由 `scripts/build-firehose-linux.sh` 自己生成。
4. **构建对增量状态敏感**：改完 `iig` 必须删 `build/xnu/**/DriverKit/*.h`，
   否则 make 按 `%.h : %.iig` 时间戳不重新生成；`installhdrs` 的产物会被 tree
   装配清掉，而 `kernel.py` 先跑 archive 再跑内核；树搬家后旧 `.d` 里是过期
   绝对路径。
5. **只跑过 `bootstrap_defconfig` 与 `uke-full_defconfig`**，`uke_defconfig`
   （first-console）没验过。没验重建确定性，没做启动测试。
6. **并行 make 偶发比串行失败**（链接那一步），定位阶段用 `JOBS=1 RC_XBS=YES`。

---

## 参考

- [markmentovai/bootstrap_cmds](https://github.com/markmentovai/bootstrap_cmds/tree/cross_platform) — MIG 的 Linux 可移植移植
- [tpoechtrager/cctools-port](https://github.com/tpoechtrager/cctools-port) — Apple cctools + ld64 的 Linux 移植
- [lzfse/lzfse](https://github.com/lzfse/lzfse) — `compression_tool` 的后端
- `docs/LINUX-BUILD.md` — 完整调研与实施记录

补丁里含 Apple 开源代码的衍生内容，按 APSL v2.0 处理；shim 与生成器是本仓库原创。
