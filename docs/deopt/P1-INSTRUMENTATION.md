# P1 埋点：在飞 C2 编译的"当前阶段"（2026-11-14）

> 目的：在不猜测的前提下决定 P1 取消点要挖多深——长尾到底卡在**阶段之间**，还是卡在
> 单次 IGVN / IdealLoop / ConnectionGraph / Chaitin(regalloc) 内循环里。

## 1. 实现

补丁：`patches/p1-instrumentation.patch`（叠加在 `p0-notify-wait-v4.patch` 之上）。

1. `Compile` 增加 `_current_phase_name` / `_current_phase_start_ns`（volatile，跨线程读为良性竞争），
   在 `Compile::TracePhase` 构造/析构里设置和恢复，因此记录的是**最内层** TracePhase：
   `parse / optimizer / iterGVN / idealLoop / escapeAnalysis / connectionGraph / macroExpand /
   matcher / scheduler / regalloc(Chaitin 各子阶段) / output ...`。
2. `CompilerThread` 增加 `_current_compile`（TracePhase 嵌套时保存/恢复），使排空线程能读取
   "该编译线程正在跑哪个 `Compile`、处于哪个阶段、阶段已持续多久"。
3. `CompileBroker::drainCompilationsForEnhancedRedefinition()` 在等待超过
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

## 2. 快速验证（fastdebug，合成负载）

`bench.Med.m0..m3`（~13 KB 的 600 语句分支方法，`-XX:HugeMethodLimit=65535` 放开 C2，
`-XX:CompileThreshold=100` 让它们反复重编译）+ 8 worker + 每 500 ms 一次 body-only redefine：

```
java -XX:+AllowEnhancedClassRedefinition -XX:HugeMethodLimit=65535 \
     -XX:CompileThreshold=100 -XX:Tier4InvocationThreshold=100 \
     -XX:DcevmDrainDumpThreshold=1 -Xlog:redefine+class=info:file=p1.log \
     -javaagent:bench-agent.jar -cp out/v1:out/bench bench.Main out/v1,out/v1b 10 500 8 100,200
```

实测（fastdebug aarch64，1 个 C1 + 1 个 C2 线程）：

* 排空 10 次：**min 124 ms / p50 998 ms / max 1281 ms**（本机 fastdebug 合成负载）。
* 168 条 in-flight 采样，79 个方法/阶段组合；其中 C2 命名阶段 81 条。
* 阶段分布（采样数 / 单次阶段内最长 ms）：

  | 阶段 | n | max phase_ms |
  |---|---|---|
  | (between-phases) | 87 | –（C1 或 C2 两个 TracePhase 之间） |
  | regAllocSplit | 14 | 111 |
  | computeLive | 13 | 23 |
  | scheduler | 7 | 89 |
  | buildIFG | 7 | 24 |
  | fill buffer | 6 | 134 |
  | optimizer | 3 | **285** |
  | idealLoop | 3 | 51 |
  | matcher | 3 | 71 |
  | regalloc（Chaitin 总段） | 1 | **630** |
  | idealLoopVerify | 2 | 33 |
  | 其余 chaitin*/output/bldOopMaps 等 | 各 1-3 | 4-63 |

* 最坏单点：`bench.Med.m1` level 4 卡在 **`regalloc` 630 ms**；`optimizer` 285 ms。

## 3. 解读与结论

1. **长尾主要不在"阶段之间"**：C2 线程的命名阶段样本里，**Chaitin/寄存器分配管线**
   （`regalloc` 总段、`regAllocSplit`、`computeLive`、`buildIFG`、`scheduler`）占绝对多数，
   且单次可达 630 ms。`optimizer`（含 IGVN/IdealLoop 等）也是重要来源。
2. 这直接回答"取消点要不要下沉进内循环"：**要**。只在 `Compile::Optimize()` / `Code_Gen()`
   边界检查取消标志，最坏情况仍要等完一个 630 ms 的 Chaitin；必须至少在
   `PhaseChaitin` 的 split/coalesce/select 循环、`PhaseIterGVN`、`PhaseIdealLoop`、
   `PhaseMacroExpand`/EA 的内层循环里放 `C->check_cancellation()`。
3. **fastdebug 注意**：绝对毫秒被 IR 校验/断言放大数倍，不能当 release 数据用；
   但"阶段占比/单次阶段内耗时"可定位瓶颈，release 上应同比例缩短（预计 regalloc 100 ms 量级），
   仍需在真实 Remold 负载上复测确认。
4. `(between-phases)` 占 87/168：主要来自 C1 线程（本来就没有阶段概念，phase_ms=-1）以及
   C2 在 `TracePhase` 之外的准备/收尾代码。若要细分，下一步可把 `Compile::Optimize()` 里
   未被 TracePhase 包住的段（如 incremental inlining 的调度、cleanup）也打点。

## 4. 下一步（P1 实施顺序建议）

1. 在真实 Remold 负载上跑 `-XX:DcevmDrainDumpThreshold=50`，确认 release 下长尾还是
   regalloc/optimizer 为主。
2. 取消标志复用 `_compilation_stopped`（已存在），在 `ciEnv` 加 `_is_cancelled` +
   `record_cancellation()`；取消点先用"阶段边界 + 现有 `C->failing()` 轮询点"，
   再补 Chaitin 内循环。
3. C1 取消走 `Compilation::compile_method` bailout 路径，注意**不要**调用
   `record_method_not_compilable`（否则方法被永久禁止编译）。
4. 取消后 `Compile` 以 `failure_reason="cancelled (enhanced redefinition)"` 结束，
   由下一次 redefine 后的 deopt/重编译自然修复；需要验证不会漏掉必须重新编译的方法。
