# P0 补丁构建与验证记录

> 日期：2026-11-14
> 目标：在 JBR 25 上编译并验证 P0（safepoint-safe 排空等待 + 并发重定义引用计数）补丁
> 结果：**fastdebug aarch64 构建成功，全部 P0 测试通过（含 SafepointALot 并发压测、CFLH 嵌套重入 fail-fast）**；过程中发现并修掉两个 v2 未覆盖的上游并发缺陷（enhanced redefine prologue 未串行化、嵌套重定义会自锁）。

> 补丁版本：**v4**（v2 → v3 加 prologue 串行化 → v4 加嵌套重入 fail-fast）。

---

## 1. 构建

| 项 | 值 |
|---|---|
| 源码树 | `/home/ubuntu/jbr25-port/JBR25`（JBR 25.0.5 @ `1b5d5af9` + Android 移植） |
| 配置 | `linux-aarch64-server-fastdebug`，**headless-only**，gcc 13.3，boot JDK Temurin 25.0.5+8（`/home/ubuntu/jbr25-build/jdk-25.0.5+8`） |
| 构建命令 | `make CONF=fastdebug JOBS=2 images` |
| 产物 | `build/linux-aarch64-server-fastdebug/images/jdk`（1.7 GB，fastdebug，可运行） |
| 主机 | 2 vCPU aarch64 / 11 GB RAM / Ubuntu 24.04，无 sudo |

主机是精简镜像（无 X11/fontconfig/alsa/cups dev 包），因此从 Ubuntu 仓库 `apt-get download` 了 arm64 dev/runtime 包，`dpkg -x` 解压到 `/home/ubuntu/jbr25-port/deps`，用最小 include 目录 `/home/ubuntu/jbr25-port/inc-min`（只暴露 `alsa/`、`fontconfig/`、`cups/`、`freetype2/`）喂给 configure，避免外部 `jpeglib.h` 覆盖 JDK bundled libjpeg。

```bash
export PATH=/home/ubuntu/android-jbr-research/local/bin:$PATH
export PKG_CONFIG_PATH=/home/ubuntu/jbr25-port/deps/usr/lib/aarch64-linux-gnu/pkgconfig:/home/ubuntu/jbr25-port/deps/usr/share/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/home/ubuntu/jbr25-port/deps
bash configure --with-debug-level=fastdebug --enable-headless-only \
  --with-toolchain-type=gcc --with-boot-jdk=/home/ubuntu/jbr25-build/jdk-25.0.5+8 \
  --with-alsa-include=/home/ubuntu/jbr25-port/inc-min \
  --with-alsa-lib=/home/ubuntu/jbr25-port/deps/usr/lib/aarch64-linux-gnu \
  --with-fontconfig-include=/home/ubuntu/jbr25-port/inc-min \
  --with-cups-include=/home/ubuntu/jbr25-port/inc-min \
  --with-zlib=bundled \
  --with-extra-ldflags="-L/home/ubuntu/jbr25-port/deps/usr/lib/aarch64-linux-gnu -Wl,-rpath,/home/ubuntu/jbr25-port/deps/usr/lib/aarch64-linux-gnu" \
  --disable-warnings-as-errors
# 构建期 java.desktop/libawt 的 fontconfigmanager.c 不经过 FONTCONFIG_CFLAGS，
# 因此在生成的 spec.gmk 的 CFLAGS_JDKLIB/CXXFLAGS_JDKLIB 末尾追加 -I inc-min
make CONF=fastdebug JOBS=2 images
```

> 构建期间遇到并修掉的问题（供复现者参考）：
> 1. `Thread::current()->thread_state()` 在 JDK25 不存在 → 改用 `JavaThread::current()`；
> 2. `cups/ppd.h` 需要 `cups/raster.h`（`libcupsimage2-dev`）；
> 3. 全局 `-I deps/usr/include` 会让外部 `jpeglib.h` 覆盖 bundled libjpeg → 改为最小 include 目录；
> 4. `fontconfigmanager.c` 不吃 `FONTCONFIG_CFLAGS` → 在 spec.gmk 的 `CFLAGS_JDKLIB` 里追加 `-I inc-min`（仅本机构建用，不入补丁）。

