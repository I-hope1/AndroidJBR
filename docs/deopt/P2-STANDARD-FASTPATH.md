# P2 v1：纯方法体热更走标准 `VM_RedefineClasses`（2026-11-15）

针对"Stage C 同 shape 仍要 ~38 ms"的结论：当一次 redefine 请求在结构上没有变化时，
改派标准路径可以直接省掉 DCEVM 的新 `InstanceKlass` 克隆、全堆 ChangePointers、
全 cpool 遍历、Heap-Inspection Full GC，以及整个 stop-compilation 窗口。

补丁：`patches/p2-standard-fastpath.patch`（`2dc53e096..1dd8e6f45`，4 文件 +204/−11；
与 P0/P1 改动文件不重叠，可直接叠在 `p0-notify-wait-v4` 或 P0+P1 上，已在干净
P0 worktree 用 `git apply --check` 验证）。

## 1. 实现

`src/hotspot/share/prims/jvmtiEnv.cpp`（`JvmtiEnv::RedefineClasses`）：

1. 若 `AllowEnhancedClassRedefinition` 且所有目标类 `old_version()/new_version() == nullptr`
   （无 DCEVM 版本链），先把请求派发给 `VM_RedefineClasses`：
   * 标准路径本身是**最严格的准入裁判**（`compare_and_normalize_class_versions`
     检查方法增删/签名/修饰符、字段布局、接口、Record、PermittedSubclasses、
     Nestmates 等），接受即 100% 可走标准 `doit()`；
   * 接受 → 直接标准重定义：不进入 `stopCompilationBeforeEnhancedRedefinition()`，
     无堆遍历/全 GC。
2. 若标准路径返回 `JVMTI_ERROR_UNSUPPORTED_REDEFINITION_*`（结构性变化，DCEVM 专属）
   → 回退 `VM_EnhancedRedefineClasses`；其它错误原样返回（不误吞）。
3. **ClassFileLoadHook 只派发一次**：探针阶段把 CFLH 输出的字节捕获到
   `JvmtiThreadState`（`cflh_capture_*`，`jvmtiThreadState.hpp/cpp`），回退时
   `KlassFactory::create_from_stream()` 发现 consume 模式即直接用缓存字节并
   **跳过** `check_class_file_load_hook()`（`klassFactory.cpp`）。
4. 并发槽位：标准路径天然使用 `RedefineClasses_lock`（`lock_classes/unlock_classes`），
   与 enhanced/P0 的串行槽位一致。

## 2. 关键坑：标准/增强混用会写坏 DCEVM 旧版本 vtable（已验证）

最初版本**不检查版本链**，fastdebug 下跑 Remold 两阶段负载（Stage A enhanced →
Stage C standard）+ `-XX:+SafepointALot` + 每 700 ms `System.gc()`，进程在 VM 退出校验时
fatal（`hs_err`）：

```
Internal Error (klassVtable.cpp:1617), "vtableEntry 0x...: method is from subclass"
klassVtable::verify -> InstanceKlass::verify_on -> ClassLoaderData::verify
  -> Universe::verify -> VM_Exit::doit
```

原因：enhanced redefine 后旧 `Klass` 版本仍存活（栈上旧方法要用），其 vtable 条目指向
新版本类的方法；标准重定义只修当前版本的 vtable/method entries，**不会修 DCEVM 旧版本**，
旧版本 vtable 出现"method holder 不是自己的父类型"的悬空关系。释放版（release）能跑完 12 轮
且 Remold 报 hotswap 成功（t80：redefine p50 76.5 ms），但这是**潜在内存/GC 损坏**，不能发布。

因此 v1 加了保守门控：**任一类有 DCEVM 版本链就整单走 enhanced**（`standard_path_eligible()`）。
fastdebug + SafepointALot + GC 脉冲下门控版本 12 轮无任何 fatal/assert（t87）。

## 3. 实测（Remold CI 内测版 agent，12 轮）

| 场景 | 派发 | redefine p50 / max | 批次 total p50 | 结果 |
|---|---|---|---|---|
| 纯方法体热更（release） | **12× standard** | **21 / 25 ms** | 56.5 ms | 12 hotswap 成功 |
| 结构性两阶段（release，v1 门控） | 12× enhanced（round1 探针被拒 1 次） | 97.5 / 110 ms | 208 ms | 与 P2 前 94 / 111 / 215 持平，无回退 |
| 纯方法体热更（fastdebug+ALot+GC） | 12× standard | 54 / 68 ms | 140.5 ms | 无 assert，12 hotswap 成功 |
| 结构性两阶段（fastdebug+ALot+GC） | 12× enhanced | 257.5 / 441 ms | 567 ms | 无 assert，12 hotswap 成功 |
| （对照）结构性两阶段，**不门控**（release） | 12× standard | 76.5 / 91 ms | 189.5 ms | **不可用**：fastdebug 触发上述 vtable fatal |

性能结论：纯方法体热更 **21 ms**（此前 enhanced 同 shape op ≈38 ms + 额外停编译）；
结构性批次保持 enhanced，但 Stage C 的 ~28 ms 收益要等 v2。

## 4. 下一步（P2 v2）

要让两阶段结构性批次的 Stage C 也走标准路径，v2 需要在标准重定义成功时同步维护
DCEVM 的旧版本链：对每个目标类沿 `old_version()` 链修正 vtable / method entries
（或让 enhanced 路径在 Stage A 后不保留旧版本 vtable 对当前方法的引用），然后用同一组
fastdebug + `SafepointALot` + `System.gc()` 混合用例回归。预期收益：结构性批次 redefine
从 ~94 ms 降到 ~76 ms（t80 的实测值），且热更后重编译量更小。
