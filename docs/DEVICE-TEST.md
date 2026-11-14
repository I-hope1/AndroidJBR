# 真机导入与自检（DEVICE-TEST）

产物是 **bionic aarch64** 的 JRE，只能用于 Android arm64 设备（API 21+）。
x86_64 / arm32 设备或桌面 JVM 不能使用。

> 当前已发布产物：**JBR 21（21.0.11，真机验证过）** 和 **JBR 25（25.0.5.0.3，实验性）**。
> JBR 25 已构建成功但**没有真机验证记录**；下面的导入/自检步骤同样适用，建议先跑
> `dcevm-probe.jar` 再当稳定 runtime 用。

## 1. 产物

从 [Releases](https://github.com/I-hope1/AndroidJBR/releases) 下载：

| 文件 | 说明 |
|---|---|
| `jre21-jbr-android-arm64-<date>.tar.xz` | ~30 MB，解压 ~140 MB，启动器可直接导入 |
| `dcevm-probe.jar` | DCEVM 自检 agent |
| `SHA256SUMS.txt` | 校验和 |

校验：

```bash
sha256sum -c SHA256SUMS.txt
```

## 2. 导入（按启动器）

### PojavLauncher v3 / Amethyst

1. 把 `.tar.xz` 传到手机（如 `Download/`）。
2. 启动器 → **Settings → Java Runtimes**（Amethyst 在 **Java** 页）→
   **Add new / 导入** → 选择该文件，等待解压完成。
3. 列表中应显示版本 `21.0.11`、架构 `aarch64`；把它设为默认 runtime。

### FCL（Fold Craft Launcher）

FCL 的 Java 管理页导入同一个 `.tar.xz` 即可。FCL 启动时会用 `RuntimeUtils.patchJava()`
把自带的假 `libawt_xawt.so` 覆盖进运行时目录（cacio 不需要真实 X11 渲染后端）。
本产物已包含 FCL 所需的 `libfontmanager_xawt.so`，见 `docs/KNOWN-ISSUES.md`。

### 无 root 手动放置（adb，debuggable 启动器）

解压到 `/data/data/<包名>/runtimes/<任意名>/`，目录内必须有 `release`、`bin/`、`lib/`。
该目录就是启动器看到的 runtime 根。

## 3. 启动参数

需要结构热更（DCEVM）时，在全局或 profile 的 `javaArgs` 里加：

```
-XX:+AllowEnhancedClassRedefinition
```

规则：

- DCEVM **只支持 G1 或 Serial GC**。不显式指定时 JBR 自动选 G1；显式写
  `-XX:+UseZGC` / `-XX:+UseShenandoahGC` 会在启动时报
  `Must use the Serial or G1 GC with enhanced class redefinition.`
- **不要开 JFR**（`-XX:StartFlightRecording`）：JBR 会静默关闭 DCEVM，表现为
  重定义退回原生行为而不是报错。
- 没有 `libattach.so`：agent 只能用 `-javaagent:` / `-agentpath:` 在命令行注入，
  不能 jcmd/jdb attach。
- Pojav 的参数解析会丢弃含两个 `=` 的参数；本 flag 没有 `=`，可以正常透传。

## 4. 自检（第一次上真机必须做）

```bash
adb push dcevm-probe.jar /sdcard/Download/
```

启动器参数：

```
-XX:+AllowEnhancedClassRedefinition -javaagent:/sdcard/Download/dcevm-probe.jar
```

logcat / 游戏日志里应出现：

```
DCEVM_PROBE: PASS - schema-changing redefine worked, new field b = public int p.Target.b
```

对照实验（同一个 jar 放到原生 HotSpot）：

```
DCEVM_PROBE: FAIL - java.lang.UnsupportedOperationException: class redefinition failed: attempted to change the schema
```

若设备上也是 FAIL：

1. 确认启动器实际用的是本 runtime（版本页显示 21.0.11 / aarch64）；
2. 确认 `-XX:+AllowEnhancedClassRedefinition` 在生效参数里；
3. 确认没有开 JFR、没有显式 ZGC/Shenandoah；
4. 抓 logcat 里 `DCEVM` / `Must use the Serial` 关键字。

## 5. 常见问题

**启动即崩，日志有 `Pointer tag ... was truncated`。**
这是 bionic 指针 tag 与 aarch64 48 位常量截断的典型症状；本产物（final-r3）
已修复。如果复现，说明用的是旧版本包，换 Release 里的 final-r3。

**`UnsatisfiedLinkError: Can't load library: .../lib/libfontmanager_xawt.so`。**
FCL 的 cacio fontmanager 路径会加载它；本产物已包含。若是自己构建的包，
确认 `Awt2dLibraries.gmk` 的 headless 门控已按补丁放开。

**`java.lang.UnsatisfiedLinkError` 指向 `AWTLoadFont` / `X11` 符号。**
FCL 的假 `libawt_xawt.so` 不提供这些符号；JVM 以 `RTLD_LAZY` 加载，不调用就
不报错。若 cacio 走了真实 X11 字体路径，改用 Freetype 字体路径（FCL 默认）。

**启动器提示版本不兼容 / 无法识别 runtime。**
检查 `release` 文件里是否有 `JAVA_VERSION` 与 `OS_ARCH`（本产物有）。手动改包
时不要把 `release` 弄丢或改名。

**Android 5/6 上报链接器警告。**
本包已做 API 21 ELF 清理；若仍出现，确认没有被其他工具二次处理过 `.so`。

## 6. 已知限制（真机相关）

- headless：没有 `libawt_xawt.so`、没有 JCEF/Vulkan；对 Minecraft 启动器场景足够。
- 每次结构热更都会 deopt 整个代码缓存（JBR 实现如此），手机上有可感知卡顿，
  适合开发期热重载，不适合高频运行时热补丁。
- 模块集不含 `jdk.internal.vm.ci`：若某个工具依赖 JVMCI 会缺失（Minecraft/Forge/
  OptiFine 安装器不需要）。
