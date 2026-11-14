#!/usr/bin/env bash
# AndroidJBR — step 5/5: turn the built images into a PojavLauncher-compatible
# bionic aarch64 JRE tarball.
#
#   out/jre21-jbr-android-arm64-<YYYYMMDD>.tar.xz   (~30 MB, ~140 MB unpacked)
#   out/SHA256SUMS.txt
#
# What happens here:
#   1. copy the JDK image and cross-built freetype into a staging tree
#   2. jlink (host boot JDK) with the Pojav module list
#   3. overlay Pojav's jre_override (fonts, fontconfig properties, dummy libawt_xawt)
#   4. llvm-strip every shared object
#   5. termux-elf-cleaner --api-level 21 (DT_RPATH / GNU_HASH / VERDEF cleanup)
#   6. assert the release file carries JAVA_VERSION + OS_ARCH (Pojav requirement)
#   7. tar.xz + sha256
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

IMAGES="$BUILD_DIR/images/jdk"
STAGE_JDK="$OUT/stage-jdk"
STAGE_JRE="$OUT/stage-jre"
STAMP=$(date +%Y%m%d)
TARBALL="$OUT/jre21-jbr-android-${TARGET_SHORT}-${STAMP}.tar.xz"

need_cmd tar; need_cmd sha256sum; need_cmd readelf; need_cmd file
need_cmd xz
need_dir "$IMAGES" "run ./scripts/04-build.sh first"
need_file "$IMAGES/lib/server/libjvm.so"
need_file "$BOOT_JDK/bin/jlink" "boot JDK is required for jlink"
need_file "$ELFC" "run ./scripts/setup-toolchain.sh first"
need_dir "$POJAV_BUILD/jre_override/lib" "run ./scripts/fetch-deps.sh first"
need_file "$FREETYPE_PREFIX/lib/libfreetype.so" "run ./scripts/setup-toolchain.sh first"

mkdir -p "$OUT"
info "staging images"
rm -rf "$STAGE_JDK" "$STAGE_JRE"
cp -r "$IMAGES" "$STAGE_JDK"
cp "$FREETYPE_PREFIX/lib/libfreetype.so" "$STAGE_JDK/lib/" 2>/dev/null \
  || cp "$FREETYPE_PREFIX/lib/libfreetype.so.6" "$STAGE_JDK/lib/libfreetype.so"

# --- jlink -------------------------------------------------------------------
modules=$(grep -vE '^[[:space:]]*(#|$)' "$_script_dir/pojav-modules.txt" | paste -sd, -)
info "jlink $(printf '%s' "$modules" | tr ',' '\n' | wc -l) modules"
"$BOOT_JDK/bin/jlink" \
  --module-path "$STAGE_JDK/jmods" \
  --add-modules "$modules" \
  --output "$STAGE_JRE" \
  --no-man-pages --no-header-files \
  --release-info="$STAGE_JDK/release" \
  --compress=0 \
  --strip-native-debug-symbols=exclude-debuginfo-files:objcopy="$HOST_OBJCOPY" \
  > "$WORK/jlink.log" 2>&1 || { tail -n 40 "$WORK/jlink.log" >&2; die "jlink failed — see $WORK/jlink.log"; }

# --- overlay freetype + Pojav leftovers -------------------------------------
cp "$FREETYPE_PREFIX/lib/libfreetype.so" "$STAGE_JRE/lib/" 2>/dev/null \
  || cp "$FREETYPE_PREFIX/lib/libfreetype.so.6" "$STAGE_JRE/lib/libfreetype.so"
cp -r "$POJAV_BUILD/jre_override/lib/." "$STAGE_JRE/lib/"

# --- strip + Android ELF cleanup -------------------------------------------
info "stripping shared objects"
find "$STAGE_JRE" -name '*.so' -exec "$HOST_STRIP" --strip-unneeded {} +
info "running elf-cleaner (API $ANDROID_API)"
elf_files=$(find "$STAGE_JRE" "$STAGE_JDK" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' sh {} \; || true)
if [ -n "$elf_files" ]; then
  # shellcheck disable=SC2086  # intentional word splitting: one path per file
  "$ELFC" --api-level "$ANDROID_API" $elf_files
fi

# --- release file: Pojav's MultiRTUtils reads these -------------------------
grep -q '^JAVA_VERSION=' "$STAGE_JRE/release" \
  || die "release file has no JAVA_VERSION"
grep -q '^OS_ARCH=' "$STAGE_JRE/release" \
  || sed -i "1i OS_ARCH=\"$TARGET_JDK\"" "$STAGE_JRE/release"

# --- assertions on the artifact --------------------------------------------
file "$STAGE_JRE/lib/server/libjvm.so" | grep -q 'ARM aarch64' \
  || die "libjvm.so is not an aarch64 ELF"
readelf -n "$STAGE_JRE/lib/server/libjvm.so" 2>/dev/null | grep -q 'Android' \
  || warn "no .note.android.ident in libjvm.so (elf-cleaner may have removed it)"
strings "$STAGE_JRE/lib/server/libjvm.so" | grep -q 'AllowEnhancedClassRedefinition' \
  || die "libjvm.so does not contain the DCEVM flag — wrong VM variant?"
[ -f "$STAGE_JRE/lib/libinstrument.so" ] || warn "libinstrument.so missing (agents unavailable)"
[ -f "$STAGE_JRE/lib/libfontmanager_xawt.so" ] \
  || warn "libfontmanager_xawt.so missing — FCL's cacio font path needs it (see docs/KNOWN-ISSUES.md)"

# --- tar.xz ------------------------------------------------------------------
info "packing $TARBALL"
(
  cd "$STAGE_JRE"
  XZ_OPT="-6 --threads=0" tar cJf "$TARBALL" .
)
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > SHA256SUMS.txt )

release_info=$(grep -E '^(JAVA_VERSION|OS_ARCH)=' "$STAGE_JRE/release" || true)
rm -rf "$STAGE_JDK" "$STAGE_JRE"

info "done"
ls -lh "$TARBALL"
printf '%s\n' "$release_info"
cat "$OUT/SHA256SUMS.txt"
