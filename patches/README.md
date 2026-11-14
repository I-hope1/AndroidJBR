# patches/

按 JetBrainsRuntime line 分目录，每个目录一个 `series` 文件：

```
patches/
├── jbr21/
│   ├── series                     # 补丁应用顺序
│   └── jbr21-android-port.patch   # 单个合并补丁（相对 jbr21 pin 的完整 diff）
└── jbr25/
    ├── series
    └── jbr25-android-port.patch   # 相对 jbr25 pin 的完整 diff（实验性）
```

`scripts/env.sh` 根据 `JBR_LINE` 选择目录（默认 21）。要新增一条 line：建
`patches/jbr<N>/series` + 补丁，并在 `scripts/env.sh` 的 case 里加 pin/boot JDK。

---

## jbr21（已验证）

对 `JetBrains/JetBrainsRuntime` **`jbr21` @ `015db36dcaaf5fd670735a10b74dd413b190a40d`**
（21.0.11）的完整移植 diff，`git apply` 可干净应用：

```
 44 files changed, 978 insertions(+), 80 deletions(-)
```

来源层次：

| 层 | 来源 |
|---|---|
| 基础树 | JetBrainsRuntime `jbr21` @ `015db36d`（21.0.11） |
| Android/bionic 移植 | `PojavLauncherTeam/android-openjdk-build-multiarch` @ `f3936fb`，`patches/jre_21/android/jdk21u_android.diff` + `26_skip_proc_net6_check.diff` |
| 冲突处理 | 移植 diff 打到 jbr21 时的 6 个冲突 hunk 手工解决：`flags-cflags.m4`、`libraries.m4`、`JvmMapfile.gmk`、`Awt2dLibraries.gmk`、`UnixNativeDispatcher.c`、`awt_LoadLibrary.c` |
| 构建系统修复 | `GenerateLinkOptData.gmk` + `HelloClasslist.java`（headless classlist）、`Awt2dLibraries.gmk`（headless 下构建 `libfontmanager_xawt.so`）、`libraries.m4`（`ANDROID_BUILD=1` 时跳过 ALSA/DBus） |
| 运行时修复 | `os.cpp`（bionic tag untag/retag、`TMPDIR` 临时目录、MTE）、`EncodingSupport_md.c` + `utf_util.c`（UTF-8 codeset）、`os_linux.cpp`（`jvm_path`、`fork_and_exec`、`processor_id`）、`os_perf_linux.cpp`（`ifaddrs`）、`net_util_md.h`（`__ANDROID__`）、`awt_LoadLibrary.c`、`UnixNativeDispatcher.c` |
| 评审跟进 | 见 `docs/KNOWN-ISSUES.md`；最终版移除了所有 `JBR_DIAG` 诊断代码 |

文件构成（44）：

| 区域 | 文件数 | 内容 |
|---|---|---|
| 构建系统 `make/` | 20 | 目标三元组、clang/lld、android OS defines、`--hash-style=sysv`、headless 调整、模块 gmk 接线 |
| HotSpot `src/hotspot/` | 14 | linux/posix/bionic OS 层、aarch64 thread-local、arm/arm32/x86 CPU 文件、ELF/全局宏、`os::malloc/free/realloc` untag/retag、临时目录、MTE |
| JDK native/Java | 10 | bionic 路径（`/system/bin/sh`、`/data/local/tmp`）、net/proc 检查、`libinstrument`/`libjdwp` UTF-8、`awt_LoadLibrary.c` |

---

## jbr25（实验性）

对 `jbr25` @ `1b5d5af9510803fdc84f14dc636282d6cd02a5aa`（2026-11-06）的完整 diff，
`git apply` 可干净应用：

```
 55 files changed, 1774 insertions(+), 103 deletions(-)   # 50 modified + 5 added
```

状态：**已构建成功**（2026-11-14，`make images` 1423 秒 / 2 vCPU），**未真机验证**。
补丁 sha256 `26026f21fc286ca29ffb94eab2b996b42673e962d81a76b7774fa33baa957980`；
构建中额外修正了 `dictionary.hpp` 的 DCEVM 内联函数（JDK 25 只前向声明
`InstanceKlass`，改为在 `dictionary.cpp` 里 out-of-line 定义）。

