# AndroidJBR

[![CI](https://github.com/I-hope1/AndroidJBR/actions/workflows/ci.yml/badge.svg)](https://github.com/I-hope1/AndroidJBR/actions/workflows/ci.yml)
[![Full build](https://github.com/I-hope1/AndroidJBR/actions/workflows/build-hosted.yml/badge.svg)](https://github.com/I-hope1/AndroidJBR/actions/workflows/build-hosted.yml)

**JetBrains Runtime for Android arm64 — patches plus reproducible build scripts.**

把 [JetBrainsRuntime](https://github.com/JetBrains/JetBrainsRuntime) 交叉编译到
Android/bionic aarch64（最低 API 21），产出 PojavLauncher / Amethyst / FCL
可直接导入的 JRE。HotSpot 保留 JBR 的**增强类重定义（DCEVM）**：
`-XX:+AllowEnhancedClassRedefinition` 下可以增删字段/方法、修改父类后再
`redefineClasses`（原生 HotSpot 只允许改方法体）。

English: `git apply`-able port patches plus numbered build scripts that turn a
pinned JetBrainsRuntime tree into a PojavLauncher-compatible bionic aarch64 JRE
with JetBrains' enhanced class redefinition intact.

## 支持矩阵

| JBR line | 上游 pin | 状态 | 产物 |
|---|---|---|---|
| **21** | `jbr21` @ `015db36d`（21.0.11） | ✅ 已构建 + **真机验证**（见下） | [Release v21.0.11-r3](https://github.com/I-hope1/AndroidJBR/releases/tag/v21.0.11-r3) |
| **25** | `jbr25` @ `1b5d5af9`（25.0.5.0.3） | ⚠️ **实验性**：✅ 已构建成功（24 分钟/2 vCPU），⏳ 未真机验证 | [Release v25.0.5-r1](https://github.com/I-hope1/AndroidJBR/releases/tag/v25.0.5-r1) |

选择 line：

```bash
./scripts/build.sh            # JBR 21（默认）
./scripts/build.sh --jbr 25   # JBR 25（实验性）
JBR_LINE=25 ./scripts/check-patch.sh
```

## 验证状态

**JBR 21（已验证）**

- ✅ 交叉编译全链路成功；`libjvm.so` 为 ELF64 AArch64、`.note.android.ident`
  为 API 21 / NDK r27c，`NEEDED` 仅 `libm.so libdl.so libc.so`。
- ✅ **真机验证**（v5-tagfix；final-r3 只移除了诊断打印）：
  - 结构热更 + 64 个存活实例（加 `int` + `Object` 字段）：`LIVEPROBE: PASS`
  - 纯 JIT `java -jar ecj.jar`：3/3 正常退出（修复前必崩）
  - `-javaagent:boot-probe.jar`：`BOOTPROBE: PASS`
  - 7 分钟 JIT 压测（≈4.3e10 次多态调用 + 6 次结构热更）无崩溃
  - Remold 端到端：`Structural HotSwap Supported: true`，355 ms 完成热更

**JBR 25（实验性）**

- ✅ 补丁（AngelAuraMC `jdk25u_android.diff` 基底 + AndroidJBR 修复集）对 pin
  做 `git apply --check` + 实际应用校验（CI 矩阵成员）：55 文件，+1774/−103。
- ✅ **构建成功**（2026-11-14，aarch64 主机，2 vCPU，`make images` 1423 秒）：
  `libjvm.so` 为 ELF64 AArch64、API 21，`release` = `JAVA_VERSION="25.0.5.0.3"`。
  构建中修掉的 JDK 25 差异：`make JOBS=N`、`--build=<host>` 强制 cross（否则
  adlc 被编成 bionic 二进制）、关闭 clang 不兼容的 PCH、`dictionary.hpp`
  DCEVM 内联函数改用 out-of-line 定义。
- ⏳ **未在真机验证**：产物已发布，请按 `docs/DEVICE-TEST.md` 跑 probe 后再当
  稳定版用。

## 为什么需要它

PojavLauncher 自带的 OpenJDK 21 是标准 HotSpot：`redefineClasses` 不能改类
结构（schema），现代热重载/热修复工具（如 Remold、DCEVM 系 agent）会直接失败。
JBR 的 DCEVM 实现允许 schema 变更，本仓库把它搬到 bionic 上，并修掉了移植过程
中暴露的 Android 专属问题（JBR 21 已验证；JBR 25 已随补丁移植）：

| 问题 | 修法 |
|---|---|
| bionic C-heap 指针带 top-byte tag，aarch64 `movptr` 只编码 48 位，tag 被静默截断 → `free()` 时 SIGABRT | `os::malloc/free/realloc` 在 libc 边界做 untag/retag（`src/hotspot/share/runtime/os.cpp`） |
| `libinstrument` / `libjdwp` 的 `codeset` 被移植补丁设为 `"ASCII"`，走 bionic iconv 崩溃 | 改为 `"UTF-8"`（Android 平台编码就是 UTF-8），`utfInitialize()` 直接早退 |
| headless 配置下不构建 `libfontmanager_xawt.so`，FCL 的 cacio 字体路径加载失败 | 放开 AWT 库构建的 headless 门控（JBR 25 上适配到新的 `lib/*.gmk` 布局） |
| `os::get_temp_directory()` 硬编码 `/data/tmp`（App 沙箱不可写） | `TMPDIR` → `/tmp` → `/data/local/tmp` 兜底 |
| 移植补丁遗留：`ifaddrs` 野指针、`#define nullptr 0`、`awt_LoadLibrary.c` 空指针、`processor_id()` 越界等 | 逐条修复，见 `docs/KNOWN-ISSUES.md` |

## 仓库结构

```
patches/jbr21/      JBR 21 补丁 + series（已构建、真机验证）
patches/jbr25/      JBR 25 补丁 + series（实验性）
scripts/            env/lib + fetch-deps + setup-toolchain + 01..05 + build.sh
docs/               BUILD.md（构建细节）DEVICE-TEST.md（真机导入/自检）KNOWN-ISSUES.md
.github/workflows/  ci.yml（双 line 补丁校验）/ build-full.yml（手动完整构建，自托管 arm64）
```

| 脚本 | 作用 |
|---|---|
| `scripts/check-patch.sh` | 不下载整棵树，只 sparse 检出补丁触及的文件并验证应用（约 5 秒） |
| `scripts/fetch-deps.sh` | 下载 NDK r27c、Temurin boot JDK（21.0.13+9 / 25.0.5+8）、freetype/CUPS 源码，clone Pojav 构建仓库与 termux-elf-cleaner |
| `scripts/setup-toolchain.sh` | 生成 clang 包装器、交叉编译 freetype、构建 elf-cleaner，并做 C/C++ aarch64 冒烟链接 |
| `scripts/01-clone-jbr.sh` | 取所选 line 的 JBR pin（blob-less 浅取） |
| `scripts/02-apply-patches.sh` | 校验并应用 `patches/jbr<N>/series`，提交本地结果 |
| `scripts/03-configure.sh` | `configure`（headless、server VM、bionic aarch64） |
| `scripts/04-build.sh` | `make images` |
| `scripts/05-package-jre.sh` | jlink + Pojav `jre_override` + strip + elf-cleaner → `tar.xz` |
| `scripts/build.sh` | 一键串联全部步骤（`--jbr 21|25`） |

## 快速开始

要求：**aarch64 Linux 主机**（原构建在 Ubuntu 24.04 aarch64、2 vCPU 上完成，
约 1 小时），`clang-18`/`lld-18`/`llvm-18`、`make`、`autoconf`、`cmake`、
`xz`、`git`、`curl`。无 root 环境可按 `docs/BUILD.md` 的做法解包 `.deb`。

```bash
git clone https://github.com/I-hope1/AndroidJBR.git
cd AndroidJBR

./scripts/check-patch.sh           # 5 秒：确认补丁和 pin 一致
./scripts/build.sh                 # JBR 21 完整流水线（依赖 → 工具链 → 构建 → 打包）
./scripts/build.sh --jbr 25        # JBR 25（实验性）
```

产物：

```
out/jre<21|25>-jbr-android-arm64-<YYYYMMDD>.tar.xz  # ~30 MB，解压 ~140 MB
out/jre25-jbr-android-arm64-<YYYYMMDD>.tar.xz   # 仅在 JBR 25 构建成功后
out/SHA256SUMS.txt
```

已发布的构建见 [Releases](https://github.com/I-hope1/AndroidJBR/releases)；
导入启动器、启动参数与自检方法见 [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md)。

### 复用已有工具链

所有路径都能用环境变量覆盖，例如：

```bash
WORK=/data/androidjbr \
NDK=/opt/android-ndk-r27c \
BOOT_JDK=/opt/jdk-21.0.13+9 \
./scripts/build.sh --skip-deps
```

## CI

| workflow | 触发 | 内容 |
|---|---|---|
| `ci.yml` | push / PR | 两条 line 的补丁校验（~15s）+ shellcheck + 脚本 fail-fast |
| `build-hosted.yml` | 手动 dispatch | **GitHub 托管 runner（ubuntu-24.04 / x86_64）完整构建**，产物作为 artifact 上传。JBR 25 已验证：✅ 2026-11-14，run [43579547510](https://github.com/I-hope1/AndroidJBR/actions/runs/43579547510)，18 分钟，artifact 30 MB |
| `build-full.yml` | 手动 dispatch | 自托管 arm64 runner 完整构建（需要自备 runner） |

托管构建实测：JBR 25 从冷启动到上传 artifact 共 **18 分钟**（4 vCPU、含 NDK /
Temurin / freetype 下载与全部编译）；JBR 21 在 2 vCPU 上约 1 小时，托管 runner
上更短。依赖（NDK / Temurin / freetype / elf-cleaner / 头文件）走 `actions/cache`。
CI 产物与本地发布的 tar.xz **字节不同但结构一致**（宿主编译器/路径差异；
`release` 里 `JAVA_RUNTIME_VERSION` 带构建机名后缀），校验方式同 `docs/DEVICE-TEST.md`。

```bash
gh workflow run build-hosted.yml -f jbr=25 -f jobs=4
gh run watch
```

## 使用（手机侧，JBR 21 产物）

1. 把 `tar.xz` 传到手机（如 `Download/`）。
2. 启动器 → **Java Runtimes / Java** → **Add new / 导入** → 选中该包，等待解压；
   列表应显示 `21.0.11`、`aarch64`。
3. 需要结构热更时，在 `javaArgs` 加 `-XX:+AllowEnhancedClassRedefinition`。
4. 自检（第一次上真机必做）：

   ```
   -XX:+AllowEnhancedClassRedefinition -javaagent:/sdcard/Download/dcevm-probe.jar
   ```

   日志出现 `DCEVM_PROBE: PASS` 即 DCEVM 在设备上可用；原生 HotSpot 会打印
   `FAIL - attempted to change the schema`。

注意：DCEVM 只支持 G1/Serial GC；**不要开 JFR**（会静默关闭 DCEVM）；
没有 `libattach.so`，agent 只能用 `-javaagent:`/`-agentpath:` 在命令行注入。

## 已知限制

- headless 构建：没有 `libawt_xawt.so`（启动器用自己的假库），无 JCEF/Vulkan 等桌面特性。
- 每次结构热更会 deopt 整个代码缓存，手机上单次可能卡顿数百 ms 到数秒。
- 模块集按 Pojav 的 jlink 清单（不含 `jdk.internal.vm.ci`）。
- JBR 25 是实验轨道：构建已通过（见上），但尚未真机验证。
- 完整清单与取舍见 [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)。

## 文档

- [docs/BUILD.md](docs/BUILD.md) — 工具链原理、完整 configure 参数、双 line 说明、构建与打包细节
- [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md) — 真机导入、启动参数、自检与排错
- [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) — 修复记录、评审结论、已知坑
- [patches/README.md](patches/README.md) — 补丁来源、构成与再生成方法

## 许可

本仓库的补丁与构建脚本衍生于 OpenJDK 与 JetBrainsRuntime，按
**GPLv2 + Classpath Exception** 分发（见 `LICENSE`、`ADDITIONAL_LICENSE_INFO`），
与上游保持一致。产出的 JRE 同样受该许可约束。
