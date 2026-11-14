#!/usr/bin/env bash
# AndroidJBR — download the external inputs (no build happens here).
#
#   ./scripts/fetch-deps.sh            # download everything missing
#   ./scripts/fetch-deps.sh --sources  # skip the big NDK/boot-JDK archives
#
# Everything lands under $WORK (work/ by default) and is reused on re-runs.
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

sources_only=0
require_jbr_line
[ "${1:-}" = "--sources" ] && sources_only=1

mkdir -p "$WORK" "$OUT"

if [ "$sources_only" -eq 0 ]; then
  # --- Android NDK (only the sysroot + clang resource dir are used) --------
  if [ ! -d "$NDK_PREBUILT/sysroot" ]; then
    need_cmd curl; need_cmd unzip
    fetch "$NDK_URL" "$WORK/android-ndk-r${NDK_VERSION}-linux.zip"
    info "unpacking NDK r${NDK_VERSION}"
    unzip -q "$WORK/android-ndk-r${NDK_VERSION}-linux.zip" -d "$WORK/.ndk-unpack"
    mv "$WORK/.ndk-unpack/android-ndk-r${NDK_VERSION}" "$NDK"
    rmdir "$WORK/.ndk-unpack"
  else
    info "NDK already present: $NDK"
  fi

  # --- boot JDK (Temurin, host architecture) ------------------------------
  if [ ! -x "$BOOT_JDK/bin/jlink" ]; then
    [ -n "$TEMURIN_URL" ] || die "unsupported host architecture for Temurin download; set BOOT_JDK=<path> to an existing JDK 21"
    need_cmd curl; need_cmd tar
    fetch "$TEMURIN_URL" "$WORK/OpenJDK21U-jdk_linux.tar.gz"
    info "unpacking boot JDK ${BOOT_JDK_VERSION}"
    tar -xzf "$WORK/OpenJDK21U-jdk_linux.tar.gz" -C "$WORK"
    # the tarball expands to jdk-21.0.13+9, matching $BOOT_JDK
    [ -x "$BOOT_JDK/bin/jlink" ] || die "boot JDK did not unpack to $BOOT_JDK"
  else
    info "boot JDK already present: $BOOT_JDK"
  fi
fi

# --- freetype (cross-compiled by setup-toolchain.sh) -----------------------
if [ ! -d "$FREETYPE_SRC" ]; then
  need_cmd curl; need_cmd tar
  fetch "$FREETYPE_URL" "$WORK/freetype-${FREETYPE_VERSION}.tar.gz"
  tar -xzf "$WORK/freetype-${FREETYPE_VERSION}.tar.gz" -C "$WORK"
fi

# --- CUPS headers (configure --with-cups-include) --------------------------
# Only the source headers are used; nothing is built or linked from CUPS.
if [ ! -d "$CUPS_SRC" ]; then
  need_cmd curl; need_cmd tar
  fetch "$CUPS_URL" "$WORK/cups-${CUPS_VERSION}.tar.gz"
  tar -xzf "$WORK/cups-${CUPS_VERSION}.tar.gz" -C "$WORK"
fi

# --- PojavLauncher build repo: jre_override (fonts, fontconfig, dummy awt) -
if [ ! -d "$POJAV_BUILD/.git" ]; then
  need_cmd git
  info "cloning PojavLauncher build repo ($POJAV_BRANCH)"
  git clone --quiet --depth 1 --branch "$POJAV_BRANCH" "$POJAV_REPO" "$POJAV_BUILD"
  got=$(git -C "$POJAV_BUILD" rev-parse HEAD)
  if [ "$got" = "$POJAV_PIN" ]; then
    info "pojav build repo at pinned commit"
  else
    warn "pojav build repo is at $got, expected $POJAV_PIN (override POJAV_PIN if intentional)"
  fi
fi
[ -d "$POJAV_BUILD/jre_override/lib" ] || die "jre_override missing under $POJAV_BUILD"

# --- termux-elf-cleaner (built by setup-toolchain.sh) ---------------------
if [ ! -d "$WORK/termux-elf-cleaner/.git" ]; then
  need_cmd git
  info "cloning termux-elf-cleaner"
  git clone --quiet "$ELFC_REPO" "$WORK/termux-elf-cleaner"
  git -C "$WORK/termux-elf-cleaner" checkout --quiet "$ELFC_PIN"
fi

info "all external inputs are in place under $WORK"
