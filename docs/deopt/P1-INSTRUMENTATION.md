# P1 埋点：在飞 C2 编译的"当前阶段"（2026-11-14）

> 目的：在不猜测的前提下决定 P1 取消点要挖多深——长尾到底卡在**阶段之间**，还是卡在
> 单次 IGVN / IdealLoop / ConnectionGraph / Chaitin(regalloc) 内循环里。

## 1. 实现

补丁：`patches/p1-instrumentation.patch`（叠加在 `p0-notify-wait-v4.patch` 之上）。

1. **阶段状态挂在 `CompilerThread` 上**（`volatile int _current_phase_id` +
   `volatile jlong _current_phase_start_ns`，用 `Atomic::store/load` 读写），
   由 `Compile::TracePhase` 构造/析构设置和恢复，记录**最内层** TracePhase：
   `parse / optimizer / iterGVN / idealLoop / escapeAnalysis / connectionGraph / macroExpand /
   matcher / scheduler / regalloc(Chaitin 各子阶段) / output ...`。
   **不跨线程解引用 `Compile*`**：`Compile` 是 `C2Compiler::compile_method` 栈上局部对象，
   排空线程若通过指针读它有悬垂竞态（排空线程刚拿到指针、编译线程退出栈帧 → UAF）。
   阶段状态直接存在线程对象上，读到的永远是该线程最后发布的值，最坏是"旧值/新值"之一。
2. `CompileBroker::drainCompilationsForEnhancedRedefinition()` 在等待超过
   `-XX:DcevmDrainDumpThreshold`（默认 50 ms）时，最多每 100 ms dump 一次：
   ```
   [info][redefine,class] in-flight compilation: thread='C2 CompilerThread0'
       method='bench.Med.m1(I)I' level=4 osr_bci=-1 phase='regAllocSplit' phase_ms=111
       (phase_ms=-1 <=> C1 or between C2 phases)
   ```
   排空结束再打一行 `compilation drain finished after N ms`。
4. 无名字的 trace id（`_t_vector`、`_t_renumberLive`）保持外层阶段名，不输出空 phase。

一行日志同时给出：线程、方法、编译层级（C1=1/2/3，C2=4）、OSR、阶段名、阶段内已耗时、排空总耗时。
`-Xlog:redefine+class=info` 打开。

## 2. 验证结果

### 2.1 release（`--with-debug-level=release`，本机 aarch64，1x C1 + 1x C2 线程）

负载：`bench.Med.m0..m3`（300 分支语句，~6.5 KB，刚好低于 release 的 `HugeMethodLimit=8000`）
+ 8 worker + 每 300 ms 一次 body-only redefine；`-XX:CompileThreshold=100`、`-XX:Tier4InvocationThreshold=100`。

* 排空 20 次：**min 444 / p50 523 / max 775 ms**（release！不是 fastdebug）
* 115 条 in-flight 采样：C2 97 条（全部带命名阶段），C1 18 条（全部 `phase_ms=-1`、`compile_ms=-1`）
* C2 `compile_ms`：**median 554 ms，max 963 ms**
* C2 阶段分布（采样数 / 单次阶段内最长 ms）：

  | 阶段 | n | max phase_ms |
  |---|---|---|
  | **idealLoop** | **41** | **218** |
  | regAllocSplit | 9 | 30 |
  | computeLive | 8 | 14 |
  | scheduler | 7 | 18 |
  | buildIFG | 5 | 14 |
  | matcher | 5 | 27 |
  | chaitinCoalesce1 | 4 | 22 |
  | output | 3 | 16 |
  | optimizer（总段） | 2 | **531** |
  | 其余（chaitin*/graphReshape/fill buffer/…） | 各 1-3 | 0-6 |

* `-XX:+CITime` 佐证（同负载 10 轮）：C2 125 个方法 / 6.593 s，其中 **IdealLoop 3.489 s（52.9%）**、
  Optimize 总段 4.108 s、**Regalloc 1.396 s（21%）**、Parse 0.253 s；
  C1 826 个方法 / 1.305 s（**平均 1.6 ms/方法**），阶段为 Build HIR 0.554 / Emit LIR 0.584 /
  Code Emission 0.106。

### 2.2 fastdebug 对照（同一负载，同一埋点）

* 排空 10 次：min 124 / p50 998 / max 1281 ms
* 阶段分布：**(between-phases) 87**、regAllocSplit 14、computeLive 13、scheduler 7、buildIFG 7、
  **regalloc 总段 630 ms**、**optimizer 285 ms**
