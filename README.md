# xnu-linux-toolchain

在 Linux 上编译 XNU 内核的工具链与配套脚本。目标是把原来跑在 macOS runner
（`macos-latest` + Xcode）上的内核构建搬到 Linux。

**状态：可以完整编出 `uke-kernel-full`。** `UniXNU-uke@main` 冷构建实测
**205 秒**（32 核），改一行内核源码重编 **27 秒**，改一个补丁 **111 秒**。
产物是 Mach-O 64-bit arm64 内核，`__TEXT` 在 `0xfffffff007004000`，与原版
kernelcache 布局一致，板级 archive 全部链入，prelink 通过原版 ABI 对齐审计。

还不能直接进 CI 承担内核构建，原因见「已知缺口」。

---

## 1. 跑起来

```bash
# 系统依赖（Arch 为例）
sudo pacman -S --needed git cmake make clang python3 flex bison autoconf \
                        automake pkgconf libdispatch

# 编工具链，约 5–8 分钟
./bootstrap.sh

# 之后每次构建只要一条 source
cd /path/to/UniXNU
source scripts/linux-build-env.sh
```

`bootstrap.sh --prefix DIR` 换安装位置（默认 `~/.local/xnu-linux`），
`--fetch-only` 只取源码不编译。

装完之后：

