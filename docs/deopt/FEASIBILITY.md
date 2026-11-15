# JBR DCEVM deopt / 编译排空优化：可行性分析

> **文档类型**：可行性分析 + 实测记录（2026-11-14）
> **承接**：[`12-jbr-dcevm-jit-drain-tail-latency.md`](https://github.com/I-hope1/Remold/blob/main/docs/topology/12-jbr-dcevm-jit-drain-tail-latency.md)
> **结论先行**：能优化的有两件独立的事——**「deopt 范围」**和**「编译排空等待」**。前者可行但只对"仅改方法体"安全，对 Remold 的结构性热更（`LivingEntity` 加字段/方法）**必须** deopt-all，救不了长尾；后者才是 1–4 s 长尾的主因，**理论上只有"C2 协作式取消"能把排空压到数十 ms，且没有硬上界**；`-XX:TieredStopAtLevel=1` 仍是当前唯一实测零排空的开关。JBR 25 其实已内置"选择性 deopt"开关 `-XX:+OptimizeCodeFlush`（默认关），JBR 21 则硬编码 deopt-all。

---

## 进展（2026-11-14）

- **P0 v4 已实测封版并提交**（`patches/p0-notify-wait-v4.patch`，6 文件 +152/−28）：ForceSafepoint 64–374 → 0，并发 enhanced redefine 串行化 + 嵌套重入 fail-fast；fastdebug 全套验证通过（含 `-XX:+SafepointALot`、CFLH 嵌套用例）。
- **P1 埋点已实现并实测（含 release 验证）**（`P1-INSTRUMENTATION.md`，补丁 `patches/p1-instrumentation.patch`）：排空等待 >50 ms 时 dump 每个编译线程的当前阶段（`Compile::TracePhase` 名字 + 阶段内耗时 + 总 `compile_ms` + 排空总耗时）；阶段状态挂在 `CompilerThread` 上（Atomic store/load），不跨线程解引用栈上 `Compile*`。
  - **release 实测**（本机 aarch64，`bench.Med` 6.5 KB 长 C2 负载）：排空 444–775 ms，C2 `compile_ms` 中位 554 ms；C2 阶段以 **idealLoop（41/97 采样，max 218 ms）**、`optimizer`（max 531 ms）为主，Chaitin 子阶段单体降到 ~30 ms；`CITime` 佐证 idealLoop 3.489 s / 6.593 s、regalloc 1.396 s；C1 平均 1.6 ms/方法。
  - fastdebug 对照：排空 124–1281 ms，Chaitin/regalloc 被校验放大最明显（regalloc 总段 630 ms）。
  - 结论：P1 取消点应下沉进 **IdealLoop / IGVN / EA 内层循环 + `Register_Allocate` 轮次边界**，不先碰 `buildIFG()`/`fill_buffer()`；C1 阶段边界 `bailout()` 成本极低可顺手加。

- **P1 第一版已实现并通过 release/fastdebug 验证**（`P1-CANCELLATION.md`，补丁 `patches/p1-cancellation.patch`）：C2 在 `Optimize/Code_Gen` 入口、IGVN（每 64 节点采样）、IdealLoop（每 loop 树节点 + 边界）、EA、MacroExpand、`Register_Allocate` 轮次之间检查取消；C1 在 HIR→Optimizer→LIR→CodeGen 边界检查；取消是瞬态失败，不调用 `record_method_not_compilable`，也不走"关优化重试"。
  - **release 实测（bench.Med 长 C2，20 轮 redefine）**：排空 **444–775 ms → p50 6 ms / max 12 ms**，`redefine_ms` **30–49 ms**，20 次取消（phase=idealLoop/iterGVN2），**20/20 轮 bad=0 stale=0**，被取消的 `Med.m0–m3` 在恢复窗口全部重新 level-4 编译。
  - fastdebug 交叉验证：16 次取消（idealLoop/macroExpand/optimizer/regalloc），drain max 171 ms；C1-only 场景 19 次 C1 取消且之后重新 level-1 编译；P0 全套回归（并发/SafepointALot/嵌套/shutdown）通过。

- **真实 Remold（CI 内测版 agent）实测完成**（`REAL-REMOLD-BENCH.md`）：JBR 25 release 补丁组 vs 未打补丁 JBR 25.0.4.1，Remold example 应用 12 轮结构性两阶段热更：**ForceSafepoint 23 → 0**，批次 `total` p50 **177 → 155 ms**、mean **225 → 184 ms**；剩余离群批次由 Remold 侧实例字段回填（`patch` max 342–406 ms）主导，JIT 排空已无贡献 → 瓶颈如预期转移到 Remold 自身。
  - 补丁栈已整理：**生产用 `p0-notify-wait-v4` + `p1-cancellation-standalone`**（已用 `git apply --check` 验证在干净 P0 上直接可应用，无 instrumentation 依赖）。

## 0. TL;DR

| 问题 | 结论 |
|---|---|
| 能把 `redefine` 的 1–4 s 长尾消掉吗？ | 只有改 **编译排空** 才可能；改 deopt 范围不够。 |
| 优化 deopt 本身可行吗？ | **机制可行**（JBR 25 已有 `OptimizeCodeFlush`；JBR 21 回移补丁 5 文件 +164/−7 已就绪），但**只对"无结构变化"的 redefinition sound**。 |
| 对 Remold 现状（结构性热更）有收益吗？ | deopt 侧基本没有（结构变化必须 deopt-all）；排空侧需要 P0+P1 两个 JBR 补丁。当前可立即用的仍是 `-XX:TieredStopAtLevel=1`。 |
| 最值得投入的一项？ | **P1：C2 协作式取消在飞编译**（预期长尾 <100 ms，保留 C2；无硬上界是已知风险）。 |
| 附带发现 | JBR 的 `RedefineClasses` 缺少并发引用计数，多线程/多 agent 并发热更有 JBR-3937 同类崩溃风险（建议顺手修）。 |

---

## 1. 问题重述与成本分解

Remold 文档把长尾定位在 `CompileBroker::stopCompilationBeforeEnhancedRedefinition()` 的排空轮询；本分析把单次 `redefine` 墙钟拆成三块（数字取自文档实测）：

| 组成 | 文档实测 | 能否优化 | 说明 |
|---|---:|---|---|
| `vm_op` 外：编译排空等待 | **680–3854 ms** | ✅（P1 取消在飞编译；P0 只能去噪音） | 等"关闸前已开始的 C2 编译"跑完；每 10 ms 一次 `VM_ForceSafepoint` |
| `vm_op` 内：`doit` | 150–220 ms | ⚠️ 部分（选择性 deopt 可减 deopt 部分；`heap iterate` 省不掉） | DCEVM 堆遍历 + deopt-all |
| `vm_op` 内：`prologue` | 76–102 ms | ❌ 基本不行 | 111 个类过 CFLH/校验的固有成本 |

关键因果链（文档结论 + 我们的源码核对一致）：

```mermaid
flowchart LR
  A["DCEVM 每次 redefine 都 deopt-all"] --> B["客户端大面积重编译（C2 风暴）"]
  B --> C["下一次 redefine 时 C2 编译正在飞"]
  C --> D["stopCompilationBeforeEnhancedRedefinition 排空等待"]
  D --> E["1–4 s 长尾"]
```

**优化 deopt（A→B 这一环）只能让风暴变小，不能消除"排空时正好撞上某个慢编译"这一概率事件；只有直接缩短 D（排空）才能消掉长尾。**

---

## 2. 源码事实：JBR 21 与 JBR 25 的 deopt 路径

| 位置 | JBR 21（Remold 现用） | JBR 25 |
|---|---|---|
| `VM_EnhancedRedefineClasses::flush_dependent_code()` | `if (0 && all_dependencies_are_recorded())` → **硬编码 deopt-all**（FIXME） | `if (!all_dependencies_are_recorded() \|\| !OptimizeCodeFlush)` → 选择性路径可用 |
| 选择性谓词 | 只有标准 `has_evol_metadata()`（仅覆盖"旧 Method"） | 新增 `has_evol_metadata_dcevm()`：扫 Method/Klass 元数据 + 被引用方法的字节码字段扫描 |
| 开关 | 无 | `product(bool, OptimizeCodeFlush, false, ...)`（`runtime/globals.hpp:2033`），**默认关** |
| 依赖记录 | `AlwaysRecordEvolDependencies` 默认 true，启动即 `all_dependencies_are_recorded=true` | 同 |

> 即：JBR 25 把"DCEVM 选择性 deopt"做成了**实验开关**，但上游自己默认关着——这是"尚未证明 sound"的明确信号。

### 2.1 选择性 deopt 的 soundness（关键，不可跳过）

对 DCEVM 增强重定义来说，编译代码里"烘焙"的不只是**元数据指针**，还有**立即数**：字段 offset、vtable index、itable offset、`static final` 折叠值、`Unsafe.objectFieldOffset` 等。HotSpot 的依赖记录机制**根本不记录**这些（标准 redefine 只允许改方法体，所以不需要）。因此选择性谓词只能"扫元数据 + 扫字节码里的字段引用"来近似，本质是 **under-approximate**。

逐场景结论（证据与漏检路径详见 [`jbr21-backport-analysis.md`](jbr21-backport-analysis.md) §2/§3）：

| 变更类型 | 选择性 deopt 是否 sound | 残留漏洞（实际可触发） |
|---|---|---|
| **仅方法体修改** | **基本 sound**（内存安全） | `static final` 常量折叠（行为偏差，不崩） |
| 增/删/重排字段 | ❌ | 从未解析过的字段 CP 项（JBR25 静默漏检）；`Unsafe`/`VarHandle`/DMH 的 offset 常量折叠 |
| 增/删方法（vtable/itable 变化） | ❌ | **megamorphic 虚调用 IC 没有 cached metadata**，而 `VtableStub` 已烘焙旧 vtable index → 调错方法 |
| 改父类/接口 | ❌（风险最高） | `RemoveSuperType` 被拒，但**增删接口是允许的**，checker 无专门判定；itable/默认方法语义变化 |

> 重要：**DCEVM 没有"追加式布局"不变量**——字段会按 name/signature 重排并原地迁移（`CalculateFieldUpdates` / `copy_backwards`）、size 变化触发 safepoint 内 full GC、新版本类重建 vtable/itable、旧方法全部 `set_is_old`（JBR21 `jvmtiEnhancedRedefineClasses.cpp` 1705-1788、884-901、1077-1095、2078）。所以"新字段只是追加"的假设不成立。

**=> 对 Remold 的结构性热更（加 `@Unique` 字段、改 Mixin 结构），选择性 deopt 不安全，必须保留 deopt-all。**

---

## 3. 路线 A：优化 deopt（选择性 deopt / 减少风暴）

### 3.1 机制可回移到 JBR 21（补丁已就绪）

JBR 21 已具备 90% 基础设施（`DeoptimizationScope`、两个 `mark_*`、`AlwaysRecordEvolDependencies`、old/new version 链）。回移补丁：

- 文件：[`patches/jbr21-selective-deopt.patch`](patches/jbr21-selective-deopt.patch)
- 规模：**5 文件，+164/−7**（`globals.hpp`、`compiledMethod.{hpp,cpp}`、`codeCache.cpp`、`jvmtiEnhancedRedefineClasses.cpp`）
- 状态：在 `/home/ubuntu/android-jbr-research/jbr21` 树 `git apply --check` **通过**；未编译、未跑测试
- 唯一 API 适配：JDK21 用 `ConstantPoolCacheEntry`（`get_index_u2_cpcache → decode_cpcache_index → entry_at → f1_as_klass`）替代 JDK25 的 `ResolvedFieldEntry`；并顺带**修掉 JBR25 会静默漏检的"未解析字段 CP 项"**（改为无法判定即保守 deopt）
- 默认仍 **flag=false**（不改现状）。若要在 AndroidJBR/Remold 打开，必须先加 **L1 门控**（见下）

### 3.2 L1 门控：只对"无结构变化"启用选择性 deopt

利用 `VM_EnhancedRedefineClasses::_max_redefinition_flags`（`doit()` 里 749-752 行本来就留着被注释的同类判断）：

```cpp
static const int structural = Klass::ModifyClass | Klass::ModifyClassSize |
                              Klass::ModifyInstances | Klass::ModifyInstanceSize |
                              Klass::RemoveInterface;   // RemoveSuperType 已被拒绝
bool may_selective = (_max_redefinition_flags & structural) == 0;
if (!JvmtiExport::all_dependencies_are_recorded() || !OptimizeCodeFlush || !may_selective) {
  CodeCache::mark_all_nmethods_for_evol_deoptimization(&deopt_scope);
} else {
  CodeCache::mark_dependents_for_evol_deoptimization(&deopt_scope);
}
```

- 语义：`structural == 0` 时增强重定义退化为"标准 JVMTI（仅方法体/常量池）"，选择性谓词覆盖接近标准 `has_evol_metadata` 的安全水平；
- 收益：HotswapAgent 场景里最高频的"改方法体"可吃到选择性 deopt；结构变更仍走 deopt-all（即现状，不倒退）；
- 这是"可证明安全换部分收益"的折中，适合作为 AndroidJBR 的首选上线形态。

### 3.3 实测（预编译桌面 JBR 21.0.11 / JBR 25.0.4.1，aarch64）

合成基准（`bench/`）：agent + 96 个热方法 + 8 个巨型 `Heavy.hugeN()`（制造长 C2 编译）+ 8/16/32 worker；`v1↔v1b` 仅方法体，`v1→v2→v3` 结构性；每轮校验字段迁移 + 陈旧代码。完整数据见 [`MEASUREMENTS.md`](MEASUREMENTS.md)。

| 场景（间隔/worker） | 平均 redefine | 最长 | ForceSafepoint | JIT 编译次数 | 陈旧代码 |
|---|---:|---:|---:|---:|---|
| JBR21 body（60 ms/16） | 78 ms | 189 ms | 17 | 3042 | 0 |
| JBR25 body，`OptimizeCodeFlush` off | 87 ms | 168 ms | 15 | 2879 | 0 |
| JBR25 body，`OptimizeCodeFlush` **on** | 110 ms | 190 ms | 28 | **983** | 0 |
| JBR21 body，`TieredStopAtLevel=1` | 47 ms | 65 ms | **0** | — | 0 |
| JBR21 压力（20 ms/32） | 134 ms | 291 ms | 25 | 2997 | 0 |
| JBR25 on 压力（20 ms/32） | 237 ms | 406 ms | 62 | 1267 | 0 |

**读法**（避免误读）：

1. `OptimizeCodeFlush` 确实把 deopt-all 切成 dependent-only：日志从 `Marked all nmethods` 变为 `Marked dependent nmethods`；**下游重编译风暴缩小约 3×**（2879 → 983）；
2. **但单次 redefine 没有变快**（隔离场景 33–37 → 39–41 ms）：选择性分支要对**整个 code cache 每个 nmethod 做元数据扫描**，成本 O(nmethods)，换来的收益是"下一次"风暴更小——**这是 trade-off，不是免费加速**；
3. 排空（ForceSafepoint）在 JBR21/25 上都在，且随编译压力波动；只有 `TieredStopAtLevel=1` 能把它归零（与 Remold 文档一致）；
4. `stale=0 / bad=0` 只是"本合成负载下没抓到"——测试规模远小于 Remold 的 111 个类，**不能当作 soundness 证据**。

> 另注：JBR 21 的 `jit,compilation` 日志在 info 级不输出（JDK21 是 debug 级），跨版本对比需统一 `=debug`。

---

## 4. 路线 B：消除编译排空等待（真正压长尾）

详见 [`drain-elimination-analysis.md`](drain-elimination-analysis.md)（含源码行号、锁协议分析、验证清单）。要点：

### 4.1 为什么 10 ms + ForceSafepoint 是"必需的停靠点"，且不是根因

`mutex.cpp:129-141` 明确：若一个线程以 `_thread_in_vm` 状态在 nosafepoint-rank 的 monitor 上无限阻塞，会与 safepoint 死锁。而排空线程正是"等编译、且必须在 VM 里等"的角色；编译线程是 native 态、**不参与 safepoint**，只在 native→VM 转换（`ciEnv::cache_jvmti_state`/`register_method` 等 `VM_ENTRY_MARK`）时 poll。于是存在一个环：

```
排空线程（unsafe 阻塞等编译）
   → safepoint 需要它停靠 → 它 10 ms 醒一次让 safepoint 能完成
   → 编译线程 native→VM poll 需要 safepoint 能完成 → 才能跑到下一个 poll 点
   → 编译完成 → active 归零 → 排空结束
```

所以 10 ms 只是"排空线程保持 unsafe 的上界"，调大/调小都不改变本质；ForceSafepoint 是同一个保险的显式触发，**不是主要成本**。

排空墙钟 ≈ **最慢在飞 C2 编译的剩余时间**（轮询粒度最多再加 ~10 ms）。

### 4.2 P0：safepoint-safe 的 notify 等待（必做基座）

> 加固后的可 apply 补丁与逐条 Review 修订见 [`P0-P1-hardened-design.md`](P0-P1-hardened-design.md) 与 [`patches/p0-notify-wait-v2.patch`](patches/p0-notify-wait-v2.patch)（5 文件 +103/−28；已修掉"等待线程必须在 `_thread_in_vm`"这个会炸 fastdebug 的隐藏坑，并把并发计数下沉到 `CompileBroker` + RAII）。

现状：`DcevmCompilation_lock`（nosafepoint rank）上 `wait_without_safepoint_check(10)` + 每次 `VM_ForceSafepoint`。

正确做法（只加 notify 会重新引入死锁）：

- 新增 rank=safepoint 的 `DcevmCompilationWait_lock`；
- `stop`：先把 `_compilation_stopped=true`（在 nosafepoint 锁下），再在 safepoint-rank monitor 上 `while (active > 0) wait()`（可被 pending safepoint 正常完成）；
- 编译线程递减处：`MonitorLocker(..., safepoint check); if (Atomic::sub(...,1)==0) notify_all();`（同一 monitor 下消 lost-wakeup）；
- 保留"保险超时"兜底（防 shutdown 路径永久等待）。

**收益**：ForceSafepoint 64–374 → 0；消除热更期间几十~几百次全局 STW；去掉 10 ms 粒度与一个潜在死锁类别。
**局限（必须写进验收）**：**墙钟长尾不变**——仍要等最慢编译跑完。

### 4.3 P1：C2 协作式取消在飞编译（唯一能压长尾）

> 取消点已按内核 Review 修正：**不要**放在 `Phase::Phase()` 基类构造函数里（子类半初始化），而是放在 `Compile::Optimize()`/`Code_Gen()` 阶段入口 + IterGVN/IdealLoop/EA/Chaitin 既有的 `C->failing()` 退出通道；取消信号直接用 `_compilation_stopped`（零锁零进 VM），并用 `ciEnv::_is_cancelled` 分流掉 `not_compilable` 与 JFR 假失败。设计细节见 [`P0-P1-hardened-design.md`](P0-P1-hardened-design.md) §3。

- 现状：C1/C2 **没有取消机制**（全源码 grep `cancel` 零命中）；但 C2 有可复用的"干扰点"：`Phase::Phase()` 构造里的 `CompileBroker::maybe_block()`（phase.cpp:52-56，shutdown 用）、bailout 框架 `Compile::record_failure()/failing()` 与 `output.install()` 前闸门（compile.cpp:3107-3112）。
- 设计：redefine 时置 `_redefine_epoch`/`_compilation_cancel_requested` → C2 在每个 `Phase` 边界检查并 `C->record_failure("cancelled by enhanced redefinition")` → 编译循环退出、**不安装 nmethod**、**不置 `not_compilable`**；C1 在阶段边界 `bailout()`（可后置）。
- 收益：长尾从 680–3854 ms 压到"下一个 Phase 边界"，典型 **数十 ms**；保留 C2 与 Tier。
- 卡点：**协作式、无抢占**——单阶段超长（巨型方法 GVN/寄存器分配）无硬上界；需审计"Phase 边界已 failing"的容忍度；建议先埋点确认长尾来自 C2 再投入。
- 规模：C2 60–150 行 + C1 20–40 + broker ~30 + 大测试矩阵。**唯一值得投入的中等工程**。

### 4.4 被否掉的方案

| 方案 | 结论 |
|---|---|
| 先 redefine、再丢弃窗口内完成的编译 | 语义上结果本来会被丢弃，但 DCEVM 在 safepoint 内**原地改** metadata（method flags、cpool/bytecode patch、code cache flush、堆/类迁移）+ ciObjectFactory 全局状态，编译线程不参与 safepoint、无 happens-before → 要版本化 metadata 才行（月级重构） |
| 只等"引用受影响类"的编译任务 | 没有任务级 touched-klass 信息；内联/CHA 开放世界，不 sound |
| 只加 notify、保留 ForceSafepoint | 风暴仍在（active>0 时每 10 ms 一次），收益有限 |
| **4b：仅方法体变更走标准 `VM_RedefineClasses`（该路径不停编译）** | **值得做（P2）**：检测出"EMCP 兼容（无结构变化）"的 redefine 就走标准路径，直接绕开排空循环；文档实测该路径 54–63 ms，且不需要 `OptimizeCodeFlush`/选择性 deopt 的 soundness 论证。卡点：要在触发 stop 之前判定 EMCP 兼容性（prologue 计算 `_max_redefinition_flags` 之后才有结论），需调整控制流；结构变更仍走增强路径 |

### 4.5 附带发现：并发 redefine 的引用计数缺口（建议顺手修）

`JvmtiEnv::RedefineClasses`（`jvmtiEnv.cpp:576-589`）没有 Retransform 那样的 `_active_redefinitions` 引用计数：两个 JavaThread 并发 redefine 时，T1 的 release 可能落在 T2 的 redefine 窗口内，**编译在 T2 期间恢复** → JBR-3937 同款崩溃类别。`_compilation_stopped` 也应改成计数/epoch。任何 P0/P1 落地前应一并修掉。

---

## 5. 路线 C：不改 JBR 的即时手段

| 手段 | 效果 | 代价 |
|---|---|---|
| `-XX:TieredStopAtLevel=1` | 排空归零；`redefine` 稳定 ~235–295 ms（Remold 文档）/ 我们实测 47–65 ms | 无 C2，重负载帧率/吞吐下降 |
| JBR 25 + `-XX:+OptimizeCodeFlush` | 重编译风暴 ↓~3×；**排空仍在**；结构性变更有 soundness 洞 | 需要 JBR 25；对 Remold 结构热更**不建议**直接开 |
| 缩短 C2 编译时长（拆分巨型方法、`-XX:CompileCommand` 限制） | 直接缩短排空上界 | 需要改业务/字节码，不通用 |
| 减少热更频率/合并多次修改 | 减少撞上编译的概率 | 体验折中 |
| **仅方法体时关增强开关**（文档已给） | `redefine` 54–63 ms，无堆遍历/无 deopt-all | 失去结构热更能力；Remold 需要按轮次手动切换，体验差 → 对应 4b 的"自动判定" |

---

## 6. 推荐落地路线（面向 Remold）

**阶段 0（现在，0 改动）**
- 结构性热更会话：继续用 `-XX:TieredStopAtLevel=1`（文档已证）或接受长尾；
- 纯方法体热更：JBR 25 + `-XX:+OptimizeCodeFlush` 可作为实验（仅 body-only 场景，且需压测常量折叠行为）。

**阶段 1（小，低风险，先合）**
- 实证：未打补丁的 JBR25 上 4 线程并发 redefine **0.4 s 内 SIGSEGV**（VMThread 在 `ConstantPool::klass_ref_at_noresolve`，见 [`evidence-jbr25-concurrent-redefine-crash.log`](evidence-jbr25-concurrent-redefine-crash.log)）——并发计数缺口是真实可触发的崩溃，不是理论风险。
- **P0 已在本地 fastdebug JBR25 上构建并通过验证**：单线程 20 轮 ForceSafepoint **0**（基线 6/10 轮）；4 线程×100 轮并发 redefine 不再崩溃（未打补丁版本 0.43 s 内 SIGSEGV）；shutdown hook redefine、bench 回归全过。见 [`P0-VERIFICATION.md`](P0-VERIFICATION.md)。
- 补丁：[`patches/p0-notify-wait-v4.patch`](patches/p0-notify-wait-v4.patch)（6 文件 +152/−28 = v2 + 并发 enhanced redefine prologue 串行化 + CFLH 嵌套重入 fail-fast）。验证含 `-XX:+SafepointALot` 并发压测与嵌套重入用例，全部通过。：消除热更期间几十~几百次 ForceSafepoint 的 STW 噪音，并把死锁类别去掉。**不改变长尾**，但它是 P1 的基座，也让日志/观测干净。
- 同 patch 修 4.5 的并发引用计数。

**阶段 2（中，收益最大）**
- P1：C2 `Phase` 边界协作式取消 + C1 bailout；验收目标"P99 长尾 <100 ms"，并保留"超时仍等完成"兜底。
- 前先做埋点实验（不改代码）：在 JBR 25 上给 stop 入口/出口打临时日志，dump 排空 >50 ms 时的 `CompilerThread::current()->task()`（level/method/osr/start time），确认 Remold 的长尾确实来自单个 C2 任务、并量化占比。

**阶段 2.5（高收益，性价比可能高于 P1）**
- **仅方法体变更的"无排空快速路"**：在 `JvmtiEnv::RedefineClasses` 里先做 EMCP 兼容性判定（复用 prologue 里 `_max_redefinition_flags` 的结论、或先跑一次轻量 prologue），若 `structural == 0` 则**直接走标准 `VM_RedefineClasses` 路径**（该路径不调用 `stopCompilationBeforeEnhancedRedefinition`），结构变更才走增强路径（deopt-all + 排空）。
- 收益：body-only 热更从"最长 1–4 s（受排空影响）"直接回到文档实测的 **54–63 ms**，且**不需要**选择性 deopt 的 soundness 论证；Remold/Mixin 场景里"只改方法体"的轮次占比不低。
- 代价：控制流改动（判定要早于 stop）、标准路径与增强路径的元数据/旧方法处理需一致性验证；风险中等。

**阶段 3（可选，结构性热更的"deopt 优化"；若做了 2.5 则收益进一步收窄）**
- JBR 21 回移 + **L1 门控**：让"仅方法体"的 redefine 走选择性 deopt（结构性变更仍 deopt-all）。这样高频微调场景（改方法体）风暴↓3×；结构变更保持安全。

**不建议**：为了消长尾去给结构性热更开 `OptimizeCodeFlush`（soundness 洞：megamorphic vtable index、未解析字段 CP、常量折叠、接口增删）。JBR 25 自己默认关就是证据。

---

## 7. 验证计划（落地前必做）

1. **埋点**：JBR 25 临时 patch，统计 stop 入口/出口、ForceSafepoint 次数、迭代数、`>50 ms` 时的 C2 任务信息；与 Remold 的 680–3854 ms/64–374 次对拍。
2. **P0 验证**：`-Xlog:safepoint` 热更窗口内无密集 ForceSafepoint；redefine 墙钟不变；JTReg `serviceability/jvmti/RedefineClasses`、`vmTestbase/nsk/jvmti/RedefineClasses`；fastdebug（锁 rank/线程状态断言）；并发 redefine 压测。
3. **P1 验证**：长尾 P50/P99；对抗用例（巨型方法/单阶段长编译）；fastdebug + `-XX:+SafepointALot`；确认被取消方法 `is_not_compilable` 未置位、无 nmethod 安装、后续可重编；`-Xcomp`/`-XX:+RepeatCompilation` 组合回归。
4. **选择性 deopt（若做 L1）**：JBR21 aarch64 构建 + JTReg + 定向压测（仅改体 + megamorphic 调用点、字段增删、连续 redefine 后 CP cache 全清、vtable 变化、接口增删、常量折叠），并与 JBR25 同 repro 对拍。

---

## 8. 交付物与复现

| 文件 | 内容 |
|---|---|
| 本文件 | 综合可行性结论与路线 |
| [`jbr21-backport-analysis.md`](jbr21-backport-analysis.md) | JBR21↔25 精确 diff、DCEVM 布局更新证据链（行号）、分场景 soundness 表、L1 门控建议、验证清单 |
| [`patches/jbr21-selective-deopt.patch`](patches/jbr21-selective-deopt.patch) | JBR21 回移补丁（5 文件 +164/−7；`git apply --check` 通过；未编译） |
| [`drain-elimination-analysis.md`](drain-elimination-analysis.md) | 排空消除四方案：锁协议、可复用取消点、拒绝理由、优先级、验证 |
| [`patches/drain-notify-wait.patch`](patches/drain-notify-wait.patch) | P0 设计草图（伪代码级，非可直接 apply 的 diff） |
| [`MEASUREMENTS.md`](MEASUREMENTS.md) | 合成基准全部场景数据 + 解读 + 局限 |
| `bench/` | 可直接复跑的基准：`build.sh`、`run-matrix.sh`、`parse.py`、变体生成、agent |

复现（预编译桌面 JBR，aarch64 主机）：

```bash
cd deopt-study/bench
export JAVAC=<jbr>/bin/javac JAR=<另一个 JDK>/bin/jar   # JBR 发行版不含 jar
./build.sh && ./run-matrix.sh && python3 parse.py
```

---

## 9. 局限与风险

- 合成基准的类数/堆规模远小于 Remold（111 个子类、Minecraft 客户端），**长尾绝对值不可直接外推**；本报告用它做**相对比较**（选择性 deopt 对风暴/成本的影响、C1 对排空的归零）。
- 选择性 deopt 的 soundness 结论来自源码分析 + 小规模实测，**未在 Minecraft 规模上验证**；任何"打开 OptimizeCodeFlush"的决策都应以 Remold 自身的 megamorphic/vtable/字段迁移回归为准。
- P1（C2 取消）只是设计草案：Phase 边界的 failing 容忍度、C1 bailout 时机、fastdebug 断言都需要实做验证；"无硬上界"是方案固有属性。
- 所有 JBR 补丁均未编译/未跑 JTReg；下一步应先做"JBR21 aarch64 桌面构建 + 补丁编译 + 现有测试通过"再谈性能验证。