* 与 release 的关键差异：fastdebug 下 Chaitin/regalloc 的各子阶段被校验放大得最厉害；
  release 下 **idealLoop 才是第一大项**，regalloc 单体降到 ~30 ms 量级。

### 2.3 C1 采样说明

release 下 C1 的 18 条采样全部 `compile_ms=-1`、`phase_ms=-1`。结合 `-XX:+CITime`（C1 平均 1.6 ms/方法）
可以确认：这些不是"正在编译的 C1"，而是**被 DCEVM gate 停住、已取到 task 但还没进编译器**的 C1 线程
（`invoke_compiler_on_method()` 还没开始，所以没有 `time_started`）。也就是说本负载下 C1 不是长尾来源；
但它被 gate 挡住的时间确实存在，属于 redefine 窗口的一部分。

## 3. 解读与结论

1. **长尾确实不在"阶段之间"**：release 的 C2 采样 97/97 都能落到命名阶段上；
   **第一大项是 `idealLoop`（41/97 采样，单次 218 ms）**，`optimizer` 总段单次 531 ms；
   排空本身 444–775 ms，`compile_ms` 中位数 554 ms —— 这就是"只在外层 `Optimize()` /
   `Code_Gen()` 边界检查不够"的 release 实证。
2. **取消点优先级（按 release 数据收窄）**：
   1) `PhaseIdealLoop::build_and_optimize()` 及其内层循环（现有 `C->failing()` 轮询点附近）；
   2) `PhaseIterGVN::optimize()` / `PhaseMacroExpand` / `ConnectionGraph::compute_escape()` 的现有检查点；
   3) `PhaseChaitin::Register_Allocate()` 每轮 Split/Select 之间（release 单体 ~30 ms，但多轮累积）；
   4) **不要**先插 `buildIFG()` / `fill_buffer()` 内部（release 单体 6–14 ms，收益小、半途 bailout 风险高）。
3. **C1**：本负载下 C1 平均 1.6 ms/方法，不是长尾来源；但 C1 取消点（HIR→LIR→CodeGen 边界 +
   `bailout()`）只有 ~20 行、成本极低，建议作为第一版顺手加上，防止别的负载出现大方法 C1 编译。
4. **fastdebug 注意**：绝对毫秒被 IR 校验放大数倍（Chaitin 子阶段尤其明显），只能看"阶段形状"；
   release 的 `idealLoop`/`optimizer`/`regalloc` 比例才是决策依据。
5. `(between-phases)` 在 release 的 C2 采样里是 0/97；fastdebug 里的 87/168 主要来自 C1 线程与
   C2 的 TracePhase 间隙，说明阶段埋点对 C2 归属已经足够细。

## 4. 下一步（P1 实施顺序建议）

1. 真实 Remold 负载上跑 `-XX:DcevmDrainDumpThreshold=50`（release 构建），确认
   `idealLoop`/`optimizer` 仍是第一优先级；本机没有 Remold 运行环境，本轮用 `bench.Med`
   合成负载代表"大方法 + 结构性热更"的最坏情况。
2. 取消标志复用 `_compilation_stopped`（已存在），封装 `CompileBroker::redefinition_cancel_requested()`
   内部用 `Atomic::load`；在 `ciEnv` 加 `_is_cancelled` + `record_cancellation()`。
3. 第一版取消点（按 release 数据）：`PhaseIdealLoop::build_and_optimize()` 内层循环、
   `PhaseIterGVN::optimize()`、`PhaseMacroExpand`、`ConnectionGraph::compute_escape()` 的现有
   `C->failing()` 检查点；`PhaseChaitin::Register_Allocate()` 每轮 Split/Select 之间；
   C1 在 HIR→Optimizer→LIR→CodeGen 边界加 `bailout()`。暂不碰 `fill_buffer()`/`buildIFG()`。
4. 区分"被取消"与"编译失败"：取消路径绝不调用 `record_method_not_compilable()`，也不触发
   "关优化重试"；`failure_reason` 标记为 cancelled，由下一次 redefine 后的 deopt/重编译修复。
5. 验证：P0 全套 + 取消压测（并发 redefine × 4、`-XX:+SafepointALot`）+ 取消后正确性
   （bench.Main `bad=0 stale=0`）+ 无方法被永久禁止编译（多次 redefine 后仍能重编译）。
