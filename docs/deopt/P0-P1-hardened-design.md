# P0/P1 加固设计（针对内核 Review 的逐条修订）

> 回应：[`drain-elimination-analysis.md`](drain-elimination-analysis.md) 的内核 Review
> 产物：[`patches/p0-notify-wait-v2.patch`](patches/p0-notify-wait-v2.patch)（5 文件 +103/−28，已在 JBR25 树 `git apply --check` 通过）
> 树：JBR25 `25.0.5 @ 1b5d5af9`（`/home/ubuntu/jbr25-port/JBR25`，五个目标文件均为纯上游状态）；JBR21 `015db36d`

---

## 0. 结论

1. **P0 按 Review 重写了**：计数下沉到 `CompileBroker`（`_compilation_stop_count`）、RAII guard、每个并发 redefine 都等排空、超时检查 VM 退出状态；同时发现并修掉 Review 未提到的**线程状态陷阱**（safepoint-check 等待必须在 `_thread_in_vm`，而 JVMTI 入口在 native 态——不处理会在 fastdebug 直接 `fatal("LEAF method calling lock?")`）。
2. **P1 的取消点从 `Phase::Phase()` 移走**：改为 `Compile::Optimize()` / `Compile::Code_Gen()` 的阶段入口 + 已有 `failing()` 退出通道的长循环（IterGVN / IdealLoop / EA / Chaitin），并给 `ciEnv` 增加显式 `_is_cancelled` 退出通道（不置 `not_compilable`、不发 JFR 假失败）。
3. **额外简化**：不需要新增 cancel epoch/flag——**`_compilation_stopped` 本身就是要取消的集合**：它只在 compile gate 关闭（重定义窗口）期间为 true，此时所有在飞编译都已过期，编译器看到 true 直接放弃即可。一次 `volatile` 读，零锁零进 VM。
4. **C1 也发现一个必须处理的点**：`Compilation::compile_method()` 的 `if (bailed_out()) _env->record_method_not_compilable(bailout_msg())`（`c1_Compilation.cpp:609-612`）会把取消误标为 never-compilable，必须用 `_is_cancelled` 分流。

---

## 1. 对 Review 各条的核对结果