## 2. 补丁

`patches/p0-notify-wait-v4.patch`（6 文件，+152/−28），= v2 内容 + **并发 enhanced redefine 串行化** + **嵌套重入 fail-fast**：

| 文件 | 内容 |
|---|---|
| `runtime/mutexLocker.{hpp,cpp}` | 新增 rank=`safepoint` 的 `DcevmCompilationWait_lock` |
| `compiler/compileBroker.{hpp,cpp}` | `_compilation_stop_count` 引用计数、`EnhancedClassRedefinitionCompilationStop` RAII、safepoint-safe 排空等待（`ThreadInVMfromNative` 适配）、递减侧 notify、`_should_block`/`VM_Exit::vm_exited()` 兜底 |
| `prims/jvmtiEnv.cpp` | Redefine/Retransform 分支改用 RAII guard，删除 `_active_redefinitions` |
| `prims/jvmtiEnhancedRedefineClasses.cpp` | **新增**：用 `RedefineClasses_lock` 串行化 concurrent enhanced redefine 的 prologue..epilogue 窗口（`_enhanced_redefinitions_in_progress` + owner 线程；失败路径与 `doit_epilogue()` 释放）；同线程嵌套调用 fail-fast（`JVMTI_ERROR_INTERNAL`），不自锁 |

### 2.1 为什么 v2 不够：并发 prologue 竞态

v2 只保证"编译窗口"不提前打开。并发压测暴露了第二个独立缺陷：`doit_prologue()` 在**调用方 JavaThread** 上执行 `load_new_class_versions()`（含拓扑排序、全局 `Klass` 重定义标志），两个线程的 prologue 可以同时跑：

```
[v2 但未串行化] 4 threads × 100 rounds
-> fastdebug assert at jvmtiEnhancedRedefineClasses.cpp:2625
   assert(klass->check_redefinition_flag(Klass::MarkedAsAffected)) failed
   证据：evidence-fastdebug-assert-no-serialization.log
```

`info`：JBR 里本应负责该串行化的 `EnhancedRedefineClasses_lock` 在 `jvmtiEnv.cpp` 中被注释掉（且 rank/thread-state 不适合在 JVMTI 入口直接使用），所以改为在 prologue/epilogue 上用标准路径同款 `RedefineClasses_lock` 串行化。

### 2.2 v4：嵌套重入 fail-fast

`doit_prologue()` 里会跑 `ClassFileLoadHook`；如果某个 Agent 在 CFLH 回调里（同一线程）再次调用 `RedefineClasses`，单槽位会等自己而死锁。v4 记录 owner 线程：同线程重入直接 `_res = JVMTI_ERROR_INTERNAL; return false;`，外层重定义继续正常完成。实测（`bench.NestedAgent` + `bench.Nested`）：

```
NESTED_ERROR=java.lang.InternalError   # 嵌套调用被拒绝，返回 JVMTI_ERROR_INTERNAL
OUTER_REDEFINE_OK                      # 外层 redefine 正常完成
```

> 标准路径本身支持同线程嵌套（`lock_classes()` 用 per-thread 类表跳过自己）；enhanced 路径的全局状态重入没有上游保证，因此选择 fail-fast 而不是模仿标准路径的语义。

## 3. 验证结果

测试脚本：`bench/p0-verify.sh`（测试程序 `bench.Stress`：single / concurrent / shutdown-hook）。

