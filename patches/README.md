# patches/

## What this is

`jbr21-android-port.patch` is a single `git-format` patch that turns a pristine
`JetBrains/JetBrainsRuntime` **`jbr21` @ `015db36dcaaf5fd670735a10b74dd413b190a40d`**
(21.0.11) into the Android/bionic cross-build consumed by
`scripts/03-configure.sh` … `scripts/05-package-jre.sh`.

It applies with `git apply` on top of the pin (verified in CI by
`scripts/check-patch.sh`):

```
 44 files changed, 978 insertions(+), 80 deletions(-)
```

The series file lists it, so adding a future patch is a two-line change:
drop `0002-*.patch` in here and append its name to `series`.

## Provenance

| Layer | Source |
|---|---|
| Base tree | JetBrainsRuntime `jbr21` @ `015db36d` (21.0.11) |
| Android/bionic port | `PojavLauncherTeam/android-openjdk-build-multiarch` @ `f3936fb`, branch `buildjre17-21`: `patches/jre_21/android/jdk21u_android.diff` + `patches/jre_21/android/26_skip_proc_net6_check.diff` |
| Conflict resolution | 6 conflicting hunks resolved by hand when applying the Pojav diff to jbr21: `flags-cflags.m4`, `libraries.m4`, `JvmMapfile.gmk`, `Awt2dLibraries.gmk` (headless gate), `UnixNativeDispatcher.c`, `awt_LoadLibrary.c` |
| Build-system fixes | `make/GenerateLinkOptData.gmk` + `HelloClasslist.java` (headless classlist dump), `Awt2dLibraries.gmk` (build `libfontmanager_xawt.so` in headless mode), `libraries.m4` (skip ALSA/DBus when `ANDROID_BUILD=1`) |
| Runtime fixes | `os.cpp` (bionic C-heap pointer tagging vs aarch64 48-bit `movptr`; `TMPDIR`-aware temp dir; MTE heap-tag opt-out), `EncodingSupport_md.c` + `utf_util.c` (`codeset` `"ASCII"` → `"UTF-8"`), `os_linux.cpp` (`jvm_path` cache), `os_perf_linux.cpp` (`ifaddrs` allocation), `net_util_md.h` / `net_util_md.c` (`__ANDROID__`), `UnixNativeDispatcher.c`, `os_linux.cpp` `fork_and_exec` (`/system/bin/sh`) |
| Patch-review follow-ups | see `docs/KNOWN-ISSUES.md`; the final revision removes all `JBR_DIAG` instrumentation |

## File composition (44)

| Area | Files | What changes |
|---|---|---|
| Build system (`make/`) | 20 | target triple, clang/lld/toolchain handling, android OS defines, `--hash-style=sysv`, headless-only tweaks, module gmk wiring |
| HotSpot (`src/hotspot/`) | 14 | linux/posix/bionic OS layer, aarch64 thread-local helper, arm/arm32/x86 CPU files, ELF/global defines, `os::malloc/free/realloc` untag/retag, temp dir, MTE |
| JDK native + Java (`src/java.base`, `java.desktop`, `java.instrument`, `jdk.jdwp.agent`) | 10 | bionic paths (`/system/bin/sh`, `/data/local/tmp`), net/proc checks, UTF-8 codeset in `libinstrument`/`libjdwp`, `awt_LoadLibrary.c` X11-toolkit probe |

## Regenerating after an edit

The official flow keeps `git diff` as the source of truth:

```bash
# 1. edit the patched tree (scripts/01 + scripts/02 already applied the series)
$EDITOR work/JetBrainsRuntime/src/hotspot/...

# 2. regenerate the patch against the pin
cd work/JetBrainsRuntime
git diff 015db36dcaaf5fd670735a10b74dd413b190a40d > ../../patches/jbr21-android-port.patch

# 3. prove it still applies to a pristine pin
../../scripts/check-patch.sh
```

`scripts/02-apply-patches.sh` commits the patched tree locally (author
`AndroidJBR`), which is why HEAD is one commit ahead of `$JBR_PIN` during a
normal build.

## Scope / caveats

- **Not a generic desktop-Linux patch.** It assumes this exact cross-build:
  `TARGET_OS` stays `linux` (`make/autoconf/platform.m4` android branch is
  deliberately ordered after `*linux*`), `--hash-style=sysv` and `-D__USE_BSD`
  are applied globally because bionic's `linker64` needs them, and
  `libraries.m4` skips ALSA/DBus only when `ANDROID_BUILD=1` is exported.
- Conflicts with a newer JBR `jbr21` tip are expected as OpenJDK moves; pin
  bumps are a deliberate, tested operation (`JBR_PIN` in `scripts/env.sh`).
- The patch was produced and validated on an **aarch64 Linux host** (see
  docs/BUILD.md); an x86_64 host follows the same flags but has not been
  exercised end-to-end by this repo.