| # | Review 观点 | 核对结果（源码证据） | 处理 |
|---|---|---|---|
| P0-1 | `release...()` 是否 `notify_all`，否则编译器恢复要白等 10–20 ms | **有**：`compileBroker.cpp:2972-2978` 在 `DcevmCompilation_lock` 下 `_compilation_stopped=false; locker.notify_all();`；gate 是 `while(_compilation_stopped) locker.wait(20)`（:1983-1985），notify 立即唤醒，**不存在固定的 20 ms 白等** | 保持；v2 继续在此处 notify |
| P0-2 | 并发计数下沉到 `CompileBroker`，不要放 `JvmtiEnv`；第二个 redefine 也要等排空；RAII | 完全同意。现状：`RedefineClasses` **没有**计数（`jvmtiEnv.cpp:576`），`RetransformClasses` 的 `_active_redefinitions`（:503-508）在 `AllowEnhancedClassRedefinition` 下做了 add/stop/execute/sub/条件 release，但仍有两个缺口：① Redefine 路径完全没有计数；② `_active_redefinitions` 与 `_compilation_stopped` 不是一个协议 | **v2 已实现**：`_compilation_stop_count` + `EnhancedClassRedefinitionCompilationStop` RAII；每次 stop 都等排空；删除 `_active_redefinitions` |
| P0-3 | `wait(1000)` 超时后检查 VM 退出，避免 shutdown hook 卡死 | 对。`VM_Exit::vm_exited()` 在 `runtime/vmOperations.hpp:259`（public static）；`CompileBroker::_should_block` 在 `compileBroker.hpp:181`（private static，同类可读）；compileBroker.cpp **原本没有** include vmOperations.hpp | **v2 已实现**：`if (_should_block || VM_Exit::vm_exited()) return;` + 新增 include |
| P0-4 | （Review 未提）safepoint-check 等待的线程状态 | **必须修**：`JavaThread::check_for_valid_safepoint_state()`（`javaThread.cpp:400-402`）对 `_thread_in_vm` 以外的状态直接 `fatal("LEAF method calling lock?")`；JVMTI 入口（`jvmtiEnv.cpp:576`）是 native 态（`JvmtiEnv::RedefineClasses` 无 `VM_ENTRY_MARK`），`ThreadInVMfromNative` 只在 `jvmtiEnv.cpp:204` 这类局部出现 | **v2 已实现**：`stop...()` 内按 `thread_state() == _thread_in_native` 用 `ThreadInVMfromNative` 包住排空等待 |
| P1-1 | 不要在 `Phase::Phase()` 基类构造里 `C->record_failure`，会半初始化/断言 | **正确**。`Phase::Phase(PhaseNumber)`（`phase.cpp:52-57`）只做 `maybe_block()`；`PhaseIdealLoop/PhaseIterGVN/PhaseCCP/PhaseCFG/PhaseChaitin` 都继承它，基类构造返回后子类构造体和成员初始化继续执行 | **P1 v2**：取消点移到 `Compile::Optimize()`/`Code_Gen()` 阶段入口 + 长循环已有 `failing()` 出口；不在任何 `Phase` 构造函数里 |
| P1-2 | 审计 `C2Compiler::compile_method` / `CompileBroker` 失败后处理 | 已核对：`C2Compiler::compile_method` 的 `while (!env->failing())`（`c2compiler.cpp:131`）对非 retry 原因走 `env->record_failure(C.failure_reason())`（:196），随后 fail 循环退出；`Compile::failing()` 含 `_env->failing()`（`compile.hpp:806-812`）；install 闸门 `if (failing()) return;` 在 `compile.cpp:3107-3112`；broker 的 `handle_compile_error()`（`compileBroker.cpp:2156-2168`）只在 `AbortVMOnCompilationFailure` 下 fatal；`task->set_failure_reason` 在 :2406；**危险路径**是 `ciEnv` 自己没标失败时的 `record_method_not_compilable("compile failed")`（:2383）和 `ciEnv::report_failure` 的 JFR 事件（`ciEnv.cpp:1195-1200`） | **P1 v2**：`ciEnv::record_cancellation()` + `_is_cancelled`；`report_failure`、`record_failure` 的 log 对 cancel 静默；C1 的 not_compilable 分流（§3.4） |
| P1-3 | 取消轮询必须零进 VM、零锁 | 同意：`_compilation_stopped` 是 `volatile bool`（`compileBroker.hpp:203`），读一次即可（与 `maybe_block()` 读 `_should_block` 同模式）；不要用 `Atomic::load` 之外的锁，也不要在轮询点调 `maybe_block()`（它会进 VM） | **P1 v2**：`Atomic::load(&_compilation_stopped)`（或直接 volatile 读） |
| P1-4 | 已出队但卡在闸门外的任务、被取消任务要清 `queued_for_compilation` | 已核对：闸门外任务尚未 `Atomic::add(_active_compilations)`，睡在 gate 上安全；被取消任务的收尾在 `CompileBroker::invoke_compiler_on_method` 的 `CompileTaskWrapper` 路径，`method->clear_queued_for_compilation()` 在 `compileBroker.cpp:2467`；只要不置 `not_compilable`，方法之后还能正常重编 | **P1 v2**：取消路径不置 `not_compilable`、不递增失败计数 |
| 4b-1 | 标准/增强两个 `doit_prologue()` 都会 `load_new_class_versions()` + 派发 `ClassFileLoadHook`，不能跑两遍 | 正确：`VM_RedefineClasses::doit_prologue()`（`jvmtiRedefineClasses.cpp`）与 `VM_EnhancedRedefineClasses::doit_prologue()`（`jvmtiEnhancedRedefineClasses.cpp`）各自调用 `load_new_class_versions()`/CFLH。**判定必须发生在 `load_new_class_versions` 的公共阶段**（构造 op 之前用原始 `class_definitions` 做 EMCP 兼容性预判），然后只构造/执行一种 op | 写入 §4 的 4b 落地约束 |
| 4b-2 | 之前发生过增强重定义后切回标准路径，注意版本链状态 | 记录为验证项：标准 `VM_RedefineClasses::doit()` 的 `flush_dependent_code` 只认 `has_evol_metadata()`（旧 Method），若之前 DCEVM 留下 `new_version`/old 方法链，需确认标准路径的 `reset_old_method_table`/`MetadataOnStackMark` 语义仍成立 | 写入 §4 |

