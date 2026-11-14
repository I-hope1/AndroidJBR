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
