#!/usr/bin/env bash
# AndroidJBR — step 3/5: configure the patched JBR tree for
#   OpenJDK target  aarch64-linux-android<API>  (bionic, headless, server VM)
#   host            Linux aarch64 / x86_64 with clang-18 + NDK r27c sysroot
#
# The flags below are the exact set the shipped artifact was built with; they
# are reproduced in docs/BUILD.md with the reasoning for each group.
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

require_jbr_line
need_dir "$JBR_SRC" "run 01/02 first"
need_dir "$JBR_SRC/.git" "run 01/02 first"
need_file "$JBR_SRC/configure"
require_toolchain
need_dir "$FREETYPE_PREFIX/include/freetype2" "run ./scripts/setup-toolchain.sh first"
need_dir "$CUPS_SRC" "run ./scripts/fetch-deps.sh first"
need_dir "$DUMMY_LIBS" "run ./scripts/02-apply-patches.sh first"

# --- sanity: the whole series must be applied -------------------------------
while IFS= read -r line; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | xargs)
  [ -n "$line" ] || continue
  git -C "$JBR_SRC" apply --reverse --check --whitespace=nowarn \
    "$PATCH_DIR/$line" 2>/dev/null \
    || die "patch not applied in $JBR_SRC: $line — run ./scripts/02-apply-patches.sh first"
done < "$PATCH_SERIES"

extra_cflags="-DLE_STANDALONE -O3 -DANDROID -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
extra_ldflags="-L$DUMMY_LIBS -Wl,--undefined-version"

# The port keeps OPENJDK_TARGET_OS=linux, so a target of *-linux-android is not
# enough for configure to notice it is cross-compiling: it compares the
# autoconf build/host names.  Pass --build explicitly (the host's config.guess)
# so BUILD_CC/BUILD_CXX are detected as host compilers and the build tools
# (adlc, ...) are native.  Without this, JDK 25 builds adlc for bionic and the
# build dies with "cannot execute: required file not found".
GNU_BUILD_PLATFORM=$(sh "$JBR_SRC/make/autoconf/build-aux/config.guess" 2>/dev/null || true)
[ -n "$GNU_BUILD_PLATFORM" ] || die "cannot determine host platform via config.guess"

pch_args=()
case "${PRECOMPILED_HEADERS:-auto}" in
  disabled) pch_args=(--disable-precompiled-headers) ;;
  enabled)  pch_args=(--enable-precompiled-headers) ;;
  auto)     ;;
  *)        die "PRECOMPILED_HEADERS must be auto, enabled or disabled" ;;
esac

info "configuring JBR $JBR_LINE (target $ANDROID_TARGET$ANDROID_API, headless, server VM)"
rm -rf "$JBR_SRC/build"
(
  cd "$JBR_SRC"
  # ANDROID_BUILD=1 makes make/autoconf/libraries.m4 skip ALSA/DBus probing.
  ANDROID_BUILD=1 \
  CC="$WRAP_CC" \
  CXX="$WRAP_CXX" \
  AR="$HOST_AR" \
  RANLIB="$HOST_RANLIB" \
  OBJCOPY="$HOST_OBJCOPY" \
  STRIP="$HOST_STRIP" \
  bash configure \
    --openjdk-target="$ANDROID_TARGET" \
    --build="$GNU_BUILD_PLATFORM" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-build-jdk="$BOOT_JDK" \
    --with-toolchain-type=gcc \
    --with-devkit="$NDK_PREBUILT" \
    --with-extra-cflags="$extra_cflags" \
    --with-extra-cxxflags="$extra_cflags" \
    --with-extra-ldflags="$extra_ldflags" \
    --disable-warnings-as-errors \
    --enable-option-checking=fatal \
    --enable-headless-only=yes \
    --with-jvm-variants="$JVM_VARIANTS" \
    --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc,-zgc,-shenandoahgc,-jvmci \
    --with-native-debug-symbols=external \
    --with-debug-level="$DEBUG_LEVEL" \
    --with-freetype-include="$FREETYPE_PREFIX/include/freetype2" \
    --with-freetype-lib="$FREETYPE_PREFIX/lib" \
    --with-cups-include="$CUPS_SRC" \
    --with-fontconfig-include="$ANDROID_SYSROOT/usr/include" \
    --x-includes="$ANDROID_SYSROOT/usr/include/X11" \
    --x-libraries=/usr/lib \
    "${pch_args[@]}" \
    > "$CONFIGURE_LOG" 2>&1
) || {
  tail -n 40 "$CONFIGURE_LOG" >&2
  die "configure failed — full log: $CONFIGURE_LOG"
}

# --- post-conditions ---------------------------------------------------------
need_file "$BUILD_DIR/spec.gmk" "configure did not produce the expected build dir $BUILD_DIR"
jvm_variant=$(grep -E '^JVM_VARIANTS[[:space:]]*:=' "$BUILD_DIR/spec.gmk" | head -1 | awk -F':=' '{print $2}' | xargs)
[ "$jvm_variant" = "$JVM_VARIANTS" ] || die "unexpected JVM_VARIANTS in spec: $jvm_variant"
grep -qE '^BOOT_JDK[[:space:]]*:=' "$BUILD_DIR/spec.gmk" || die "spec.gmk has no BOOT_JDK"

info "configure OK"
info "  build dir : $BUILD_DIR"
info "  log       : $CONFIGURE_LOG"
info "next: ./scripts/04-build.sh"