---

## 2. P0 v2 补丁（可直接 apply）

文件：[`patches/p0-notify-wait-v2.patch`](patches/p0-notify-wait-v2.patch)
规模：**5 文件 +103/−28**，`git apply --check` 通过（JBR25 纯净树）。
JBR21 树同构（`compileBroker.cpp` 的 stop 函数在 :2907 左右），移植时只需把 `_should_block`/`VM_Exit` 对应到 21 的同名 API。

### 2.1 变更清单

| 文件 | 变更 |
|---|---|
| `runtime/mutexLocker.hpp` | 新增 `extern Monitor* DcevmCompilationWait_lock;` |
| `runtime/mutexLocker.cpp` | 指针定义 + `MUTEX_DEFN(DcevmCompilationWait_lock, PaddedMonitor, safepoint);`（rank 同 `RedefineClasses_lock`，允许 safepoint-check 等待） |
| `compiler/compileBroker.hpp` | `_compilation_stop_count`；`drainCompilationsForEnhancedRedefinition()`；`EnhancedClassRedefinitionCompilationStop` RAII；include `memory/allocation.hpp`（`StackObj`） |
| `compiler/compileBroker.cpp` | include `runtime/vmOperations.hpp`；`_compilation_stop_count` 定义；gate 递减处改为在 `DcevmCompilationWait_lock` 下 `Atomic::sub` + 归零 `notify_all`；stop/release 重写 + 排空等待 |
| `prims/jvmtiEnv.cpp` | `RedefineClasses`/`RetransformClasses` 用 RAII guard；删除 `_active_redefinitions` 及其手动计数 |

### 2.2 关键代码（补丁内容节选）

```cpp
// compileBroker.cpp
void CompileBroker::drainCompilationsForEnhancedRedefinition() {
  assert(Thread::current()->thread_state() == _thread_in_vm, "must be in VM state");
  MonitorLocker wait_ml(DcevmCompilationWait_lock);
  while (Atomic::load(&_active_compilations) > 0) {
    // VM 关闭期编译器线程可能永远不回来，别让 shutdown hook 卡死
    if (_should_block || VM_Exit::vm_exited()) {
      return;
    }
    wait_ml.wait(1000);   // 仅兜底（lost wakeup / 编译线程异常退出）
  }
}

void CompileBroker::stopCompilationBeforeEnhancedRedefinition() {
  if (!AllowEnhancedClassRedefinition) return;
  {
    MonitorLocker locker(DcevmCompilation_lock, Mutex::_no_safepoint_check_flag);
    if (_compilation_stop_count++ == 0) {
      _compilation_stopped = true;
    }
  }
  JavaThread* self = JavaThread::current();
  if (self->thread_state() == _thread_in_native) {
    ThreadInVMfromNative tiv(self);       // safepoint-check 等待要求 VM 态
    drainCompilationsForEnhancedRedefinition();
  } else {
    drainCompilationsForEnhancedRedefinition();
  }
}

void CompileBroker::releaseCompilationAfterEnhancedRedefinition() {
  if (!AllowEnhancedClassRedefinition) return;
  MonitorLocker locker(DcevmCompilation_lock, Mutex::_no_safepoint_check_flag);
  assert(_compilation_stop_count > 0, "unbalanced enhanced redefinition stop/release");
  if (--_compilation_stop_count == 0) {
    _compilation_stopped = false;
    locker.notify_all();
  }
}
```

