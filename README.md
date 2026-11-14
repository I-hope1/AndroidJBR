# AndroidJBR

**JetBrains Runtime 21 for Android arm64 — a patch plus reproducible build
scripts.**

把 [JetBrainsRuntime](https://github.com/JetBrains/JetBrainsRuntime) `jbr21`
（21.0.11）交叉编译到 Android/bionic aarch64（最低 API 21），产出
PojavLauncher / Amethyst / FCL 可直接导入的 JRE。HotSpot 保留 JBR 的
**增强类重定义（DCEVM）**：`-XX:+AllowEnhancedClassRedefinition` 下可以
增删字段/方法、修改父类后再 `redefineClasses`（原生 HotSpot 只允许改方法体）。

English: a single `git apply`-able port patch (44 files) plus numbered build
scripts that turn a pinned JetBrainsRuntime `jbr21` tree into a PojavLauncher-
compatible bionic aarch64 JRE, with JetBrains' enhanced class redefinition
(DCEVM) intact. Verified on-device by the original build (see below).

## 验证状态

- ✅ 交叉编译全链路成功，产物 `libjvm.so` 为 ELF64 AArch64、`.note.android.ident`
  为 API 21 / NDK r27c，`NEEDED` 仅 `libm.so libdl.so libc.so`。
- ✅ **真机验证**（用户设备，v5-tagfix；final-r3 只移除了诊断打印）：
  - 结构热更 + 64 个存活实例（加 `int` + `Object` 字段）：`LIVEPROBE: PASS`
  - 纯 JIT `java -jar ecj.jar`：3/3 正常退出（修复前必崩）
  - `-javaagent:boot-probe.jar`：`BOOTPROBE: PASS`
  - 7 分钟 JIT 压测（≈4.3e10 次多态调用 + 6 次结构热更）无崩溃
  - Remold 端到端：`Structural HotSwap Supported: true`，355 ms 完成热更
- ✅ 本仓库的补丁在 CI 中对 pin 做 `git apply --check` + 实际应用校验
- ⚠️ 本仓库**不负责**重新验证真机行为：CI 只验证补丁可应用（完整构建需要
  arm64 自托管 runner，见 `.github/workflows/build-full.yml`）

## 为什么需要它

PojavLauncher 自带的 OpenJDK 21 是标准 HotSpot：`redefineClasses` 不能改类
结构（schema），现代热重载/热修复工具（如 Remold、DCEVM 系 agent）会直接失败。
JBR 的 DCEVM 实现允许 schema 变更，本仓库把它搬到 bionic 上，并修掉了移植过程
中暴露的 Android 专属问题：

| 问题 | 修法 |
|---|---|
| bionic C-heap 指针带 top-byte tag，aarch64 `movptr` 只编码 48 位，tag 被静默截断 → `free()` 时 SIGABRT | `os::malloc/free/realloc` 在 libc 边界做 untag/retag（`src/hotspot/share/runtime/os.cpp`） |
| `libinstrument` / `libjdwp` 的 `codeset` 被移植补丁设为 `"ASCII"`，走 bionic iconv 崩溃 | 改为 `"UTF-8"`（Android 平台编码就是 UTF-8），`utfInitialize()` 直接早退 |
| headless 配置下不构建 `libfontmanager_xawt.so`，FCL 的 cacio 字体路径加载失败 | 放开 `Awt2dLibraries.gmk` 的 headless 门控 |
| `os::get_temp_directory()` 硬编码 `/data/tmp`（App 沙箱不可写） | `TMPDIR` → `/tmp` → `/data/local/tmp` 兜底 |
| 移植补丁遗留：`ifaddrs` 野指针、`#define nullptr 0`、`awt_LoadLibrary.c` 空指针、`processor_id()` 越界等 | 逐条修复，见 `docs/KNOWN-ISSUES.md` |

## 仓库结构

```
patches/            补丁（series + 合并后的 port patch）
scripts/            env/lib + fetch-deps + setup-toolchain + 01..05 + build.sh
docs/               BUILD.md（构建细节）DEVICE-TEST.md（真机导入/自检）KNOWN-ISSUES.md
.github/workflows/  ci.yml（补丁校验）/ build.yml（手动完整构建，自托管 arm64）
```

| 脚本 | 作用 |
|---|---|
| `scripts/check-patch.sh` | 不下载整棵树，只 sparse 检出补丁触及的 44 个文件并验证应用（约 5 秒） |
| `scripts/fetch-deps.sh` | 下载 NDK r27c、Temurin 21 boot JDK、freetype/CUPS 源码，clone Pojav 构建仓库与 termux-elf-cleaner |
| `scripts/setup-toolchain.sh` | 生成 clang 包装器、交叉编译 freetype、构建 elf-cleaner，并做 C/C++ aarch64 冒烟链接 |
| `scripts/01-clone-jbr.sh` | 取 JBR `jbr21` @ `015db36d`（blob-less 浅取） |
| `scripts/02-apply-patches.sh` | 校验并应用 `patches/series`，提交本地结果 |
| `scripts/03-configure.sh` | `configure`（headless、server VM、bionic aarch64） |
| `scripts/04-build.sh` | `make images` |
| `scripts/05-package-jre.sh` | jlink + Pojav `jre_override` + strip + elf-cleaner → `tar.xz` |
| `scripts/build.sh` | 一键串联全部步骤 |

## 快速开始

要求：**aarch64 Linux 主机**（原构建在 Ubuntu 24.04 aarch64、2 vCPU 上完成，
约 1 小时），`clang-18`/`lld-18`/`llvm-18`、`make`、`autoconf`、`cmake`、
`xz`、`git`、`curl`。无 root 环境可按 `docs/BUILD.md` 的做法解包 `.deb`。

```bash
git clone https://github.com/I-hope1/AndroidJBR.git
cd AndroidJBR

./scripts/check-patch.sh        # 5 秒：确认补丁和 pin 一致

./scripts/build.sh              # 完整流水线（依赖 → 工具链 → 构建 → 打包）
# 或分步：
./scripts/fetch-deps.sh
./scripts/setup-toolchain.sh
./scripts/01-clone-jbr.sh
./scripts/02-apply-patches.sh
./scripts/03-configure.sh
./scripts/04-build.sh
./scripts/05-package-jre.sh
```

产物：

```
out/jre21-jbr-android-arm64-<YYYYMMDD>.tar.xz   # ~30 MB，解压 ~140 MB
out/SHA256SUMS.txt
```

已发布的构建见 [Releases](https://github.com/I-hope1/AndroidJBR/releases)。
导入启动器、启动参数与自检方法见 [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md)。

### 复用已有工具链

所有路径都能用环境变量覆盖，例如：

```bash
WORK=/data/androidjbr \
NDK=/opt/android-ndk-r27c \
BOOT_JDK=/opt/jdk-21.0.13+9 \
./scripts/build.sh --skip-deps
```

## 使用（手机侧）

1. 把 `tar.xz` 传到手机（如 `Download/`）。
2. 启动器 → **Java Runtimes / Java** → **Add new / 导入** → 选中该包，等待解压；
   列表应显示 `21.0.11`、`aarch64`。
3. 需要结构热更时，在 `javaArgs` 加：

   ```
   -XX:+AllowEnhancedClassRedefinition
   ```

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
- 未覆盖 FCL 假 `libawt_xawt.so` 缺少的 X11 字体符号（`RTLD_LAZY` 下不调用即不报错）。
- 完整清单与取舍见 [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)。

## 文档

- [docs/BUILD.md](docs/BUILD.md) — 工具链原理、完整 configure 参数、构建与打包细节
- [docs/DEVICE-TEST.md](docs/DEVICE-TEST.md) — 真机导入、启动参数、自检与排错
- [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) — 修复记录、评审结论、已知坑
- [patches/README.md](patches/README.md) — 补丁来源、构成与再生成方法

## 许可

本仓库的补丁与构建脚本衍生于 OpenJDK 与 JetBrainsRuntime，按
**GPLv2 + Classpath Exception** 分发（见 `LICENSE`、`ADDITIONAL_LICENSE_INFO`），
与上游保持一致。产出的 JRE 同样受该许可约束。
