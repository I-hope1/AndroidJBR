#!/usr/bin/env bash
# AndroidJBR — one-shot build driver: dependencies → toolchain → clone → patch
# → configure → build → package.
#
#   ./scripts/build.sh                     # full pipeline, JBR 21
#   ./scripts/build.sh --jbr 25            # JBR 25 (experimental track)
#   ./scripts/build.sh --skip-deps         # deps/toolchain already in $WORK
#   ./scripts/build.sh --jobs 4
#   ./scripts/build.sh --from 3            # resume at 03-configure.sh
#
# Stages are idempotent where possible: an existing JBR clone and an existing
# build directory are reused instead of being wiped (use --clean-build for
# `make clean images`; the JBR tree is only reset by 02 when it is dirty and
# still sitting exactly on the pin).
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# --jbr has to be known before env.sh is sourced, so pre-scan argv for it.
_jbr_opt=""
_prev=""
for _a in "$@"; do
  [ "$_prev" = "--jbr" ] && _jbr_opt="$_a"
  _prev="$_a"
done
export JBR_LINE=${_jbr_opt:-${JBR_LINE:-21}}
unset _jbr_opt _prev _a
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"
require_jbr_line

skip_deps=0
skip_toolchain=0
from_step=1
clean_build=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jbr)            shift ;;   # already applied via the pre-scan above
    --skip-deps)      skip_deps=1 ;;
    --skip-toolchain) skip_toolchain=1 ;;
    --clean-build)    clean_build=--clean ;;
    --from)           shift; from_step=${1:?-"--from needs a step number 1..5"} ;;
    --jobs)           shift; export JOBS=${1:?-"--jobs needs a number"} ;;
    -h|--help)
      awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
case "$from_step" in 1|2|3|4|5) ;; *) die "--from expects 1..5" ;; esac

print_summary
started=$(date +%s)
step() {
  local n=$1 name=$2
  shift 2
  if [ "$n" -lt "$from_step" ]; then
    info "step $n/5 ($name) skipped (--from $from_step)"
    return 0
  fi
  info "===== step $n/5: $name ====="
  "$@"
}

if [ "$skip_deps" -eq 0 ]; then
  info "===== step 0/5: fetch external inputs ====="
  "$_script_dir/fetch-deps.sh"
fi
if [ "$skip_toolchain" -eq 0 ]; then
  info "===== step 0/5: prepare toolchain ====="
  "$_script_dir/setup-toolchain.sh"
fi

step 1 "clone JetBrainsRuntime @ $JBR_PIN" "$_script_dir/01-clone-jbr.sh"
step 2 "apply patch series"              "$_script_dir/02-apply-patches.sh"
step 3 "configure (headless server, bionic aarch64)" "$_script_dir/03-configure.sh"
if [ -n "$clean_build" ]; then
  step 4 "build images (clean)" "$_script_dir/04-build.sh" --clean
else
  step 4 "build images"       "$_script_dir/04-build.sh"
fi
step 5 "package Pojav-compatible JRE" "$_script_dir/05-package-jre.sh"

info "pipeline finished in $(( $(date +%s) - started ))s"
ls -lh "$OUT"/*.tar.xz "$OUT"/SHA256SUMS.txt 2>/dev/null || true