```cpp
// 编译线程 gate 之后的递减处（原 compileBroker.cpp:1996）
invoke_compiler_on_method(task);
{
  MonitorLocker ml(DcevmCompilationWait_lock);
  if (Atomic::sub(&_active_compilations, 1) == 0) {
    ml.notify_all();
  }
}
```

```cpp
// jvmtiEnv.cpp
if (AllowEnhancedClassRedefinition) {
  EnhancedClassRedefinitionCompilationStop stop_compilation;  // 引用计数 + RAII
  VM_EnhancedRedefineClasses op(class_count, class_definitions, jvmti_class_load_kind_redefine);
  VMThread::execute(&op);
  op_id = op.id();
  error = (op.check_error());
}
```

### 2.3 动机实证：未打补丁的 JBR25 并发 redefine 直接 SIGSEGV

在写本补丁前先用**未打补丁的**预编译 JBR25（25.0.4.1+1-b635.79）跑了并发 redefine 压测：

```
java -javaagent:bench-agent.jar -cp out/v1:out/bench \
     -XX:+AllowEnhancedClassRedefinition \
     -Xlog:safepoint=info:file=/tmp/sp-concurrent-before.log \
     bench.Stress concurrent out/v1,out/v1b 50 4
# -> SIGSEGV at pc=... in ConstantPool::klass_ref_at_noresolve(int, Bytecodes::Code)+0x6c
#    Current thread: VMThread, elapsed time 0.43s
#    证据：/home/ubuntu/deopt-study/evidence-jbr25-concurrent-redefine-crash.log
```

即 Review 指出的"`RedefineClasses` 没有引用计数"不是一个理论风险：4 个线程各 50 轮、0.4 秒内就能把 VM 打崩（崩溃点还是 VMThread 在 `klass_ref_at_noresolve` 里读到了正在被另一路 redefine 改写的常量池）。单线程同一负载 10 轮 138 ms 正常。**P0 v2 的 `_compilation_stop_count` + RAII 正是修这个：第二个 redefine 不会在 T1 release 后提前放开编译窗口，两个 VM op 在 gate 关闭期间串行执行。**

### 2.4 仍然存在的边界/风险（落地前必测）

1. **fastdebug 锁 rank/线程状态**：`DcevmCompilationWait_lock` 用 `safepoint` rank（与 `RedefineClasses_lock` 同），等待方必须是 `_thread_in_vm`；v2 已用 `ThreadInVMfromNative` 兜住 JVMTI 入口。需回归：`RetransformClasses`、`-agentlib:jdwp` + 热更、shutdown hook 里 redefine、两个线程同时 redefine。
2. **`_should_block` 只覆盖 VM shutdown 的 `maybe_block` 路径**：若未来新增“编译器线程提前退出”机制，需要扩展该判断（目前 `set_should_block` 只由 `VMThread` 在 `VM_Exit` safepoint 设置，足够）。
3. **`notify_all` 的正确性依赖递减在 `DcevmCompilationWait_lock` 下**：若未来有人把递减挪出去（比如为减少锁竞争改成纯 `Atomic::sub`），会 reintroduce lost wakeup；建议在代码注释里写死这个不变量（v2 已注释）。
4. **未编译验证**：本补丁只过了 `git apply --check` 和人工一致性检查，必须在 JBR21/JBR25 aarch64 上编译 + fastdebug 跑 JTReg。

---

### 2.5 v3/v4：并发 prologue 串行化 + 嵌套重入 fail-fast（实测后补充）

fastdebug 构建 + `bench.Stress concurrent` 暴露出 v2 之外的第二个缺陷：`doit_prologue()` 在调用方 JavaThread 上执行 `load_new_class_versions()`（拓扑排序、全局 `Klass::MarkedAsAffected` 标志），两个线程的 prologue 可并发执行 → 断言/损坏。v3 在 prologue..epilogue 用标准路径同款 `RedefineClasses_lock` 串行化（`_enhanced_redefinitions_in_progress` 槽位），修复后 4×100 并发通过。

