# JBR runtime feature patches

These are **not** Android port patches: they are optional JetBrainsRuntime
runtime fixes/features validated against JBR 25.0.5 (Linux aarch64, fastdebug).

## p0-notify-wait-v4.patch

Replaces the DCEVM enhanced-redefinition compile-drain loop:

* waits on a safepoint-safe monitor instead of polling with
  `VM_ForceSafepoint` every 10 ms (removes the 64-374 forced safepoints per
  redefinition and one potential deadlock class);
* reference-counts concurrent enhanced redefinitions (RAII guard in
  `JvmtiEnv::RedefineClasses`/`RetransformClasses`) and serializes their
  `doit_prologue()`..`doit_epilogue()` window on `RedefineClasses_lock`;
* fails fast (`JVMTI_ERROR_INTERNAL`) on nested enhanced redefinition from a
  `ClassFileLoadHook` callback instead of self-deadlocking.

Validation (fastdebug aarch64 build, JBR 25.0.5 + Android port tree):
`docs/deopt/P0-VERIFICATION.md`. Patch applies to a pristine `jbr25` tree
(`git apply --check` verified).

## p1-instrumentation.patch

Diagnostic only (apply on top of p0-notify-wait-v4.patch): while the enhanced
redefinition drain waits, log the in-flight compilation of every compiler thread
(thread, method, level, OSR bci, innermost C2 `Compile::TracePhase` name, time in
phase, total compile_ms) plus the total drain duration. Enabled with
`-Xlog:redefine+class=info`; threshold via `-XX:DcevmDrainDumpThreshold`
(default 50 ms). Phase state lives on the CompilerThread (Atomic store/load), so
there is no cross-thread dereference of the stack-allocated `Compile*`.

Measured on the synthetic long-C2 workload (bench.Med, 6.5 KB):
- release: drains 444-775 ms, C2 compile_ms median 554 ms; phases dominated by
  `idealLoop` (max 218 ms) and `optimizer` (max 531 ms), Chaitin sub-phases
  ~30 ms each; C1 averages 1.6 ms/method;
- fastdebug: drains 124-1281 ms, Chaitin/regalloc sub-phases inflated the most.
So P1 cancellation points must be sunk into the IdealLoop/IGVN/EA inner loops
and Register_Allocate round boundaries, not into buildIFG/fill_buffer.
See `docs/deopt/P1-INSTRUMENTATION.md`.

## p1-cancellation.patch

First version of cooperative cancellation (apply on top of
p1-instrumentation.patch; the instrumentation is diagnostic-only and can be
dropped for production). While an enhanced class redefinition is in progress,
in-flight C1/C2 compilations abort at safe boundaries instead of forcing the
redefinition to wait for the whole compilation:

- C2: Optimize()/Code_Gen() entry, PhaseIterGVN worklist (sampled every 64
  nodes), IdealLoop boundaries + per-loop-tree-node iteration_split,
  ConnectionGraph/split_unique_types, PhaseMacroExpand loops, and between
  PhaseChaitin Register_Allocate Split/Select rounds;
- C1: HIR -> Optimizer -> LIR -> CodeGen stage boundaries plus before install,
  recorded as a transient failure so the method is NOT marked not compilable.

Measured on the long-C2 bench.Med workload (release, 20 redefines): drains drop
from 444-775 ms to p50 6 ms / max 12 ms, redefine_ms 30-49 ms, bad=0 stale=0,
and every cancelled method recompiles at level 4 afterwards. See
`docs/deopt/P1-CANCELLATION.md`.