| 检查 | 未打补丁（预编译 JBR25 25.0.4.1 release） | v4（fastdebug 本地构建） |
|---|---|---|
| 单线程 redefine | 10 轮 138 ms，正常 | 20 轮，`errors=0`，**ForceSafepoint=0**（基线同负载 10 轮 = 6 次） |
| **并发 + `-XX:+SafepointALot`** | — | 4 线程 × 20 轮：**0 崩溃 / 0 错误**（80 次 redefine，3.0 s） |
| 并发 redefine | **4 线程 × 50 轮 → 0.43 s 内 SIGSEGV**（`ConstantPool::klass_ref_at_noresolve`，VMThread；`evidence-jbr25-concurrent-redefine-crash.log`） | **4 线程 × 100 轮 → 0 崩溃 / 0 错误 / ForceSafepoint=0**（16.7 s，fastdebug 含断言开销） |
| CFLH 内嵌套 redefine | — | 嵌套调用 fail-fast（`InternalError`），外层正常完成，不死锁 |
| shutdown hook 里 redefine | — | 正常退出，`HOOK_DONE errors=0` |
| bench.Main body（10 轮） | 正常 | 退出 0，`bad=0 stale=0` |
| bench.Main schema（10 轮） | 正常 | 退出 0，`bad=0 stale=0` |

复现命令：

```bash
cd /home/ubuntu/deopt-study/bench
./p0-verify.sh /home/ubuntu/jbr25-port/JBR25/build/linux-aarch64-server-fastdebug/images/jdk/bin/java
# -> ALL P0 CHECKS PASSED
```

## 3.1 额外交叉核对（Review 提出的三点）

1. **`JvmtiVTMSTransitionDisabler` 位置**：`JvmtiEnv::RedefineClasses()`（`jvmtiEnv.cpp:568`）和 `RetransformClasses()`（:~500）**都没有**包 `JvmtiVTMSTransitionDisabler`；`jvmtiEnv.cpp` 里的 disabler（153/206/666/690/972/…）都属于其它 JVMTI 函数。因此 current P0 的排空窗口不会因为 disabler 而卡住虚拟线程 mount/unmount（P1 接入后也无需调整这一点）。
2. **嵌套重入约束**：已实现 owner 线程 fail-fast（见 §2.2），并有 `bench.Nested` 用例覆盖。
3. **P2 快速路的串行化**：已写进设计文档约束——标准 `VM_RedefineClasses` 与 `VM_EnhancedRedefineClasses` 必须共用**同一个**串行化槽位（不能各自维护 in-progress 标志），否则一条线程走标准路径、一条走增强路径时仍会并发改全局 `Klass` 重定义状态。

## 4. 结论与剩余风险

- **P0 v3 达到预期**：ForceSafepoint 64–374 → 0；并发 redefine 不再崩溃（v2 的编译窗口修复 + v3 的 prologue 串行化缺一不可）；shutdown hook 与正常 redefine 语义保持。
- **尚未验证**：JTReg `serviceability/jvmti/RedefineClasses`、`vmTestbase/nsk/jvmti/RedefineClasses`、`-XX:+SafepointALot`、`-Xcomp` 组合；JBR 21 回移后的构建/测试；Minecraft/Remold 实机负载。fastdebug 构建只覆盖 Linux 桌面 headless，不含 X11/AWT 与 Android 目标。
- **串行化的粒度**：当前是"全局一次只允许一个 enhanced redefine"，比标准路径的 per-class 锁更粗；对 Remold（单线程热更）无影响，但若有并行多 agent 热更需求，可后续换成 `is_being_redefined` 逐类协议（注意与标准路径共享锁/状态的问题，见 §3.1-3）。
- **JTReg**：源码树有 `test/hotspot/jtreg/serviceability/jvmti/RedefineClasses`，但本机未安装 jtreg harness，本轮未跑；建议作为合入前门槛。
- **计时**：fastdebug 数值不能与 release 比；P0 的收益口径仍是"消除 ForceSafepoint 全局 STW 噪音 + 去掉 10 ms 粒度 + 修并发崩溃"，**不改变排空墙钟**（那是 P1 的收益）。