v4 再加一层：同线程在 `ClassFileLoadHook` 里嵌套 redefine 会等自己而死锁，因此用 owner 线程记录做 **fail-fast**（`JVMTI_ERROR_INTERNAL`），实测嵌套调用报 `InternalError`、外层 redefine 正常完成、进程正常退出。

完整构建/验证记录（含构建配方、修复过程、before/after 数据、SafepointALot/嵌套用例）见 [`P0-VERIFICATION.md`](P0-VERIFICATION.md)，补丁：[`patches/p0-notify-wait-v4.patch`](patches/p0-notify-wait-v4.patch)。

## 3. P1 v2：取消点重排与 `_is_cancelled` 退出通道

### 3.1 取消信号 = `_compilation_stopped`

不需要新 flag/epoch：

```cpp
// compileBroker.hpp
static bool compilation_cancelled_by_redefinition() {
  // 只会在 enhanced redefine 的 gate 关闭期间为 true；volatile 读，零锁零进 VM
  return AllowEnhancedClassRedefinition && _compilation_stopped;
}
```

理由：`_compilation_stopped == true` 的窗口 = “所有在飞编译都早于本次 redefine”的窗口（gate 已关，新编译进不来）。C2/C1 在任意 poll 点看到 true 就可以放弃；drain 等待的也正是这批编译。

### 3.2 C2：把检查放在“阶段入口 + 长循环的既有 failing 出口”

已核对的安全点（全部已有 `if (failing()) return;` 退出通道，生命周期完整）：

| 位置 | 文件:行 | 建议 |
|---|---|---|
| `Compile::Optimize()` 入口（`print_method(PHASE_AFTER_PARSING)` 之后） | `opto/compile.cpp:2288` 起 | `if (check_cancellation()) return;`（避免在已请求取消时再启动一个大阶段） |
| `Compile::Optimize()` 各阶段边界 | 同函数内已有 `if (failing()) return;`（:2321/2327/2333/…/2461） | 无需新增：内层 poll 置失败后，这些既有检查会立即退出 |
| `PhaseIterGVN::optimize()` 主循环 | `opto/phaseX.cpp:1018`，循环 :1037 | 循环体内 `if (C->check_cancellation()) return;`（或每 1024 个节点一次） |
| `ConnectionGraph::compute_escape()` | `opto/escape.cpp:2389-2401` 已有 `maybe_block()` 的 `next % SAMPLE_SIZE == 0` 分支 | 在该分支里加 `if (C->check_cancellation()) break;`（**零新增 poll 机制，白捡**） |
| `PhaseIdealLoop` | `opto/loopnode.cpp` 已有 `C->failing()` 检查（5727/5772/5842/5955/5992/6574/7405） | 在主 build 循环每轮检查一次；长循环内部可直接复用这些出口 |
| `PhaseChaitin::Register_Allocate()` | `opto/chaitin.cpp` 重试循环，已有失败出口（452/482/487/494/569/575/682） | 每轮 alloc 尝试入口检查 |
| `Compile::Code_Gen()` | `opto/compile.cpp:2991`，`Matcher` 构造 :3006，后续 :3011/:3021/:3029 | 入口 + Matcher/regalloc 前各一次 |
| `Parse` | 可选 | 巨大方法的 parse 也可能长；若埋点显示 parse 占比高，在 inlining site（已有 `Phase` 构造点）加 |

**不要在 `Phase::Phase()` 基类构造里做**（Review P1-1 正确）：`phase.cpp:52-57` 只是 `maybe_block()` 的既有 poll 点；在此 `record_failure` 会让子类在 `failing()` 已 true 的半初始化状态下继续构造。

### 3.3 `Compile::check_cancellation()`

