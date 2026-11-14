#!/usr/bin/env bash
# shellcheck shell=bash
#
# AndroidJBR — central build configuration.
#
#   source scripts/env.sh
#
# Pick the JetBrainsRuntime line with JBR_LINE (default 21):
#
#   ./scripts/build.sh              # JBR 21 (verified track)
#   JBR_LINE=25 ./scripts/build.sh  # JBR 25 (experimental track)
#
# Nothing here is executed when the file is sourced.  Every path and version
# can be overridden from the environment, which is how an existing toolchain
# tree is reused instead of downloading everything again:
#
#   WORK=/srv/androidjbr-work ./scripts/build.sh
#   NDK=/opt/android-ndk-r27c BOOT_JDK=/opt/jdk-21.0.13+9 ./scripts/build.sh
#
# See docs/BUILD.md for the full dependency story.

# --- repository layout -------------------------------------------------------
_androidjbr_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export ANDROIDJBR_HOME=${ANDROIDJBR_HOME:-$(cd -- "$_androidjbr_script_dir/.." && pwd)}
export WORK=${WORK:-$ANDROIDJBR_HOME/work}
export OUT=${OUT:-$ANDROIDJBR_HOME/out}
unset _androidjbr_script_dir

# --- JBR line selection ------------------------------------------------------
# Each line pins: upstream branch + commit, boot JDK version, patch directory.
export JBR_LINE=${JBR_LINE:-21}

_jbr_line_ok=0
_jbr_branch=
_jbr_pin=
_jdk_major=
_boot_jdk_version=
case "$JBR_LINE" in
  21)
    _jbr_line_ok=1
    _jbr_branch=jbr21
    _jbr_pin=015db36dcaaf5fd670735a10b74dd413b190a40d
    _jdk_major=21
    _boot_jdk_version=21.0.13+9
    _pch=auto
    ;;
  25)
    _jbr_line_ok=1
    _jbr_branch=jbr25
    _jbr_pin=1b5d5af9510803fdc84f14dc636282d6cd02a5aa
    _jdk_major=25
    _boot_jdk_version=25.0.5+8
    # JDK 25's PCH handling assumes gcc-style .gch lookup; the clang wrapper
    # cannot use it (clang needs the header next to the .gch), so the 25 track
    # builds without precompiled headers until that is solved properly.
    _pch=disabled
    ;;
esac
export JBR_LINE_OK=$_jbr_line_ok
export JDK_MAJOR=${JDK_MAJOR:-$_jdk_major}

