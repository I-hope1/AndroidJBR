# 已知问题与修复记录（KNOWN-ISSUES）

## 1. 产物能力边界

| 项 | 结论 | 原因 |
|---|---|---|
| 平台 | 仅 Android arm64（bionic，API 21+） | ELF 目标为 `aarch64-linux-android21` |
| AWT | headless（无 `libawt_xawt.so`） | `--enable-headless-only=yes`；启动器自带假库 |
| FCL 字体路径 | 支持 | 额外构建了 `libfontmanager_xawt.so` |
| DCEVM | 支持（G1/Serial） | JBR 增强类重定义 |
| JFR + DCEVM | 不可同时用 | JBR 在 JFR 开启时**静默**关闭 DCEVM |
| jcmd/jdb attach | 不可用 | 无 `libattach.so`（agent 只能命令行注入） |
| 结构热更开销 | 全代码缓存 deopt | JBR 实现：`FIXME: for now, deoptimize all!`；手机上单次数百 ms～数秒 |
| JVMCI | 未编译 | `--with-jvm-features=...-jvmci`；模块集也不含 |
| 桌面特性 | 无 | 无 JCEF/Vulkan/字体渲染后端 |

## 2. 已修复问题

| # | 问题 | 症状 | 修复 |
|---|---|---|---|
| 1 | headless 构建缺 `libfontmanager_xawt.so` | FCL 的 cacio agent premain 抛 `UnsatisfiedLinkError` | `Awt2dLibraries.gmk` 放开 headless 门控，构建真正的 JBR X11 font shim |
| 2 | `codeset` 被移植补丁设为 `"ASCII"` | `-javaagent` 注入时 `appendToBootstrapClassLoaderSearch` SIGSEGV（`utfInitialize()` 走 bionic iconv） | `EncodingSupport_md.c` / `utf_util.c` 改为 `"UTF-8"`，让 `utfInitialize()` 早退、`iconvConvert()` 走 memcpy 回退 |
| 3 | bionic C-heap 指针 top-byte tag vs aarch64 48 位 `movptr` | 任意 JIT 代码都可能 SIGABRT（`Pointer tag ... was truncated`，`free()` 内 `MaybeUntagAndCheckPointer`） | `os::malloc/realloc/free` 在 JVM 内部一律 untag 存储，只在交回 libc 的边界 retag/untag |
| 4 | `os_perf_linux.cpp` `new_ifaddrs_storage()` 野指针 | 潜在崩溃（当前树内无调用者） | 恢复 `new (std::nothrow)` 分配，`freeifaddrs()` 对应 `os::free()` |
| 5 | `os::get_temp_directory()` 硬编码 `/data/tmp` | App 沙箱不可写；`JVM_GetTemporaryDirectory`/attach/hsperfdata/hs_err 受影响 | `TMPDIR` → `/tmp` → `/data/local/tmp` 兜底 |
| 6 | Android MTE 随机 heap tag | 固定 tag 还原不可行，崩溃风险 | 首次 `os::malloc` 时 `dlsym("mallopt")` 尝试 `M_BIONIC_SET_HEAP_TAGGING_LEVEL(-204) → NONE(0)`；老系统静默忽略，并检测 tag 是否变化打警告 |
| 7 | `awt_LoadLibrary.c` `buf` 未初始化 / `strchr` 空指针 | `p==NULL` 时下游 `strncpy` 必崩 | `buf` 置空、校验 `realpath`、maps 解析加边界检查、`p==NULL` 退回 `buf` |
| 8 | `os_linux.cpp` `jvm_path` 相对路径分支 | product 版 `assert` 不生效且不写缓存 | 失败时 `buf[0]=0`，不再提前 return，统一缓存 |
| 9 | `os::fork_and_exec` 只用 `/bin/sh` | Android 上是 `/system/bin/sh` | `__ANDROID__` 下优先 `/system/bin/sh`，否则 `/bin/sh`（proot/rootfs） |
| 10 | `net_util_md.h` 用 `#ifdef ANDROID` | NDK 只定义 `__ANDROID__`，条件实际不生效 | 改为 `__ANDROID__` |
| 11 | `os::processor_id()` 在 `sched_getcpu()` 返回 -1 时 | `(uint)-1` 当数组下标 | 加 `id >= 0 && id < processor_count()` |
| 12 | 移植补丁遗留 `#define nullptr 0` | C++14 下会炸 | 删除 |
| 13 | headless classlist dump 需要 AWT | `GenerateLinkOptData` 失败 | `-Djava.awt.headless=true` + `HelloClasslist.java` 兼容补丁 |

诊断版本（v3/v4）里临时加入的 `JBR_DIAG` 打点（`os::free` 坏指针检测、
ICHolder 释放跟踪、`libinstrument` 入口打点）在 **final-r3 已全部移除**，
行为与修复版一致。

## 3. Patch review 结论（final-r3）

