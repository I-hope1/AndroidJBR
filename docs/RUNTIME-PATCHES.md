# DCEVM runtime patches (P0 / P1 / P2) in AndroidJBR

AndroidJBR's JBR 25 build now carries three runtime-behaviour patches on top of
the Android port patch. They target the enhanced class redefinition path that
Remold / JBR DCEVM hot reload uses, and they are listed in
`patches/jbr25/series`:

| patch | file | what it does |
|---|---|---|
| P0 | `patches/runtime/p0-notify-wait-v4.patch` | The stop-the-compilers window no longer polls `VM_ForceSafepoint` every 10 ms: a ref-counted gate is released with a real monitor, concurrent enhanced redefinitions are serialized, and nested CFLH redefinition fails fast. |
| P1 | `patches/runtime/p1-cancellation-standalone.patch` | Compiler threads cooperatively abort in-flight C1/C2 compilations at safe phase boundaries while a redefinition window is open. Cancellation is a transient failure: methods are never marked not-compilable and the policy re-enqueues them. |
| P2 | `patches/runtime/p2-standard-fastpath.patch` | Redefine requests with no DCEVM structural change are dispatched through the standard `VM_RedefineClasses` path (no instance walk / cpool walk / Heap-Inspection Full GC / stop-compilation window). Structural requests fall back to the enhanced path. `ClassFileLoadHook` is posted exactly once. |

All three are applied in this order and verified by CI
(`p2-runtime-series` branch run 43689018820: 4 patches, 75 files changed).
They touch only HotSpot sources and do not change the Android port.

## Measured effect (upstream-style JBR 25, Remold example workload)

| metric | before | after |
|---|---|---|
| enhanced-redefinition drain | 444-775 ms | 4-12 ms (P0+P1) |
| `ForceSafepoint` storms during redefinition | 23 per 12 hot swaps | 0 |
| method-body-only batch redefine | ~38 ms | 21 ms (P2) |
| redefinition drain tail under C2 pressure | 444-775 ms | bounded by phase cancellation |

Structural redefinition batches (field layout changes) still take the enhanced
path: the remaining cost is the DCEVM instance-size update (heap walk +
Heap-Inspection Full GC), which is inherent to that path and not addressed by
these patches.

## Verifying on a device

Start the app with the enhanced-redefinition flag and redefinition logging:

```text
-XX:+AllowEnhancedClassRedefinition
-Xlog:redefine+class=info
```

With P0+P1 you should see, on every enhanced redefine:

* `compilation drain finished after <n> ms` with small numbers (single-digit to
  low tens of ms) instead of hundreds of ms;
* no `ForceSafepoint` requests caused by `stopCompilationBeforeEnhancedRedefinition`;
* under compile pressure, `cancelled in-flight compilation: method='...' level=...`
  lines (C2) / `cancelled in-flight compilation (C1): ...` (C1) — the cancelled
  methods recompile after the redefinition window (level 4, or level 1 when
  running with `-XX:TieredStopAtLevel=1`).

With P2, method-body-only redefines additionally log
`standard redefine path accepted (no structural change)` and no longer enter the
DCEVM heap-walk path; structural redefines log
`standard redefine path rejected (64: structural change), falling back to enhanced`.

## Not included (yet)

* JBR 21: P1/P2 depend on the JBR 25 `VM_EnhancedRedefineClasses` code; a JBR 21
  port of the runtime layer is separate work.
* P2 v2 (letting the second stage of a two-phase structural redefine use the
  standard path) is deliberately not implemented: mixing standard and enhanced
  class-version models corrupts DCEVM old-version vtables
  (`klassVtable.cpp:1617` fatal in fastdebug). P2 v1 gates on "no DCEVM version
  chain" and is the safe stopping point.