| 层 | 来源 |
|---|---|
| 基础树 | JetBrainsRuntime `jbr25` @ `1b5d5af9` |
| Android/bionic 移植 | `AngelAuraMC/angelauramc-openjdk-build` 分支 `fcl/BUILD_JRE_25` 的 `patches/jdk25u_android.diff`（52 文件，sha256 `c9aa3e953f9abcf1f4b3b3ac2af92d1a33fca9349d5cca6c38c4b75db450119b`） |
| 冲突处理 | 6 个冲突 hunk（4 个文件；基底文件是两段补丁拼接，`libraries.m4` 各自拒一次）手工解决：`make/autoconf/libraries.m4`、`make/modules/java.desktop/lib/ClientLibraries.gmk`、`src/hotspot/os/linux/os_linux.cpp`、`src/java.desktop/unix/native/libawt/awt/awt_LoadLibrary.c` |
| AndroidJBR 修复集 | 从 jbr21 补丁逐条移植（headless classlist、headless 下 `libfontmanager_xawt.so`、`os.cpp` bionic tag/临时目录/MTE、UTF-8 codeset、`ifaddrs`、`jvm_path`/`fork_and_exec`/`processor_id`、`net_util_md.h`、`awt_LoadLibrary.c`、评审修复） |
| 与 JDK 21 的结构差异 | `make/hotspot/lib/JvmMapfile.gmk` 在 25 中已移除；`make/modules/java.desktop/lib/Awt2dLibraries.gmk` 拆分为 `AwtLibraries.gmk` / `ClientLibraries.gmk` 等——补丁按新布局适配，未回填已删除文件 |
| 构建期修复（2026-11-14） | `dictionary.hpp`/`dictionary.cpp`：DCEVM `old_if_redefining()` 在 JDK 25 头文件里只剩前向声明，改为 out-of-line 定义 |

构建注意：JBR 25 需要 Temurin **25.0.5+8** 作 boot JDK（`fetch-deps.sh` 会按
line 自动选版本）。configure flag 与 21 相同，但有三处 line 专属差异（见
`scripts/env.sh` / `scripts/03-configure.sh`）：

1. `make JOBS=N`（JDK 25 拒绝 `make -jN`）；
2. 显式传 `--build=<host config.guess>` 强制交叉编译，否则 adlc 等 build tool
   会被编成 bionic 二进制；
3. `PRECOMPILED_HEADERS=disabled`（clang 不能直接用 JDK 25 预期的 gcc 式 `.gch`）。

---

## 重新生成补丁（编辑后）

```bash
# 1. 在对应 line 的构建树里编辑（01 + 02 已把 series 应用成一次本地提交）
$EDITOR work/JetBrainsRuntime-21/src/hotspot/...
#    或 work/JetBrainsRuntime-25/...

# 2. 相对 pin 重新生成
cd work/JetBrainsRuntime-21
git diff 015db36dcaaf5fd670735a10b74dd413b190a40d > ../../patches/jbr21/jbr21-android-port.patch
cd ../JetBrainsRuntime-25
git diff 1b5d5af9510803fdc84f14dc636282d6cd02a5aa > ../../patches/jbr25/jbr25-android-port.patch

# 3. 证明仍能干净应用（不下载整棵树，约 5 秒）
./scripts/check-patch.sh              # JBR 21
JBR_LINE=25 ./scripts/check-patch.sh  # JBR 25
```

`scripts/02-apply-patches.sh` 会把应用后的树提交为一次本地 commit（作者
`AndroidJBR`），所以正常构建期间 HEAD 比 `$JBR_PIN` 多一个提交。

## 范围与限制

- **不是通用桌面 Linux 补丁**：假定就是这套交叉构建——`TARGET_OS` 仍是 `linux`
  （`make/autoconf/platform.m4` 的 android 分支故意排在 `*linux*` 之后），
  `--hash-style=sysv`、`-D__USE_BSD` 全局生效（bionic `linker64` 需要），
  `libraries.m4` 仅在 `ANDROID_BUILD=1` 时跳过 ALSA/DBus。
- 上游漂移会导致冲突：升 pin 是"重新生成 + 重测"的显式操作。
- jbr25 补丁目前只保证**可应用**；是否可构建、DCEVM 是否可用需实际构建验证
  （见 README「支持矩阵」）。
