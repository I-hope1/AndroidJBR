#!/usr/bin/env bash
# AndroidJBR — step 4/5: cross-build the JDK images.
#
#   ./scripts/04-build.sh              # make images
#   ./scripts/04-build.sh --clean      # make clean images
#
# About an hour on a 2 vCPU aarch64 host, a bit less on 4+ cores.  The full log
# goes to $BUILD_LOG.
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

target_args=(images)
require_jbr_line
[ "${1:-}" = "--clean" ] && target_args=(clean images)

need_dir "$JBR_SRC" "run ./scripts/01-clone-jbr.sh first"
need_file "$BUILD_DIR/spec.gmk" "run ./scripts/03-configure.sh first"
need_dir "$FREETYPE_PREFIX/lib" "run ./scripts/setup-toolchain.sh first"

info "building: make ${target_args[*]} JOBS=$JOBS  (log: $BUILD_LOG)"
start=$(date +%s)
(
  cd "$JBR_SRC"
  # The wrappers and -L dummy_libs are already recorded in spec.gmk, so a
  # plain make is enough; the env vars are only here to shield against stray
  # user environment leaking into the build.
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    ANDROID_BUILD=1 \
    # OpenJDK's build system refuses `make -j`; it derives parallelism from JOBS.
    make JOBS="$JOBS" "${target_args[@]}"
) > "$BUILD_LOG" 2>&1 || {
  warn "build failed after $(( $(date +%s) - start ))s"
  tail -n 60 "$BUILD_LOG" >&2
  die "see $BUILD_LOG for the full log"
}

elapsed=$(( $(date +%s) - start ))
img="$BUILD_DIR/images/jdk"
need_dir "$img" "make images finished but $img is missing"
need_file "$img/lib/server/libjvm.so"
need_file "$img/bin/java"

if file "$img/bin/java" | grep -q 'ARM aarch64'; then
  info "images built in ${elapsed}s: $img (aarch64 confirmed)"
else
  warn "built java is not an aarch64 ELF — check the toolchain setup"
fi
info "next: ./scripts/05-package-jre.sh"