```cpp
// compile.hpp
bool check_cancellation();   // true = 已 failing（含取消）

// compile.cpp
bool Compile::check_cancellation() {
  if (failing_internal()) return true;
  if (CompileBroker::compilation_cancelled_by_redefinition()) {
    // 同时记录到 ciEnv（broker 据此识别“取消”，避免误标 not_compilable / 假 JFR 失败）
    env()->record_cancellation("cancelled by enhanced class redefinition");
    return true;
  }
  return false;
}
```

要点：
- `Compile::failing()` 本身已包含 `_env->failing()`（`compile.hpp:806-812`），所以 `record_cancellation` 之后所有既有 `if (failing()) return;` 自动生效；
- install 闸门 `if (failing()) return;`（`compile.cpp:3107-3112`）保证不安装过期 nmethod，不需要额外处理；
- `C2Compiler::compile_method` 的 `while (!env->failing())`（`c2compiler.cpp:131`）自然退出；非 retry 原因走 `env->record_failure(C.failure_reason())`（:196）——我们的 reason 不会命中任何 `retry_*`，不会被重试。

### 3.4 `ciEnv`：显式取消通道（避免“假失败”副作用）

```cpp
// ciEnv.hpp
bool _is_cancelled;
bool is_cancelled() const { return _is_cancelled; }
void record_cancellation(const char* reason);
void record_failure(const char* reason);   // 已有

// ciEnv.cpp
void ciEnv::record_cancellation(const char* reason) {
  _is_cancelled = true;
  if (_failure_reason.get() == nullptr) {
    _failure_reason.set(reason);   // 不写 CompilationLog 的 failure elem
  }
}

void ciEnv::record_failure(const char* reason) {
  if (_is_cancelled) return;       // 取消不是编译失败，别记 log_failure
  ... 原逻辑 ...
}

void ciEnv::report_failure(const char* reason) {
  if (_is_cancelled) return;       // 不 post JFR CompilationFailureEvent
  ... 原逻辑 ...
}
```

C1 还必须分流 `not_compilable`（**Review 没提、但必踩**）：

```cpp
// c1/c1_Compilation.cpp:609-612
if (bailed_out()) {
  if (_env->is_cancelled()) {
    _env->record_failure("cancelled by enhanced class redefinition");
  } else {
    _env->record_method_not_compilable(bailout_msg());   // 原逻辑
    if (is_profiling()) { ... }
  }
}
```

C1 的 poll 点：`Compilation::compile_java_method()` 的阶段边界（GraphBuilder→Optimizer→LIR→CodeGen）加 `if (env()->is_cancelled() || CompileBroker::compilation_cancelled_by_redefinition()) { _env->record_cancellation(...); bailout("cancelled..."); return; }`；C1 尾巴小，可后置。

### 3.5 其它必须核对的点

- **不要**在取消路径调 `record_method_not_compilable`（`ciEnv.cpp:1204`），否则方法被永久降级；
- broker 的 `post_compilation_event`（`EventCompilation`）仍会记 failure，可接受（真实事件），若要完全静默可在 `if (ci_env.is_cancelled())` 时跳过 commit（后续可选项）；
- `CompileTask::set_failure_reason`（:2406）会把 "cancelled by enhanced class redefinition" 写进 task 日志，便于观测，保留；
- 被取消任务的 `queued_for_compilation` 正常清理在 `compileBroker.cpp:2467`（`CompileTaskWrapper` 路径），不需要额外处理。

### 3.6 P1 的残余风险

- **无抢占**：检查点之间仍有一段延迟；巨型方法若卡在 `PhaseOutput::Output`、`Matcher`、`PhaseCFG` 等未加 poll 的循环里，取消要等该阶段结束（几十 ms～秒级）；验收目标应写“P99 < 100 ms”，并保留“超时后仍等完成”的兜底。
- `record_cancellation` 在任意 Phase 边界触发，需要审计各 Phase 在“进入时已 failing”时的行为（EA、matcher、regalloc 的空 IR/半构建状态）；建议先在 JBR25 上做 `-XX:+SafepointALot` + 大方法对抗用例，再做 release 验证。
- JVMCI 路径不覆盖（grep `cancel` 在 JVMCI 中零命中）；`-Xcomp`、`-XX:+RepeatCompilation`、`WhiteBox::compilation_locked` 需回归。

