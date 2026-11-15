# 真实 Remold（Actions 内测版 agent）实测：P0+P1 vs 原版 JBR（2026-11-15）

## 1. 环境与版本

| 项 | 值 |
|---|---|
| Remold agent | **GitHub Actions 内测版**：run [43676111604](https://github.com/I-hope1/Remold/actions/runs/43676111604)（main、commit *"ci: 上传构建产物并在运行页汇总呈现（remold-dist）"*），artifact `remold-dist` 里的 `remold-agent-0.2.8.jar` |
| Patched JBR | JBR 25.0.5 `1b5d5af9` + Android port tree，**release** 本地构建（`--with-debug-level=release`），叠加 `p0-notify-wait-v4` + `p1-cancellation` |
| Baseline JBR | 预编译 **JBR 25.0.4.1**（`jbr/ext25`，未打任何补丁） |
| 负载 | Remold 官方 `example` 应用（`example.Main` + `PlayerService`），给 `PlayerService` 注入 ~6.5 KB 热方法 `work()` + 4 个后台 worker 持续调用；每轮结构性变更（新增字段 `guildN` + 改 `work()` 常量）后 `javac` 重编译，Remold agent 走两阶段热更（`-XX:+AllowEnhancedClassRedefinition`，`file_shake_ms=200`） |
| 轮数 | 12 轮，全部结构性变更（每轮都是 two-phase A+C） |

命令（可复跑）：`docs/deopt/bench/remold-real-bench.sh <jdk> <tag> <rounds>`，
agent 用 `AGENT=/path/to/remold-agent.jar` 指定。

## 2. 结果（12 个 two-phase 批次）

| 指标 | Baseline（原版 JBR） | Patched（P0 v4 + P1 v1） | 变化 |
|---|---|---|---|
| 批次 `total` min / p50 / max / mean | 151 / **177** / 598 / 225 ms | 129 / **155** / 532 / 184 ms | p50 **−12%**，mean **−18%** |
| `patch`（Remold 实例字段回填）max | 406 ms | 342 ms | −16%（Remold 侧，与 JBR 补丁无关） |
| `ForceSafepoint` safepoint 次数 | **23** | **0** | 排空风暴消失 |
| 排空 drain >50 ms 日志 | — | **0** | 取消在阈值前完成 |
| P1 取消事件 | 0 | **39**（C1 level2=9，level3=11，C2 level4=19） | 取消覆盖 C1/C2 |

## 3. 解读

1. **排空侧目标达成**：真实 Remold 路径上 `ForceSafepoint` 从 23 次降到 0，39 次在飞编译被
   P1 协作取消吸收，**没有任何一次排空超过 50 ms**（而 bench.Med 合成负载上 P1 前是 444–775 ms）。
2. **端到端收益被 Remold 自身开销摊薄**：`total` 的 p50 只降 12%，因为剩余时间主要是
   Remold agent 的类解析/Schema 处理/实例字段回填（`patch` 最大 342–406 ms）和两阶段事务开销，
   不是 JIT 排空。**这正是"排空压下去后瓶颈转移"的实证**：下一步收益点应转向 Remold 侧的
   `patch`（实例字段回填）与两次 redefine 的批次合并，而不是继续动 `fill_buffer()`。
3. **max 仍有 532–598 ms 的离群批次**：两边的 `patch` 也有 342/406 ms 离群，说明离群来自
   Remold 实例回填路径（GC/对象遍历），JBR 侧已无排空长尾贡献。


## 3.1 `-Dremold.agent.perf_log=true` 细分（内测版 agent 支持）

同一负载再跑 12 轮，打开内测版 agent 的 perf 明细（`[HOTSWAP-BATCH] summary:`），
每批次拆成 `readers / gate / alignDiff(fetch,lambda,diff,annDef,initFix) / liveScan / anon / redefine`：

| 批次分项 | Baseline 原版 JBR | Patched (P0 v4 + P1) | 变化 |
|---|---|---|---|
| **redefine（JVMTI 调用，含 deopt-all/flush/GC）p50 / max** | **136 / 569 ms** | **113 / 156 ms** | p50 −17%，**max −73%** |
| 逐批 redefine（ms） | 154,167,**569**,130,127,134,**377**,134,136,130,126,**452** | 125,143,124,156,106,108,136,113,111,104,110,108 | 长尾离群消失，稳定在 104–156 |
| total p50 / max | 289 / 841 ms | 263 / 831 ms | −9%（max 由首轮启动主导） |
| readers p50 / max | 22 / 57 ms | 24 / 59 ms | agent 侧，与 JBR 无关 |
| gate p50 / max | 32 / 99 ms | 34 / 82 ms | 同上 |
| alignDiff p50 / max | 21 / 55 ms | 21 / 62 ms | 同上（initFix 11–44 ms） |
| liveScan / anon | 7 / 7 ms | 7 / 9 ms | 同上 |

**关键**：P1 把 `redefine` 的离群完全抹平（569/452/377 → 全部 ≤156 ms），但**中位 `redefine`
仍有 ~113 ms**——这部分是 `VM_EnhancedRedefineClasses::doit()` 里的 **deopt-all +
`flush_dependent_code()` + 堆遍历/GC**，不是排空。**下一阶段的直接收益点就是
`-XX:+OptimizeCodeFlush`（JBR 25 内置，默认关）+ "仅方法体变化走标准 VM_RedefineClasses 快路径"
（文档实测 54–63 ms），而不是 `fill_buffer()`。**

## 4. 补丁栈独立性（验证记录）

在 `p0-notify-wait-v4` 的干净 worktree 上实测：

* `p1-cancellation-standalone.patch`（本次导出，**不依赖** instrumentation）：
  `git apply --check` **通过**，直接叠在 P0 上即可；
* `p1-cancellation.patch`（原文件，差分基于 instrumentation 之后）：
  **不能**直接叠在 P0 上（`compileBroker.hpp`/`compile.hpp` 冲突），仅适用于
  "P0 → p1-instrumentation → p1-cancellation" 这条诊断栈；
* `p0 → p1-instrumentation` 后再叠 `p1-cancellation-stacked.patch`：**通过**；
  `p0 → p1-cancellation-standalone` 后再叠 instrumentation：**冲突**（顺序不可逆）。

结论：**生产用 `p0-notify-wait-v4` + `p1-cancellation-standalone`**；诊断时先 P0 →
instrumentation → P1-stacked。往 AndroidJBR / JBR 21 回移用 standalone 版本。

## 5. 局限

* 单机 2 vCPU、`example` 体量（非 Minecraft 整合包）；12 轮样本较小。
* 内测版 agent 与 `v0.2.8` release agent 的行为可能有差异；本表两组都用同一个内测版 agent，
  只对比 JBR 本身。
* 合成 `work()` 方法 6.5 KB（低于 release `HugeMethodLimit=8000`），代表"大方法 + 结构性热更"
  的最坏 N 倍，但不是真实 Minecraft 类体量。

## 6. 最新 Remold CI 构建复测（2026-11-15 10:39）

用 Remold `main` 最新 CI 构建（run
[43705168373](https://github.com/I-hope1/Remold/actions/runs/43705168373)，
commit `c0a38d64`，artifact `remold-dist`，包含 *perf(native): reuse warm
jvmtiEnv and batch-clear tags via tagged heap* 等改动）重跑同一套 workload，
对照组仍为未打补丁的 JBR 25.0.4.1：

| 场景 | 指标 | 原版 JBR 25.0.4.1 | P0+P1+P2 JBR 25 | 变化 |
|---|---|---|---|---|
| 结构性两阶段 | redefine p50 / max | **329.5 / 441 ms** | **97 / 116 ms** | p50 **−71%** |
| 结构性两阶段 | 批次 total p50 | 453.5 ms | 228.5 ms | −50% |
| 结构性两阶段 | `ForceSafepoint` 次数 | **147** | **0** | 排空风暴消失 |
| 结构性两阶段 | P1 取消事件 | 0 | 33 | 排空被吸收 |
| 纯方法体 | redefine p50 / max | 67 / 309 ms | **19.5 / 28 ms** | p50 −71%，max −91% |
| 纯方法体 | 批次 total p50 | 158 ms | 77.5 ms | −51% |
| 纯方法体 | 派发 | enhanced | **12/12 standard（P2）** | 跳过堆遍历/GC/停编译 |

结论与之前一致：最新内测版 agent 在未打补丁的 JBR 上把排空长尾放大到
p50 329 ms / max 441 ms（结构性）与 max 309 ms（纯方法体），补丁栈把它压到
97 ms / 19.5 ms，且 `ForceSafepoint` 147→0、无 >50 ms drain。剩余时间主要是
Remold 侧 readers/gate/alignDiff/initFix（p50 合计 ~40–60 ms）与结构性 Stage A
的 6 次 Heap-Inspection Full GC（物理下限），与 P2 v1 封版结论一致。

## 7. 200 万实例压测（2026-11-15 11:10）

同一套 Remold 热更负载，但 `Main` 里常驻 **2,000,000 个 `PlayerService` 实例**
（`-Xms1g -Xmx3g`，结构性字段累积变更，5 轮稳定批次，`ROUND_SLEEP=20`）：

| 指标 | 原版 JBR 25.0.4.1 | P0+P1+P2 JBR 25 |
|---|---|---|
| 批次 total p50 | 11312 ms | 11256 ms |
| `redefine`（JVM 侧）p50 / min / max | 1460 / 765 / 1614 ms | **1292 / 761 / 1600 ms（−12%）** |
| `stageB`（Remold 实例回填）p50 | 6178 ms | 6005 ms |
| `getInstances`（2,000,001 实例）p50 | 2935 ms | 2951 ms |
| `ForceSafepoint` | 17 | **0** |
| P1 取消事件 | 0 | 9 |
| Heap-Inspection Full GC | 3（仅在实例尺寸变化轮） | 3 |

`getInstances` 的 2.9 s 拆项（p50）：iterate ~0.75 s、collect ~0.9 s、fill ~0.83 s、
cleanup ~0.44 s；`stageB` 约 6.0 s，占批次 ~53%。

**结论**：实例数到百万级后，端到端瓶颈完全转移到 **Remold 的实例枚举/回填**
（`getInstances`＋`stageB` 约 9 s / 批次，占 ~80%）；JVM 侧 `redefine` 只剩 ~1.3 s
（2M 对象的 DCEVM 堆遍历 + Heap-Inspection Full GC），P0/P1 仍把 `ForceSafepoint`
从 17 压到 0，P2 在该结构路径按门控回退 enhanced。继续压这个量级的端到端，应优化
Remold 的 `getInstances`（tag/对象枚举）与 `stageB` 回填，而不是 JVM。
