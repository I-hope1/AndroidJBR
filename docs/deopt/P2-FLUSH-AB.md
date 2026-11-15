# P0+P1 下 redefine 内部拆解 & OptimizeCodeFlush A/B（2026-11-15）

同一份 `bench/remold-real-bench.sh`、同一个 Remold CI 内测版 agent、同一负载
（12 轮结构性两阶段热更，每轮新增字段 + 改 6.5 KB 热方法体），两组都带
`-Xlog:redefine+class*=info,gc=info` 与 `-Dremold.agent.perf_log=true`：

* **A 组**：默认 P0 v4 + P1 v1；
* **B 组**：A 组 + `-XX:+OptimizeCodeFlush`。

JVM 侧临时加了 4 个局部计时器（`jvmtiEnhancedRedefineClasses.cpp`：redefine_single /
flush_dependent_code / cpool / instances），补丁存
`patches/local-diagnostic-redefine-timers.patch`，**未提交**，跑完已还原源码。

## 1. 每批次 agent 视角

| 指标 | A 默认 | B +OptimizeCodeFlush |
|---|---|---|
| `redefine`（agent 计时）p50 / max | **118.5 / 137 ms** | **124.5 / 149 ms** |
| 批次 `total` p50 | 260 ms | 205.5 ms |
| marked nmethods 模式 | 24 次 **all** | 24 次 **dependent** |

→ OptimizeCodeFlush 按设计生效（全量 deopt 变依赖 deopt），但 **redefine 本身没有变快**
（p50 反而略升，属噪声；两者都在 118–125 ms）。

## 2. redefine 内部（24 个 VM op = 12 轮 × 2 阶段）

| 分项 | A 默认 p50 (max) | B OCF p50 (max) |
|---|---|---|
| `vm_op all` | 44.5 (52) | 49 (56) |
| `prologue`（含 P0 排空等待） | 1 (5) | 0 (1) |
| `doit` 总计 | 43 (52) | 49 (56) |
| ├ `flush_dependent_code`（mark+deopt） | **0 (2)** | **2 (3)** |
| ├ `cpool`（ClearCpoolCacheAndUnpatch 全类遍历） | 9 (10) | 9 (10) |
| ├ `instances`（堆遍历 + ChangePointers） | 12 (20) | 13 (21) |
| ├ `full GC`（Heap Inspection Initiated GC） | **18 (22)** | **21 (22)** |
| └ 其余（dictionary/vmClasses/静态字段拷贝/check_class…） | ≈4–5 | ≈4–5 |

GC 日志确认每次 enhanced redefine 都触发一次
`Pause Full (Heap Inspection Initiated GC)`（堆仅 20–28 MB，单次 15–22 ms）：
来源是 `doit()` 里 `if (needs_instance_update)` 为更新实例布局调用的
`Universe::heap()->collect_as_vm_thread(GCCause::_heap_inspection)`。

## 3. worker 吞吐（4 个后台 worker 调 `work()`，每 2 s 采样）

| 指标 | A 默认 | B OCF | 变化 |
|---|---|---|---|
| throughput mean | 2.166 M calls/s | 2.271 M calls/s | **+5%** |
| throughput p50 | 2.084 M | 2.297 M | **+10%** |
| throughput min（热更窗口内最差 2 s） | 1.515 M | 1.716 M | **+13%** |

→ OptimizeCodeFlush 的收益在**代码缓存保留**（更少全量重编译），不在 redefine 延时；
最差窗口 worker 吞吐 +13%，与"少 deopt 一堆无关 nmethod"一致。

## 4. 结论：这 113 ms 该往哪挖

* **`flush_dependent_code` 不是瓶颈**：0–2 ms，`OptimizeCodeFlush` 只是换了 deopt 集合。
* **每个 VM op 约 43–49 ms，其中 full GC 18–21 ms（≈40%）、堆遍历/实例更新 12–13 ms、
  cpool 9 ms**；两阶段批次 = 2 个 VM op + ~25–30 ms JVMTI/类准备 → 118–125 ms。
* 这些是 **DCEVM 结构性重定义（字段布局变化）的物理成本**：实例尺寸变化必须做全堆
  ChangePointers + 一次 Heap Inspection Full GC。继续在 `fill_buffer()`/code flush 上挖
  没有空间；JVM 侧 P2 的可行方向只剩：
  1. **shape 未变的第二阶段是否还能省掉一次 Full GC**（当前 24 个 op 全部触发 GC，
     Stage C 与 Stage A 同 shape 时理论上 `needs_instance_update` 应为 false，值得核查）；
  2. 把"仅方法体变化"从结构性路径分流出去（标准 `VM_RedefineClasses` 快路径，历史实测
     54–63 ms；JBR 25 的 `OptimizeCodeFlush` 只解决 deopt 侧）。
* Remold 侧批次 `total` 里 readers/gate/alignDiff/initFix 等仍占 ~80–100 ms，且 OCF 组
  的非 redefine 分项更快（噪声内），端到端收益仍会被 agent 本身摊薄。