---

## 4. 4b（方法体快速路）的落地约束

1. **单次 CFLH**：EMCP 兼容性判定必须在 `load_new_class_versions()` 之前、基于原始 `class_definitions` 完成（或把 `load_new_class_versions` 抽成公共前置阶段，先算 `_max_redefinition_flags`/EMCP 判定，再决定构造 `VM_RedefineClasses` 还是 `VM_EnhancedRedefineClasses`）；不能先跑一个 op 的 `doit_prologue` 再换另一个。
2. **版本链**：若之前已有增强重定义，标准路径的 `flush_dependent_code()` 只认 `has_evol_metadata()`（旧 Method）——纯方法体场景下 vtable/字段布局未变，标准路径是安全的；但若存在未清理的 old version 残留，需要验证 `reset_old_method_table`/`MetadataOnStackMark` 语义。
3. **收益上限**：文档实测标准路径 54–63 ms（无排空、无 deopt-all 风暴）；这是 4b 的卖点，也让 P1 的收益只覆盖“结构性热更 + 长 C2 在飞”这一半场景。

---

## 5. 测试矩阵（P0 v2 / P1 v2 各自）

### P0 v2（先跑）
- [ ] JBR25 aarch64 构建通过（Android 移植树 + 本补丁）
- [ ] fastdebug：锁 rank/线程状态断言不炸（`ThreadInVMfromNative` 分支、`MonitorLocker` 的 `_thread_in_vm` 断言）
- [ ] `jshell`/JTReg：`serviceability/jvmti/RedefineClasses`、`vmTestbase/nsk/jvmti/RedefineClasses`、`RetransformClasses`
- [ ] 并发 redefine：两个 JavaThread 同时调 `redefineClasses`（T1/T2 各自等排空；gate 只在最后一个 release 打开）
- [ ] shutdown hook 里调用 redefine（`_should_block` 兜底路径）
- [ ] `-Xlog:safepoint` 热更窗口内不再有密集 `VM_ForceSafepoint`（预期 64–374 → 0）
- [ ] 对比原有实现：redefine 墙钟不退化（预期相等或略好，因为不再每 10ms 醒来做一次 VM op）

### P1 v2（埋点后跑）
- [ ] 同一负载排空墙钟 P50/P99（预期 680–3854 ms → 数十 ms～<100 ms）
- [ ] 对抗用例：巨型方法（`Heavy.hugeN` ×10 倍）、单阶段长编译
- [ ] fastdebug + `-XX:+SafepointALot` + 反复热更 5 分钟无断言
- [ ] 确认：被取消方法 `is_not_compilable` 未被置位；无 nmethod 安装（`-Xlog:codecache=info`）；下次仍能正常编译回 C2
- [ ] `-Xcomp` / `-XX:+RepeatCompilation` / `WhiteBox::compilation_locked` 组合回归

---

## 6. 下一步

1. **P0 v2 编译验证**：在 JBR25 aarch64 桌面上 apply 本补丁 → `make` → fastdebug 跑上面 P0 清单（预计 1–2 小时构建）。
2. **埋点确认 P1 长尾来源**：JBR25 临时加日志（stop 入口/出口、ForceSafepoint 计数、`>50 ms` 时 dump `CompilerThread::current()->task()`），拿 Remold 负载对照 680–3854 ms / 64–374 次，确认长尾确实来自单个 C2 任务。
3. **P1 v2 实现**：按 §3 的插入点做 `ciEnv::_is_cancelled` + `Compile::check_cancellation()` + IGVN/EA/Chaitin/Code_Gen 四处 poll，先在 JBR25 上验证，再回移 21。
