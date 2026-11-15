#!/usr/bin/env bash
# shellcheck shell=bash
#
# AndroidJBR — small helper library shared by every script.
# Source it right after env.sh:
#
#   source "$(dirname "$0")/lib.sh"

# --- logging -----------------------------------------------------------------
# All output goes to stderr except the deliberate CRITICAL messages, so command
# substitution in the scripts never mixes logs into captured values.
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
info() { log "==> $*"; }
warn() { log "WARN: $*"; }
die()  { log "FATAL: $*"; exit 1; }

# --- guards ------------------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

need_file() {
  [ -e "$1" ] || die "required path not found: $1${2:+ — $2}"
}

need_dir() {
  [ -d "$1" ] || die "required directory not found: $1${2:+ — $2}"
}

# --- host LLVM binutils resolution -----------------------------------------
# Debian/Ubuntu package versioned binaries (llvm-ar-18, llvm-strip-18, ...) and
# only create unversioned names through update-alternatives, which is often not
# active on CI images.  Accept both spellings so LLVM_ROOT=/usr works after
# `apt-get install llvm-18`.
_androidjbr_resolve_llvm_binutil() {
  local var=$1 cur base cand
  eval "cur=\$$var"
  [ -x "$cur" ] && return 0
  base=${cur##*/}
  for cand in "$LLVM_BIN/${base}-22" "$LLVM_BIN/${base}-21" "$LLVM_BIN/${base}-20" \
              "$LLVM_BIN/${base}-19" "$LLVM_BIN/${base}-18" "$LLVM_BIN/${base}-17"; do
    [ -x "$cand" ] && { export "$var=$cand"; return 0; }
  done
  cand=$(command -v "$base" 2>/dev/null || true)
  [ -n "$cand" ] && export "$var=$cand"
  return 0
}
if [ -n "${LLVM_BIN:-}" ]; then
  for _v in HOST_AR HOST_RANLIB HOST_OBJCOPY HOST_STRIP HOST_NM; do
    _androidjbr_resolve_llvm_binutil "$_v"
  done
  unset _v
fi

# require_jbr_line: validate JBR_LINE early with a list of supported lines.
require_jbr_line() {
  [ "${JBR_LINE_OK:-0}" = "1" ] \
    || die "unsupported JBR_LINE='${JBR_LINE:-}' (supported: 21, 25) — see README / scripts/env.sh"
  need_file "$PATCH_SERIES" "no patch series for JBR $JBR_LINE (expected $PATCH_SERIES)"
}

# series_lines: print the effective patch list, one relative path per line.
# RUNTIME_PATCHES=0 drops the ../runtime/* layer so the same series can build a
# baseline (Android port only) and a patched (port + P0/P1/P2) JBR from one
# checkout.  Default is 1 (runtime patches included).
series_lines() {
  while IFS= read -r line; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | xargs)
    [ -n "$line" ] || continue
    if [ "${RUNTIME_PATCHES:-1}" = "0" ] && [ "${line#../runtime/}" != "$line" ]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$PATCH_SERIES"
}

# require_toolchain: fail fast with actionable advice when the cross toolchain
# is incomplete.
require_toolchain() {
  [ -n "${HOST_CLANG:-}" ] || die "env.sh was not sourced"
  [ -x "$HOST_CLANG" ] || die "host clang not found at $HOST_CLANG
  Install clang-18 / lld-18 / llvm-18 (apt-get install clang-18 lld-18 llvm-18),
  or point LLVM_ROOT at an extracted package prefix (see docs/BUILD.md)."
  # shellcheck disable=SC2153  # provided by env.sh
  [ -x "$HOST_CLANGXX" ] || die "host clang++ not found at $HOST_CLANGXX"
  [ -x "$HOST_AR" ]      || die "llvm-ar not found at $HOST_AR"
  need_dir "$NDK_PREBUILT/sysroot" "unpack android-ndk-r${NDK_VERSION:-27c} into \$WORK or set NDK=<path>"
  need_dir "$BOOT_JDK" "install Temurin ${BOOT_JDK_VERSION:-21.0.13+9} or set BOOT_JDK=<path>"
  [ -x "$BOOT_JDK/bin/jlink" ] || die "boot JDK is missing bin/jlink: $BOOT_JDK"
}

# --- downloads ---------------------------------------------------------------
# fetch <url> <dest-file> [<sha256>]
fetch() {
  local url=$1 dest=$2 sha=${3:-}
  if [ -f "$dest" ] && [ -n "$sha" ] && printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status 2>/dev/null; then
    info "already downloaded: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  info "download $url"
  curl -fL --retry 3 --retry-delay 5 -o "$dest.part" "$url" \
    || die "download failed: $url"
  mv "$dest.part" "$dest"
  if [ -n "$sha" ]; then
    printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status \
      || die "sha256 mismatch: $dest"
  fi
}

