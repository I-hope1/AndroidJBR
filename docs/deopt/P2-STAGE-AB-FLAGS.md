# P2：为什么 24/24 个 enhanced redefine 都触发 Full GC —— Stage A/C 逐 op 取证

用临时诊断（`patches/local-diagnostic-op-flags.patch`，未提交；已还原源码）在
`VM_EnhancedRedefineClasses::doit()` 打印：
`opN class flags old_size new_size old_isize new_isize old_fields new_fields old_methods new_methods`、
`instances: needs_instance_update=`、`fullgc: flags=`，以及 4 个分项计时。
`-Xlog:redefine+class*=info,gc=info` 同步开 GC 日志。两组负载各 12 轮：

* **t70（上一轮口径，字段"每轮换名"）**：每轮源码只保留 `guildN`，上一轮字段消失；
* **t71（真实口径，字段只增不减）**：`guild0..guildN` 累积。

## 1. 逐 op 结果

| 观测 | t70 换名字段 | t71 累积字段 |
|---|---|---|
| Stage A（奇数次 op）`max_flags` | 12（**每轮**） | 12 或 4（随实例尺寸是否变化） |
| Stage C（偶数次 op）`max_flags` | 12（**每轮**） | **0（每轮）** |
| Stage A `needs_instance_update=1` | 12/12 | 6/12（实例 size_helper 实际变大时才 1） |
| Stage C `needs_instance_update=1` | **12/12** | **0/12** |
| 批次 redefine p50 | 119.5 ms | **94 ms** |
| 批次 total p50 | 251.5 ms | **215 ms** |
| Stage A doit（分项合计）p50 | 61 ms | 57.5 ms |
| Stage C doit（分项合计）p50 | 50 ms | **38 ms** |

flag 解码（`Klass` 枚举）：`4 = ModifyInstances`，`8 = ModifyInstanceSize`，`12 = 两者都有`；`0 = NoRedefinition`（DCEVM **不比较方法体**，所以纯方法体改动在 flag 上不可见）。

## 2. 结论：24/24 GC 是"负载 + 两阶段并集语义"造成的，不是 DCEVM 保守

Remold 的 Stage A 骨架用 **旧字段 ∪ 新字段**（`StageASkeleton.build()` 里 `for (FieldNode f : old) if (!newFieldKeys.contains(...)) newCn.fields.add(f)`）。
t70 每轮把上一轮字段从源码里删掉，于是：

* `op1`（Stage A）：7 字段 → 8 字段（旧字段并回来 + 新字段），`size_helper 4→5`，`flags=12`，**Full GC**；
* `op2`（Stage C）：8 字段 → 7 字段（提交目标字节码，旧字段删掉），`size_helper 5→4`，`flags=12`，**Full GC**。

即**每轮两次实例布局变化**（先并集、后严格新结构），所以 24/24 都有 `needs_instance_update`。
真实"字段只增不减"的 t71 里 Stage C `flags=0`、`needs_instance_update=0`、**GC 0/12**——DCEVM 并没有多触发。

`needs_instance_update` 的触发条件（`ChangePointersObjectClosure::do_object`）：
```cpp
if (obj->size() - obj->size_given_klass(new_klass) != 0) {
  _needs_instance_update = true;
  _dcevm_shared_gc->update_fields_in_old(obj, new_klass->update_information());
}
```
→ 只有**实例分配尺寸真的变化**才置位；t71 里 `op3` 字段 8→9 但 `size_helper 5→5`（padding 内），
`flags=4`（ModifyInstances）却**不**触发 GC，验证了这一点。
那次 `Pause Full (Heap Inspection Initiated GC)` 在 `doit()` 里紧跟 heap walk 之后，
用于把"尺寸已变、暂存在 old space"的实例按新布局定稿（`update_fields_in_old` + `collect_as_vm_thread(GCCause::_heap_inspection)`），是布局变化的固有步骤，不是冗余 GC。

## 3. 剩余可挖点（P2 候选）

真实口径下每批次：
* Stage A：实例尺寸真变化时 ~57 ms（GC 17–20 + heap 17 + cpool 9 + 其他）；尺寸不变时 ~30 ms，无 GC；
* Stage C：flags=0（纯方法体、同 shape），仍要 ~38 ms —— 因为它依然克隆新 `InstanceKlass`、
  做全堆 ChangePointers（heap iterate 15 ms）+ 全 cpool `classes_do`（9 ms），还再走一次 P0 停编译窗口。

**Stage C 是标准 `VM_RedefineClasses` 快路径的理想候选**：JVM 在 alkyl prologue 已能算出
`_max_redefinition_flags == 0`，此时可以改派标准路径：不克隆新 `InstanceKlass`、不做全堆 walk、
不做全 cpool 遍历、用依赖信息只 deopt 受影响方法（也顺带省掉第二次 stop-compile）。
预计 Stage C 从 ~38 ms 降到 ~10–15 ms 量级，每批次省 ~20–25 ms（≈ 批次 total 的 10%），
且热更后重编译量更小。落地约束照旧：**不重复派发 `ClassFileLoadHook`**、**与增强路径共用
`RedefineClasses_lock` 串行槽位**。

真正的物理下限仍在 Stage A：**实例尺寸变化 → 全堆 ChangePointers + Heap Inspection Full GC**，
20–28 MB 小堆上 17–20 ms，大堆（2–8 GB）会按堆规模放大。这部分除非改 DCEVM 的"实例尺寸更新"
设计（例如按需只扫受影响类实例、或改用不依赖 Full GC 的 size 修正），否则压不下去；
不建议为了这 ~20 ms 去动 `fill_buffer()` 或 code flush。
