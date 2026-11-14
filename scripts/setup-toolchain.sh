#!/usr/bin/env bash
# AndroidJBR — prepare the cross toolchain:
#   1. check host LLVM (clang-18 / lld-18 / llvm binutils)
#   2. generate the clang wrappers seen by OpenJDK's configure as "gcc"
#   3. smoke-test a C and a C++ link for aarch64-linux-android
#   4. cross-compile freetype 2.10.0 (headers + libfreetype.so)
#   5. build termux-elf-cleaner (API-21 ELF cleanup at packaging time)
#
# Run after fetch-deps.sh (or point NDK / FREETYPE_SRC / WORK at existing trees).
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

need_cmd make
require_jbr_line
need_cmd sha256sum

print_summary
require_toolchain
mkdir -p "$WORK/toolchain/bin" "$WORK/bin"

# --- 1+2: wrappers -----------------------------------------------------------
info "generating clang wrappers in $WORK/toolchain/bin"
write_clang_wrapper "$WRAP_CC" cc
write_clang_wrapper "$WRAP_CXX" cxx

# --- 3: smoke tests ----------------------------------------------------------
smoke=$(temp_work_dir smoke)
cat > "$smoke/hello.c" <<'EOF'
extern int puts(const char *);
int main(void) { puts("androidjbr-smoke"); return 0; }
EOF
cat > "$smoke/hello.cc" <<'EOF'
#include <cstdio>
#include <string>
int main() { std::string s = "androidjbr-smoke"; std::puts(s.c_str()); return 0; }
EOF
info "smoke-testing C cross link"
"$WRAP_CC" "$smoke/hello.c" -o "$smoke/hello-c"
file "$smoke/hello-c" | grep -q 'ARM aarch64' \
  || die "C smoke test did not produce an aarch64 ELF: $(file "$smoke/hello-c")"
info "smoke-testing C++ cross link (static libc++ / -lunwind path)"
"$WRAP_CXX" "$smoke/hello.cc" -o "$smoke/hello-cxx"
file "$smoke/hello-cxx" | grep -q 'ARM aarch64' \
  || die "C++ smoke test did not produce an aarch64 ELF: $(file "$smoke/hello-cxx")"

# --- 4: freetype -------------------------------------------------------------
if [ -x "$FREETYPE_PREFIX/lib/libfreetype.so" ] || [ -f "$FREETYPE_PREFIX/lib/libfreetype.so.6" ]; then
  info "freetype already cross-built: $FREETYPE_PREFIX"
else
  need_dir "$FREETYPE_SRC" "run fetch-deps.sh first or set FREETYPE_SRC"
  info "cross-building freetype ${FREETYPE_VERSION}"
  (
    cd "$FREETYPE_SRC"
    # Always rebuild from a pristine tree: config.cache / stale objects from a
    # host build are a classic source of "wrong ELF class" failures.
    # Only clean with git when the freetype source really is its own repo: when
    # WORK lives inside a checkout (CI), `git clean` would walk up to that repo
    # and try to delete the caller's tree — git refuses with "Refusing to remove
    # current working directory".
    if [ -d .git ]; then git clean -xdfq; fi
    rm -rf "$FREETYPE_PREFIX"
    CC="$WRAP_CC" CXX="$WRAP_CXX" AR="$HOST_AR" RANLIB="$HOST_RANLIB" \
      ./configure \
        --host="$ANDROID_TARGET" \
        --build="$(uname -m)-unknown-linux-gnu" \
        --prefix="$FREETYPE_PREFIX" \
        --enable-shared --disable-static \
        --without-zlib --without-bzip2 --without-png \
        --without-harfbuzz --without-brotli \
        CFLAGS="-O2 -fPIC" \
      > "$WORK/freetype-configure.log" 2>&1 \
      || die "freetype configure failed — see $WORK/freetype-configure.log"
    make -j"$JOBS" > "$WORK/freetype-build.log" 2>&1 \
      || die "freetype build failed — see $WORK/freetype-build.log"
    make install >> "$WORK/freetype-build.log" 2>&1 \
      || die "freetype install failed — see $WORK/freetype-build.log"
  )
  file "$FREETYPE_PREFIX/lib/libfreetype.so" | grep -q 'ARM aarch64' \
    || die "freetype was not cross-compiled for aarch64: $(file "$FREETYPE_PREFIX/lib/libfreetype.so")"
fi

# --- 5: termux-elf-cleaner ---------------------------------------------------
if [ -x "$ELFC" ]; then
  info "elf-cleaner already built: $ELFC"
else
  need_cmd cmake "needed to build termux-elf-cleaner"
  need_dir "$WORK/termux-elf-cleaner" "run fetch-deps.sh first"
  info "building termux-elf-cleaner"
  (
    cd "$WORK/termux-elf-cleaner"
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release > "$WORK/elfc-cmake.log" 2>&1 \
      || die "elf-cleaner cmake failed — see $WORK/elfc-cmake.log"
    cmake --build build -j"$JOBS" >> "$WORK/elfc-cmake.log" 2>&1 \
      || die "elf-cleaner build failed — see $WORK/elfc-cmake.log"
    # The upstream CMake target was renamed to "termux-elf-cleaner" (3.x);
    # accept the old name too so a pinned older checkout keeps working.
    elfc_bin=build/termux-elf-cleaner
    [ -x "$elfc_bin" ] || elfc_bin=build/elf-cleaner
    [ -x "$elfc_bin" ] || die "elf-cleaner binary not found after cmake build"
    mkdir -p "$(dirname "$ELFC")"
    install -m 0755 "$elfc_bin" "$ELFC"
  )
fi

info "toolchain ready"
info "  wrappers : $WRAP_CC / $WRAP_CXX"
info "  freetype : $FREETYPE_PREFIX"
info "  elf-clean: $ELFC"
info "next: ./scripts/01-clone-jbr.sh"