export JBR_REPO=${JBR_REPO:-https://github.com/JetBrains/JetBrainsRuntime.git}
export JBR_BRANCH=${JBR_BRANCH:-$_jbr_branch}
export JBR_PIN=${JBR_PIN:-$_jbr_pin}
export BOOT_JDK_VERSION=${BOOT_JDK_VERSION:-$_boot_jdk_version}
export PRECOMPILED_HEADERS=${PRECOMPILED_HEADERS:-$_pch}
unset _jbr_branch _jbr_pin _jdk_major _boot_jdk_version _pch _jbr_line_ok

# Patch set for the selected line — see patches/jbr<N>/series.
export PATCH_DIR=${PATCH_DIR:-$ANDROIDJBR_HOME/patches/jbr$JBR_LINE}
export PATCH_SERIES=${PATCH_SERIES:-$PATCH_DIR/series}

# --- other upstream pins (fixed on purpose — do not float) ------------------
export POJAV_REPO=${POJAV_REPO:-https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch.git}
export POJAV_BRANCH=${POJAV_BRANCH:-buildjre17-21}
export POJAV_PIN=${POJAV_PIN:-f3936fba6fcf14f45202c5dd8d2d8179dde051b2}

export ELFC_REPO=${ELFC_REPO:-https://github.com/termux/termux-elf-cleaner.git}
export ELFC_PIN=${ELFC_PIN:-f9273bcb37bf4c187123438566657fa5ac40cd51}

# --- dependency versions -----------------------------------------------------
export NDK_VERSION=${NDK_VERSION:-27c}
export NDK_URL=${NDK_URL:-https://dl.google.com/android/repository/android-ndk-r${NDK_VERSION}-linux.zip}

_temurin_arch=
case "$(uname -m)" in
  aarch64 | arm64) _temurin_arch=aarch64 ;;
  x86_64 | amd64)  _temurin_arch=x64 ;;
esac
if [ -n "${TEMURIN_URL:-}" ]; then
  : # caller supplied an explicit URL
elif [ -n "${JDK_MAJOR:-}" ] && [ -n "$_temurin_arch" ]; then
  TEMURIN_URL="https://github.com/adoptium/temurin${JDK_MAJOR}-binaries/releases/download/jdk-${BOOT_JDK_VERSION/+/%2B}/OpenJDK${JDK_MAJOR}U-jdk_${_temurin_arch}_linux_hotspot_${BOOT_JDK_VERSION/+/_}.tar.gz"
else
  TEMURIN_URL=""
fi
export TEMURIN_URL
unset _temurin_arch

export FREETYPE_VERSION=${FREETYPE_VERSION:-2.10.0}
export FREETYPE_URL=${FREETYPE_URL:-https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.gz}

export CUPS_VERSION=${CUPS_VERSION:-2.2.4}
export CUPS_URL=${CUPS_URL:-https://github.com/OpenPrinting/cups/archive/refs/tags/v${CUPS_VERSION}.tar.gz}

# --- Android target ----------------------------------------------------------
export ANDROID_API=${ANDROID_API:-21}
export ANDROID_TARGET=${ANDROID_TARGET:-aarch64-linux-android}
export TARGET_JDK=${TARGET_JDK:-aarch64}          # OpenJDK build dir / OS_ARCH
export TARGET_SHORT=${TARGET_SHORT:-arm64}        # artifact naming
export JVM_VARIANTS=${JVM_VARIANTS:-server}
export DEBUG_LEVEL=${DEBUG_LEVEL:-release}

# libraries.m4 skips ALSA/DBus probing when this is set.  It is read at
# configure time and is *required* — without it the build tries to link against
# host ALSA/DBus and fails.
export ANDROID_BUILD=1

# --- toolchain trees (all overridable) --------------------------------------
export NDK=${NDK:-$WORK/android-ndk-r${NDK_VERSION}}
# The NDK ships one prebuilt toolchain per host arch; only its sysroot, clang
# resource dir and headers are used by this build (the actual compiler is the
# host clang-18).  The linux-x86_64 copy is therefore usable on aarch64 hosts
# too — this is intentional, not a typo.
export NDK_PREBUILT=${NDK_PREBUILT:-$NDK/toolchains/llvm/prebuilt/linux-x86_64}
export ANDROID_SYSROOT=${ANDROID_SYSROOT:-$NDK_PREBUILT/sysroot}
# NDK sysroot has no fontconfig/X11 headers; fetch-deps.sh assembles the header
# subtrees from the host distro here and 03-configure.sh points -I at it.
export SYSROOT_EXTRA=${SYSROOT_EXTRA:-$WORK/sysroot-extra}
export BOOT_JDK=${BOOT_JDK:-$WORK/jdk-${BOOT_JDK_VERSION}}

export FREETYPE_SRC=${FREETYPE_SRC:-$WORK/freetype-${FREETYPE_VERSION}}
export FREETYPE_PREFIX=${FREETYPE_PREFIX:-$FREETYPE_SRC/build_android-${TARGET_SHORT}}
export CUPS_SRC=${CUPS_SRC:-$WORK/cups-${CUPS_VERSION}}

export POJAV_BUILD=${POJAV_BUILD:-$WORK/android-openjdk-build-multiarch}
export ELFC=${ELFC:-$WORK/bin/elf-cleaner}

# One source tree per JBR line so several lines can be built side by side.
export JBR_SRC=${JBR_SRC:-$WORK/JetBrainsRuntime-${JBR_LINE}}
export BUILD_DIR=${BUILD_DIR:-$JBR_SRC/build/linux-${TARGET_JDK}-${JVM_VARIANTS}-${DEBUG_LEVEL}}

# Host LLVM used as the cross compiler.  On Ubuntu 24.04 with the clang-18 /
# llvm-18 / lld-18 / autoconf / m4 packages installed, LLVM_ROOT=/usr works.
# For the no-root "extracted .deb" workflow point it at the extracted prefix,
# e.g. LLVM_ROOT=$WORK/llvm/usr (see docs/BUILD.md).
export LLVM_ROOT=${LLVM_ROOT:-/usr}
export LLVM_BIN=${LLVM_BIN:-$LLVM_ROOT/bin}
export LLVM_LIB=${LLVM_LIB:-$LLVM_ROOT/lib/llvm-18/lib}
export HOST_CLANG=${HOST_CLANG:-$LLVM_BIN/clang-18}
export HOST_CLANGXX=${HOST_CLANGXX:-$LLVM_BIN/clang++-18}
export HOST_AR=${HOST_AR:-$LLVM_BIN/llvm-ar}
export HOST_RANLIB=${HOST_RANLIB:-$LLVM_BIN/llvm-ranlib}
export HOST_OBJCOPY=${HOST_OBJCOPY:-$LLVM_BIN/llvm-objcopy}
export HOST_STRIP=${HOST_STRIP:-$LLVM_BIN/llvm-strip}
export HOST_NM=${HOST_NM:-$LLVM_BIN/llvm-nm}
# Directory containing a plain `ld.lld` (clang -fuse-ld=lld looks it up on PATH);
# empty when the host's LLVM install has it on PATH already.
export LLD_BIN=${LLD_BIN:-}

# Wrappers generated by setup-toolchain.sh; configure sees them as "gcc".
export WRAP_CC=${WRAP_CC:-$WORK/toolchain/bin/clang-android}
export WRAP_CXX=${WRAP_CXX:-$WORK/toolchain/bin/clang++-android}
export DUMMY_LIBS=${DUMMY_LIBS:-$JBR_SRC/dummy_libs}

# --- build knobs -------------------------------------------------------------
export JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
export BUILD_LOG=${BUILD_LOG:-$WORK/build-jbr${JBR_LINE}.log}
export CONFIGURE_LOG=${CONFIGURE_LOG:-$WORK/configure-jbr${JBR_LINE}.log}
