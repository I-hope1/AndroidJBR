# P1 第一版：C1/C2 协作式取消（2026-11-15）

> 目标：把 enhanced redefine 的编译排空从 **444–775 ms（release 实测）** 压到几十毫秒以内，
> 取消点按 release 数据只放在 `IdealLoop` / `IGVN` / `EA` / `MacroExpand` /
> `Register_Allocate` 轮次边界 + C1 阶段边界；不动 `fill_buffer()` / `buildIFG()`。

补丁：`patches/p1-cancellation.patch`（叠加在 `p1-instrumentation.patch` 之上；
生产用可只取 P0 + 本补丁，埋点是可选的诊断层）。

## 1. 取消信号与语义

* `CompileBroker::redefinition_cancel_requested()`：`Atomic::load(&_compilation_stopped)`，
  由 `AllowEnhancedClassRedefinition` 短路。`_compilation_stopped` 从 `bool` 改为 `int`，
  stop/release 用 `Atomic::store`，编译器线程的 gate 轮询也用 `Atomic::load`
  —— 紧循环里不会被编译器 hoist 出循环。
* `Compile::check_cancellation()`：第一次观察到取消时 `record_failure("cancelled by
  enhanced class redefinition")`，之后 `failing()` 为真，各 Phase 现有的
  `if (C->failing()) return;` 路径自动收尾。
* **不写 `record_method_not_compilable()`**：这是瞬态失败，redefine 窗口结束后策略会重新排队。
* C2 的 `C2Compiler::compile_method()` 遇到这个 failure reason 直接 `env->record_failure()`
  后 `break`：不再走 "关掉某优化重试" 的阶梯。
* C1 的 `Compilation::cancel_compilation()`：置 `_is_cancelled` 并 `_env->record_failure()`，
  构造完成后**跳过** `record_method_not_compilable()`（原 C1 bailout 会永久禁编译）。

## 2. 取消点（release 数据收窄后）

| 位置 | 粒度 | 备注 |
|---|---|---|
| `Compile::Optimize()` / `Code_Gen()` 入口 | 每阶段 | 快速短路 |
| `PhaseIterGVN::optimize()` worklist 循环 | 每 64 个节点 | `(++cancel_poll & 0x3F) == 0` |
| `PhaseIdealLoop::build_and_optimize()` 两处边界 | 每轮 | 紧跟现有 `C->failing()` 检查 |
| `IdealLoopTree::iteration_split()` | 每个 loop 树节点 | 递归 driver |
| `ConnectionGraph::compute_escape()` / `split_unique_types()` | 每 64 个节点/分配 | 现有 failing 检查点旁 |
| `PhaseMacroExpand` 展开循环 | 每轮 + 每 8 个 macro node | |
| `PhaseChaitin::Register_Allocate()` spill/recycle 轮次 | 每轮 Split/Select | release 单体 ~30 ms |
| C1：HIR → Optimizer → LIR → CodeGen 边界 + install 前 | 4 个阶段边界 | 瞬态失败，不永久禁编译 |

**没有**插 `PhaseOutput::fill_buffer()` / `build_ifg()`：release 单体只有 6–14 ms，
半途 bailout 需要审计 CodeBuffer/重定位状态，收益不抵风险。

## 3. 实测（release，本机 aarch64，bench.Med 长 C2 负载）

同一负载（20 轮 redefine、300 ms 间隔、8 worker、`CompileThreshold=100`）：

| 指标 | P1 前（仅 P0） | P1 后 |
|---|---|---|
| 排空 drain | **444 / 523 / 775 ms（min/p50/max）** | **4 / 6 / 12 ms** |
| `redefine_ms` | 数百 ms 量级 | 30–49 ms（p50 39） |
| 取消事件 | 0 | **20**（C2，phase=idealLoop / iterGVN2） |
| 正确性 | bad=0 stale=0 | **20/20 轮 bad=0 stale=0** |
| 恢复 | — | 最后一个取消后 **Med.m0–m3 全部重新 level-4 编译**（7.8–10.2 s，恢复窗口） |

fastdebug 交叉验证：16 次取消（idealLoop / macroExpand / optimizer / regalloc），
drain max 171 ms（fastdebug 放大），恢复窗口内仍重新编译；
C1-only 场景（`-XX:TieredStopAtLevel=1`）：**19 次 C1 取消**，之后 Med.m0–m3 重新
level-1 编译，无 `not_compilable` 永久退化。
P0 回归（并发 redefine、`-XX:+SafepointALot`、CFLH 嵌套、shutdown hook）**全部通过**。

## 4. 已知边界

* 取消延迟上界 = "当前不可中断的单块工作"：`fill_buffer()`/`build_ifg()` 未打点，
  单个超大方法在这些段内仍可能要等数毫秒到十几毫秒；release 实测已可接受。
* `Reoptimize`/`RepeatCompilation` 等特殊 directive 下，取消会让该次重复编译提前结束，
  由后续策略重新排队；未在此负载下逐项验证。
* `-XX:TieredStopAtLevel=1` 下 C1 取消会命中 JDK 自身方法（正常），日志里能看到
  `(C1)` 前缀；这些方法同样会重新编译（已用 jit 日志确认）。
* 真实 Remold 负载仍需复测：本机无 Remold/Minecraft 运行环境，用 `bench.Med` 代表
  "大方法 + 结构性热更" 的最坏情况。

## 5. 验证脚本

* `bench/p1-verify.sh <java> release|fastdebug`：
  1) 取消确实发生；2) drain 上界；3) `bad=0 stale=0`；
  4) 被取消的方法在恢复窗口内重新到达 level 4（C1 场景为 level 1）。
* `bench/p0-verify.sh` 继续覆盖并发/嵌套/safepoint/shutdown 回归。
