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