```
$PREFIX/bin/      shim（iig、plutil、xcrun、ld、ar、strip…）
                  + 编出来的 mig、migcom、lzfse、unifdef、tcsh
                  + env.sh、werror-exceptions.txt
$PREFIX/cctools/  cctools-port：Apple 的 ld64、ar、strip、nm、otool、lipo、
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

`unifdef`、`tcsh`、`lzfse` 系统里有的话 `bootstrap.sh` 会覆盖装一份到
`$PREFIX/bin`，改成软链也行。

---

## 2. 日常循环

### 改补丁

内核改动落在补丁里：

```
UniXNU/patches/xnu/*.patch       fork 的（57 个）
UniXNU-uke/patches/xnu/*.patch   设备的
```

```bash
$EDITOR UniXNU/patches/xnu/你的补丁.patch
# 构建前先验一遍补丁序列（可选但推荐）
UniXNU/scripts/check-xnu-patches.sh /path/to/UniXNU-uke
cd UniXNU && ./unixnu build kernel -D ../UniXNU-uke
```

改补丁 → 补丁集哈希变 → `.cache/xnu-work` 重克隆重打 → **约 111 秒**。

**两个坑：**

- 顺序由 `find | sort` 决定，所以补丁文件名带 `zzzz-` 前缀。新补丁排错位、
  依赖了后面某个补丁的内容，没有工具会提醒，只会给一个上下文对不上的
  `git apply` 报错。
- 补丁格式坏了（比如 hunk 头的行数跟内容对不上），`git apply` 只说
  「补丁损坏」不说是哪一行。

想更快迭代可以先直接改 `.cache/xnu-work` 里的文件（**27 秒**），但下次补丁集
一变就没了。

### 加驱动

驱动目录**自动注册**，不用改 `feeds.toml`：

```
UniXNU/drivers/Foo/        或  UniXNU-uke/drivers/Foo/
```

`feeds.py` 的候选顺序里有 `--local DIR → DIR/<kind>/NAME`，丢进去就挂进
`out/uke/tree/drivers/`（现有的 18 个驱动就是 core 15 个 + 设备 3 个合出来的）。
然后 `board.toml` 的 `archives` 加一行：

```toml
archives = [
  ...
  "build-arm-driver.py Foo",
]
```

**两个坑：**

- 如果驱动要接 DriverKit 的 RPC（`.iig` 里声明方法、用 `TYPE(...)` 回调），
  那条链目前是断的，见「已知缺口」。纯内核态、走 archive 的驱动（像
  `ArmCpu`、`NativeUfs`）不受影响。
- 新增或改了 `.iig`，记得先删 `build/xnu/**/DriverKit/*.h`，否则 make 按
  `%.h : %.iig` 时间戳不重新生成，你会看到旧接口。

---

## 3. `-Werror` 怎么处理

**这是最容易让你「这边过了、推上去挂 CI」的地方。**

### 问题

驱动构建（`build-arm-driver.py` 一族）带 `-Werror`。项目是照 Xcode 的 clang
写的，上游 clang 多出几条诊断会打在既有代码上——多半在项目自己的宏展开里
（`OSMetaClass.h` 的 `KALLOC_TYPE_DEFINE`、`OSDefineMetaClassAndStructors`）。
不开 `-Werror` 新驱动的真问题就漏了；全局关掉又一样漏。

想用包装器注入 `-Wno-*` 也做不到：这些脚本会从
`IOPlatformExpert.cpo.json` 记录的命令行**重建**编译命令，把 `-W*` 全剥掉再
自己拼一套 `-Wall -Wextra -Werror`，而 `-MJ` 记的是编译器真实路径
（`/usr/bin/clang-23`）不是包装脚本。两条路都拦不住。

### 做法

用 `CCC_OVERRIDE_OPTIONS`——clang driver 自己读的环境变量，追加在**所有**
参数之后。而且**逐条降级**，不是全局 `-Wno-error`：

```
+-Wno-error=missing-designated-field-initializers
+-Wno-error=unused-but-set-global
```

效果是这两条降成警告，**其余任何告警仍然是错误**。实测：

```
-Wuninitialized → error: variable 'x' is uninitialized when used here [-Werror,-Wuninitialized]
```

清单在 [`toolchain/werror-exceptions.txt`](toolchain/werror-exceptions.txt)，
`env.sh` 读它拼出 `CCC_OVERRIDE_OPTIONS`。构建停在一条明显来自既有代码的
诊断上时，把诊断名加进这个文件——**不要**换成全局 `-Wno-error`。

清单是按 `UniXNU-uke@main` 的 `uke-full` 配置实测出来的（2026-10-23），只有
两条。换了配置或加了新驱动可能多出几条。

### 怎么自查

降级的告警仍会打在日志里，推 CI 前 grep 一下自己的驱动：

```bash
grep "warning:" out/uke/logs/archive-*.log | grep "你的驱动名"
```

---

## 4. 仓库布局

```
bootstrap.sh                     造工具链
env.sh                           被 linux-build-env.sh 自动 source
toolchain/                       shim 脚本（拷到 $PREFIX/bin）
  iig                            DriverKit 接口生成器
  plutil                         能读 OpenStep 格式的 project.pbxproj
  xcrun / compression_tool / brew / codesign / ditto / sw_vers / sysctl
  ld ar strip nm otool lipo libtool nmedit codesign_allocate ranlib
                                 cctools 的包装
  target-clang target-clang++    内核目标编译驱动
  host-clang                     SETUP 主机工具的编译驱动
  werror-exceptions.txt          上面那份诊断清单
patches/xnu/                     让 xnu 能用非 Apple 工具链编译的补丁
scripts/
  check-xnu-patches.sh           按构建顺序验整条补丁序列
  build-firehose-linux.sh        libfirehose_kernel 的 Linux 构建
  sync-patches.sh                把补丁同步进设备仓
docs/LINUX-BUILD.md              完整调研与实施记录
```

---

## 5. 为什么必须 cctools-port，不能用 `ld64.lld`

这是整套东西里最关键的一条。LLVM 自带的 `ld64.lld` **不支持** XNU 内核链接
要用的几个选项：

| 选项 | 出处 | `ld64.lld` | cctools ld64 |
| --- | --- | --- | --- |
| `-image_base` | `LDFLAGS_KERNEL_GENARM64` | ✗ | ✓ |
| `-segaddr` | 同上 | ✗ | ✓ |
| `-segment_order` | `LDFLAGS_KERNEL_SEGARM64` | ✗ | ✓ |
| `-alias_list` | `LDFLAGS_KERNEL_ONLY` | ✗ | ✓ |
| `-version_load_command` / `-new_linker` | `LDFLAGS_KERNEL_GEN` | ✗ | ✓ |
| `-ios_version_min` | `DEPLOYMENT_LINKER_FLAGS` | ✗ | ✓ |

少了 `-image_base`/`-segaddr`，内核会被链到 `__TEXT` 0x0，虚表内容多出 `2^52`
的偏移——prelink 的 ABI 审计报 `Native IOPMGR/IOService entry differs at 2`
（`OSObject::release(int)` 那一槽对不上）。换成 cctools 的 ld64 之后槽位逐一对齐。

`ar`/`ranlib` 同理必须用 cctools 的：GNU ar 打的归档 cctools ld64 报
`unknown-unsupported file format` 或 `archive has no table of contents`，
然后**静默丢掉整个 `.a`**——链接能过但缺符号，很难查。`llvm-strip` 会把内核
当 shared library 拒掉。`toolchain/` 里对应的包装都指到 cctools。

---

## 6. `iig`：DriverKit 接口生成器

`toolchain/iig` 是 Apple `iig` 的重实现（Python）。xnu 的
`iokit/DriverKit/*.iig` 几乎是合法 C++ 头，真 iig 解析后产出：

- `#if __DOCUMENTATION__` 里的 DriverKit 类体——**不参与编译**，内核自己在
  `IOKit/*.h` 里声明这些类；
- `X_Methods` / `X_KernelMethods` 两组宏，由
  `OSDeclareDefaultStructorsWithDispatch(X)` → `_OS_ADD_METHODS_dispatch(X)`
  展开进内核自己的 `class X`；
- `.iig.cpp`：转发体、`_Dispatch`、`_Invoke`、元类定义——`iokit/conf/files`
  里就列着这些，会编进内核。

契约是拿 `driverkit-kernel-11.3` 的真实 iig 输出当金标准反推的。几条容易踩的：

- `override` / `LOCALONLY` / `= 0` 的方法**不进** `X_Methods`；`init`/`free`/
  `retain`/`release`/`getMetaClass`/`isEqualTo`/`taggedRetain`/`taggedRelease`
  一律排除——它们由 `OSMetaClass.h` 自己声明，加进去会用带 `supermethod` 的
  重载遮蔽掉。
- 有 `*_Impl`（定义在 `iokit/Kernel/IOUserServer.cpp`）的方法，`X_Methods` 要带
  `OSDispatchMethod supermethod = NULL` 尾参——**prelink 按这个符号绑定**；
  内核直接定义的（`GetProvider` 等）不带。
- 重载全部进 `X_Methods`（真正的 C++ 重载），`_Args` / `*_Impl` 名字取最宽一份。
- `_Args` 的 `const IORPC rpc` 前缀由 `REPLY` / `INVOKEREPLY` 决定，而这个注解
  标在**基类**的 `.iig` 上，要回查 `DriverKit/<Base>.iig`。
- `TYPE(...)` 注解会生成 `CreateAction<方法名>` 工厂。
- 生成内容要插在 `.iig` 自己的 `#endif` 守卫**之前**，否则重复包含时类重定义。
- `.iig` 顶部的 `#if !__IIG / #include <IOKit/Foo.h> / #endif` 必须保留——那是
  生成头把内核类定义拉进来的路径，删掉就 `base class has incomplete type`。

---

## 7. 补丁（`patches/xnu/`）

| 补丁 | 作用 |
| --- | --- |
| `linux-host-tools.patch` | `XCRUN`/`PAX`/`PLUTIL`/`HOST_CODESIGN` 改 PATH 解析；新增 `HOST_COMPAT_CFLAGS`/`HOST_COMPAT_LIBS`/`HOST_CSH` 让 `SETUP/` 主机工具编得动；`doconf` 经 `$(HOST_CSH)` 调用；`Makefile` 里 6 处硬编码 `/usr/sbin/sysctl` |
| `portable-kalloc-type-builtins.patch` | `__builtin_xnu_type_summary`/`_signature`/`_types_compatible` 是 Apple clang 扩展，上游 LLVM 没有；回退到「只报 data 粒度」 |
| `llvm-clang-arm64-crypto-asm.patch` | `arm64_isa_compatibility.h` 按解析能力选 `qN`/`vN.4s`；上游 LLVM 拒绝 `sha256h q0, q1` |
| `iig-method-forwarders.patch` | iig 不生成的转发体（`UserSetProperties` 等） |
| `linux-link-shims.patch` | PGO 的 `__llvm_profile_*`、`__cxa_atexit`、`vm_tests.c` 用的旧 API 名 |

`scripts/sync-patches.sh <device-repo>` 把它们同步进设备仓（构建按
`find | sort` 从 `<device>/patches/xnu/` 应用）。本仓库是这些补丁的唯一来源。

---

## 8. 已知缺口

1. **工具链要 `bootstrap.sh` 造一次**，不能只靠仓库里的脚本就跑。CI 里要把
   `$PREFIX` 做成按内容哈希缓存的 artifact。
2. **`.iig.cpp` 的 `X_<M>_Invoke` 是签名正确的桩**（返回
   `kIOReturnUnsupported`），没复刻 RPC 参数解码；`_Dispatch` 转发到 `Dispatch()`，
   后者也是桩。符号齐、能链接、能过 prelink 绑定，但**运行时 DriverKit 的
   RPC 派发不通**。写走 DriverKit 接口的驱动前必须补。
3. **`libfirehose_kernel` 依赖的 SDK 私有头**（`chunk_private.h`、
   `tracepoint_private.h`、`firehose_types_private.h`）是从 Apple SDK 提取的，
   手工放在 fakeroot 里，本仓库没有脚本摆放——冷构建会缺头，且有再分发问题。
   `sys/_pthread/_pthread_*.h` 由 `scripts/build-firehose-linux.sh` 自己生成。
4. **构建对增量状态敏感**：改完 `iig` 要删 `build/xnu/**/DriverKit/*.h`；
   `installhdrs` 的产物会被 tree 装配清掉而 `kernel.py` 先跑 archive 再跑内核，
   冷启动要先跑一次 `build-xnu-4k-baseline.sh`；树搬家后旧 `.d` 里是过期绝对路径。
5. **`-Werror` 只对清单外的诊断生效**，见第 3 节。
6. **只跑过 `bootstrap_defconfig` 与 `uke-full_defconfig`**，`uke_defconfig`
   （first-console）没验过。没验重建确定性（两次构建 sha256 不同），没做启动测试。
7. **并行 make 偶发比串行失败**（链接那步），定位阶段用 `JOBS=1 RC_XBS=YES`。

---

## 9. 参考

- [markmentovai/bootstrap_cmds](https://github.com/markmentovai/bootstrap_cmds/tree/cross_platform) — MIG 的 Linux 可移植移植
- [tpoechtrager/cctools-port](https://github.com/tpoechtrager/cctools-port) — Apple cctools + ld64 的 Linux 移植
- [lzfse/lzfse](https://github.com/lzfse/lzfse) — `compression_tool` 的后端
- [`docs/LINUX-BUILD.md`](docs/LINUX-BUILD.md) — 完整调研与实施记录

补丁里含 Apple 开源代码的衍生内容，按 APSL v2.0 处理；shim 与生成器是本仓库原创。
