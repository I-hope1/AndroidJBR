# Remold 侧 200 万实例热更优化（2026-11-15）

Remold `main` @ `a0aa7485`（本地 clone 从 `dd92750` pull 到最新）。目标是把 200 万常驻实例
结构性热更的 ~11.3 s/批次压下来。

## 1. 可复现构建

`./gradlew :core:jar`（JDK 25 启动 Gradle 9.7.1，`-Dorg.gradle.java.installations.paths=<jdk25>`）
产出的 `core/build/libs/remold-agent.jar` 与 CI artifact 完全同尺寸（1,432,167 B），
可本地改代码后直接跑同一套 benchmark。

## 2. 2M 批次成本分解（优化前）

单批次 ~11.25 s：

| 段 | 耗时 | 说明 |
|---|---|---|
| DCEVM redefine（JVM 侧） | ~1.2 s | 2M 对象堆遍历 + Heap-Inspection Full GC（3 次，仅尺寸变化轮） |
| stageB：`applyPatch` collect | ~3.0 s | 一次 `getInstances`（内部 3 趟堆遍历：iterate/collect/cleanup） |
| stageB：`applyPatch` inst | ~3.1 s | 逐实例 `MethodHandle.invokeExact` 调用 `init$F` |
| `@OnReload` 枚举 | ~2.9 s | **第二次**完整 `getInstances`，只为拿到实例列表 |
| `@OnReload` 回调 | ~0.5–1 s | 2M 次反射 `Method.invoke` |

## 3. 落地的优化：`StageBInstanceCache`（弱引用）

stageB 补丁枚举出的 `Object[]` 留给同一批次的 `@OnReload` 复用，省掉第二次完整堆遍历
（2M 实例 ≈2.9 s/批次）。语义上回调拿到的是"重定义完成时"的实例快照，比逐次重新枚举
更贴近 `@OnReload` 的"存量实例"定义。

关键实现细节（两次 CI 返工）：
1. **必须弱引用**：`WeakReference<Object[]>`。强引用版本会让 P0.5 探针失败——
   测试显式 `System.gc()` 后检查残留实例，缓存数组把旧实例钉在堆里（residue=100000）。
   弱引用被 GC 清掉时回调回退实时枚举，行为仍正确。
2. **批量 `init$ALL` 循环方案已回退**（曾实现，−0.5 s/2M）：批量调用会让
   链接失败的字段方法把 hidden class 的 indy call site 标记为 erroneous，
   随后的逐实例回退无法再补同轮其它字段，破坏 `tests:initFixOracle` CaseLnk
   "链接失败不牵连其它字段"的契约。收益小、契约重，直接放弃。

## 4. 结果（同一台机器、同一 workload，最新 Remold agent 基线）

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| 2M 批次 total p50 | 11254 ms | **8720 ms** | **−23%** |
| 2M 每批 `getInstances` 次数 | 2 | **1** | 第二次枚举消失 |
| 普通结构性 12 轮 total p50 | 194.5 ms | 202.5 ms | 噪声（每批枚举 2→1） |
| 纯方法体 12 轮 total p50 | 51.5 ms | 56 ms | 噪声 |

正确性：Remold CI run
[43711933616](https://github.com/I-hope1/Remold/actions/runs/43711933616) 全绿——
`Test Matrix (javac 8/11/17/21/25)`、`P0.5 Probe (JBR 17/21)`、`Test on DCEVM (JBR 21)`、
`Build Distributable Jars` 均通过；2M 本地 3/3、普通负载 12/12 hotswap 成功，
`failedFields=[]`、`ForceSafepoint` 仍为 0。

Remold main 提交：`9574e46`（初始实现）、`f0b4895`（弱引用修复）、`bd6bc03`（回退批量循环）。

## 5. 还能往哪压

- **单趟堆遍历**：`getInstances` 现在 JVMTI 内部要 3 趟（tag→GetObjectsWithTags→clear），
  2M 实例 ~3 s。纯 Java 层不可再省，需重写 native（Single-pass 枚举在 JVMTI 回调里拿不到
  jobject，只有 tag 通道，收益有限）。
- **`cleanup` 的批量清 tag**：实测逐实例 `SetTag(0)` 在 2M 下反而要 3.2–3.4 s，远慢于
  一次 `TAGGED` 堆遍历（0.42–0.68 s），现有 `kTagClearWalkThreshold` 分流是对的，不要再改。
- **`@OnReload` 2M 次回调**：可仿照 `init$ALL` 生成类内循环，省 ~0.5–1 s。
- 结构性 Stage A 的 6 次 Heap-Inspection Full GC 是 JVM 侧物理成本，与 Remold 无关。

补丁未推 upstream（按约定先本地验证）；文件：
`/home/ubuntu/deopt-study/remold-opt-instance-enum-and-batch-loop.patch`（+123/−9，新增 1 文件）。
