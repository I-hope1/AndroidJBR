#!/usr/bin/env bash
# AndroidJBR — verify that patches/series applies cleanly to the pinned JBR
# tree, without downloading or building the whole JDK.
#
#   ./scripts/check-patch.sh              # temporary checkout, auto-removed
#   ./scripts/check-patch.sh --keep       # keep it for poking around
#
# How it stays cheap: a blob-less partial clone fetches only commit/tree objects
# and then a non-cone sparse checkout materialises just the files the patches
# touch (44 files, ~15 MB on disk).  The series is first dry-run with
# `git apply --check`, then actually applied so overlapping patches are caught.
#
# Exit status: 0 = every patch applies cleanly, 1 = failure (details on stderr).
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

PATCH_DIR="$ANDROIDJBR_HOME/patches"
SERIES="$PATCH_DIR/series"
keep=0
[ "${1:-}" = "--keep" ] && keep=1

need_cmd git
need_file "$SERIES"

patch_files=()
while IFS= read -r line; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | xargs)
  [ -n "$line" ] || continue
  p="$PATCH_DIR/$line"
  need_file "$p" "listed in patches/series"
  patch_files+=("$p")
done < "$SERIES"
[ "${#patch_files[@]}" -gt 0 ] || die "patches/series is empty"

# Every file any patch touches, deduplicated and sorted.
touched=$(mktemp)
trap 'rm -f "$touched"' EXIT
for p in "${patch_files[@]}"; do
  grep '^diff --git ' "$p" | sed -E 's#^diff --git a/(.*) b/.*#\1#'
done | sort -u > "$touched"
n_files=$(wc -l < "$touched")
info "${#patch_files[@]} patch(es), $n_files touched file(s), JBR pin ${JBR_PIN:0:12}"

chk=$(mktemp -d "${TMPDIR:-/tmp}/androidjbr-patch-check.XXXXXX")
cleanup() {
  if [ "$keep" -eq 1 ]; then
    info "checkout kept at $chk"
  else
    rm -rf "$chk"
  fi
}
trap cleanup EXIT

# --- fetch the pinned commit (blob-less) -------------------------------------
info "fetching JBR trees (blob-less shallow)"
git init --quiet "$chk"
git -C "$chk" remote add origin "$JBR_REPO"
if git -C "$chk" fetch --quiet --depth 1 --filter=blob:none origin "$JBR_PIN" 2>/dev/null; then
  :
else
  warn "direct commit fetch refused, fetching ${JBR_BRANCH} history without blobs"
  git -C "$chk" fetch --quiet --filter=blob:none origin "$JBR_BRANCH" \
    || die "cannot fetch $JBR_REPO"
fi
git -C "$chk" cat-file -e "${JBR_PIN}^{commit}" \
  || die "commit $JBR_PIN not present after fetch"

# --- materialise only the patched files -------------------------------------
info "sparse checkout of $n_files file(s)"
git -C "$chk" sparse-checkout init --no-cone
git -C "$chk" sparse-checkout set --no-cone --stdin < "$touched"
git -C "$chk" -c advice.detachedHead=false checkout --quiet "$JBR_PIN"

missing=0
while IFS= read -r f; do
  [ -e "$chk/$f" ] || { warn "not present in upstream tree: $f"; missing=$((missing + 1)); }
done < "$touched"
[ "$missing" -eq 0 ] || die "$missing patched path(s) do not exist in the pinned tree — patch/pin mismatch"

# --- dry-run, then apply -----------------------------------------------------
for p in "${patch_files[@]}"; do
  name=$(basename "$p")
  info "git apply --check $name"
  git -C "$chk" apply --check --whitespace=nowarn "$p" \
    || die "patch does not apply: $name (patch and JBR pin are out of sync)"
done
for p in "${patch_files[@]}"; do
  git -C "$chk" apply --whitespace=nowarn "$p" || die "apply failed: $(basename "$p")"
done

changed=$(git -C "$chk" diff --numstat | wc -l)
[ "$changed" -eq "$n_files" ] \
  || die "expected $n_files changed files after applying the series, got $changed"

info "OK — $n_files files changed"
git -C "$chk" diff --stat | tail -n 1