# clone_at <repo> <dest> <commit-or-branch> [<depth-args...>]
# Shallow fetch a single commit when the server allows it, otherwise fall back
# to a branch fetch (GitHub allows fetching arbitrary reachable commits).
clone_at() {
  local repo=$1 dest=$2 ref=$3
  shift 3
  if [ -d "$dest/.git" ]; then
    info "reusing existing clone: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if ! git -C "$(dirname "$dest")" clone --quiet --no-checkout --filter=blob:none \
       --branch "$ref" --single-branch "$repo" "$dest" 2>/dev/null; then
    info "branch '$ref' not found, fetching commit directly"
    mkdir -p "$dest"
    git -C "$dest" init --quiet
    git -C "$dest" remote add origin "$repo"
    git -C "$dest" fetch --quiet --depth 1 origin "$ref" \
      || die "cannot fetch $ref from $repo"
  fi
  git -C "$dest" -c advice.detachedHead=false checkout --quiet "$ref" \
    || die "cannot checkout $ref in $dest"
}

# --- misc --------------------------------------------------------------------
# temp_work_dir <name>: create a scratch dir under the build work area.
temp_work_dir() {
  local d="$WORK/tmp/$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# write_clang_wrapper <path> <mode cc|cxx>
# OpenJDK's configure insists on a gcc-compatible compiler; these wrappers
# forward to host clang-18 with the NDK sysroot and the bionic-compatible
# linker/run-time flags, and spoof `--version` so configure classifies it as gcc.
write_clang_wrapper() {
  local out=$1 mode=$2
  mkdir -p "$(dirname "$out")"
  if [ "$mode" = "cc" ]; then
    cat > "$out" <<EOF
#!/usr/bin/env bash
# generated by AndroidJBR setup-toolchain.sh — do not edit
if [ "\$1" = "--version" ]; then
  echo "\${ANDROID_TARGET:-aarch64-linux-android}-gcc (GCC) 4.9 20140827 (prerelease)"
  echo "Copyright (C) 2014 Free Software Foundation, Inc."
  exit 0
fi
export LD_LIBRARY_PATH="$LLVM_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export PATH="$LLVM_BIN\${LLD_BIN:+:\$LLD_BIN}:\$PATH"
exec "$HOST_CLANG" \\
  --target="\${ANDROID_TARGET:-aarch64-linux-android}\${ANDROID_API:-21}" \\
  --sysroot="$ANDROID_SYSROOT" \\
  -resource-dir="$NDK_PREBUILT/lib/clang/18" \\
  --rtlib=compiler-rt -fuse-ld=lld \\
  -Wno-unknown-warning-option "\${@/-fno-var-tracking-assignments/}"
EOF
  else
    cat > "$out" <<EOF
#!/usr/bin/env bash
# generated by AndroidJBR setup-toolchain.sh — do not edit
if [ "\$1" = "--version" ]; then
  echo "\${ANDROID_TARGET:-aarch64-linux-android}-g++ (GCC) 4.9 20140827 (prerelease)"
  echo "Copyright (C) 2014 Free Software Foundation, Inc."
  exit 0
fi
export LD_LIBRARY_PATH="$LLVM_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export PATH="$LLVM_BIN\${LLD_BIN:+:\$LLD_BIN}:\$PATH"
args=("\${@/-fno-var-tracking-assignments/}")
link=1
for a in "\${args[@]}"; do
  case "\$a" in -c|-E|-S|-M|-MM|c++-header) link=0 ;; esac
done
# NDK's static libc++abi references the LLVM unwinder; it must come last.
if [ "\$link" = "1" ]; then args+=(-lunwind); fi
exec "$HOST_CLANGXX" \\
  --target="\${ANDROID_TARGET:-aarch64-linux-android}\${ANDROID_API:-21}" \\
  --sysroot="$ANDROID_SYSROOT" \\
  -resource-dir="$NDK_PREBUILT/lib/clang/18" \\
  --rtlib=compiler-rt -fuse-ld=lld \\
  -Wno-unknown-warning-option "\${args[@]}"
EOF
  fi
  chmod +x "$out"
}

# print_summary: what the current configuration resolved to.
print_summary() {
  cat >&2 <<EOF

  ANDROIDJBR_HOME = $ANDROIDJBR_HOME
  WORK            = $WORK
  OUT             = $OUT
  JBR line        = $JBR_LINE (branch $JBR_BRANCH @ $JBR_PIN, boot JDK $BOOT_JDK_VERSION)
  patch series    = $PATCH_SERIES
  JBR_SRC         = $JBR_SRC
  NDK             = $NDK
  BOOT_JDK        = $BOOT_JDK
  FREETYPE        = $FREETYPE_PREFIX
  target          = $ANDROID_TARGET$ANDROID_API ($TARGET_JDK/$JVM_VARIANTS/$DEBUG_LEVEL)
  jobs            = $JOBS

EOF
}