| 评审点 | 结论 | 处理 |
|---|---|---|
| `os.cpp` tag 读写的 known/tag 顺序竞态 | 属实（极小窗口，仅 tagging 未关闭时） | 按决定**未改**，记录在案 |
| `#define nullptr 0` 全局宏 | 属实 | 已删 |
| `awt_LoadLibrary.c` `buf`/`strchr` 隐患 | 属实且更严重 | 已修 |
| `os_linux.cpp` `jvm_path` 相对路径 | 属实 | 已修 |
| `fork_and_exec` 只用 `/bin/sh` | 属实 | 已修 |
| `net_util_md.h` `#ifdef ANDROID` | 属实 | 已改 `__ANDROID__` |
| `processor_id()` 返回 -1 | 属实且更严重 | 已修 |
| `platform.m4` android 分支顺序 | 无害死代码（两分支都设 `VAR_OS=linux`） | **不改**：改顺序会让 `TARGET_OS=android`，现有 `isTargetOs linux` 假设全线崩塌 |
| `libraries.m4` 依赖 `ANDROID_BUILD=1` | 属实 | 写进构建说明（必须导出） |
| `Awt2dLibraries.gmk` `ifneq (...,disabled)` 恒真 | 属实（true/false 取值等价） | **不改**：效果正确，动脚本只会增加旧版本 diff 噪音 |
| `--hash-style=sysv`、`-D__USE_BSD` 全局生效 | 属实 | **不改**：bionic/linker64 需要；因此本 patch 不是桌面 Linux 通用 patch |
| `javaThread_linux_aarch64.hpp` 内联实现无 `__ANDROID__` 保护 | **不成立**：内联 `aarch64_get_thread_helper()` 返回 `Thread::current()` 正是 Android 兜底；`.S` 里 `#ifndef __ANDROID__` 的强符号覆盖它，是设计如此 | 不改 |

## 4. 剩余风险

- **未在 x86_64 宿主上端到端验证**：脚本按宿主架构选 Temurin，但本仓库只承诺
  aarch64 宿主的产物。
- **真机验证来自 v5-tagfix，final-r3 只移除诊断打印**：两者行为一致，但没有
  单独为 final-r3 再跑一遍完整压测。
- **tag 顺序竞态（评审第 1 条）保留**：仅在 MTE heap tagging 未关闭的极小窗口
  内可能有问题。
- **FCL 假 `libawt_xawt.so` 缺少 X11 字体符号**：`RTLD_LAZY` 下不调用即不报错；
  若 cacio 走真实 X11 字体路径会 `UnsatisfiedLinkError`。
- **上游漂移**：JBR/OpenJDK 后续改动会让补丁冲突；pin 升级需重跑
  `scripts/check-patch.sh` 并重新验证真机。

## 5. JBR 25 轨道（实验性）

JBR 25 的补丁以 **AngelAuraMC `jdk25u_android.diff`**（52 个 diff 段，sha256 `c9aa3e95…`）
为 bionic 移植基底，再叠加本仓库的 AndroidJBR 修复集，打到 `jbr25` @ `1b5d5af9`。
最终补丁 55 个文件（50 修改 + 5 新增），+1774/−103；6 个冲突 hunk 已手工解决。
已知状态与风险：

| 项 | 状态 |
|---|---|
| 补丁干净应用（`git apply --check`） | ✅ CI 矩阵成员 |
| 构建（configure + make images） | ✅ 2026-11-14：`make images` 1423 秒（2 vCPU），产物 30 MB |
| 真机验证 | ❌ 无设备 |
| DCEVM 可用性 | 静态：`libjvm.so` 含 `AllowEnhancedClassRedefinition`；动态未验证（需真机 probe） |
| 构建期修正 | `dictionary.hpp` DCEVM 内联函数改 out-of-line；`make JOBS=N`；显式 `--build`；JBR 25 轨道关闭 PCH（clang 不兼容 gcc 式 `.gch`） |

建议流程：先在 aarch64 主机 `./scripts/build.sh --jbr 25`，产物按第 8 节校验，
再按 docs/DEVICE-TEST.md 跑 `dcevm-probe.jar`；通过后再把 JBR 25 从"实验性"升级。

## 6. 修复验证记录（真机，v5-tagfix）

| 场景 | 结果 |
|---|---|
| 结构热更（加 `int` + `Object` 字段，64 个存活实例） | `LIVEPROBE: PASS - new size = 32`，exit 0（修复前 SIGABRT） |
| 纯 JIT `java -jar ecj.jar` | 3/3 exit 0（修复前必崩） |
| `-javaagent:boot-probe.jar` | `BOOTPROBE: PASS`（修复前 SIGSEGV） |
| 7 分钟 JIT 压测 | 21419 轮 × 200 万次 ≈ 4.3e10 次多态调用 + 6 次结构热更，无 `Pointer tag`/`BADFREE` |
| Remold 端到端 | `Structural HotSwap Supported: true`；给存活对象加字段后 InitFix 补成 42，新方法立即可调，355 ms 不重启 |

静态校验（构建产物）：

- `libjvm.so`：ELF64 AArch64；`.note.android.ident` = API 21 / NDK r27c；
  `NEEDED` 仅 `libm.so libdl.so libc.so`；含 `AllowEnhancedClassRedefinition`、
  `jvmtiEnhancedRedefineClasses.cpp`。
- `lib/libinstrument.so` 导出 `Agent_OnLoad`/`Agent_OnAttach`；
  `libjvm.so` 导出 `JNI_CreateJavaVM`。
- `release`：`JAVA_VERSION="21.0.11"`、`OS_ARCH="aarch64"`；
  `lib/jvm.cfg` 为 `-server KNOWN / -client IGNORE`。
