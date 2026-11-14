#!/usr/bin/env bash
# AndroidJBR — step 1/5: get JetBrainsRuntime at the pinned commit.
#
# Shallow, blob-less clone: only the pinned tree is fetched, which keeps the
# checkout in the few-hundred-MB range instead of the full JBR history.
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

need_cmd git
print_summary

if [ -d "$JBR_SRC/.git" ]; then
  have=$(git -C "$JBR_SRC" rev-parse HEAD 2>/dev/null || true)
  if [ "$have" = "$JBR_PIN" ]; then
    info "JBR already cloned at $JBR_PIN"
    exit 0
  fi
  die "$JBR_SRC exists but is at ${have:-<unknown>}, expected $JBR_PIN.
  Remove it (rm -rf \"$JBR_SRC\") or set JBR_SRC to a fresh path."
fi

mkdir -p "$(dirname "$JBR_SRC")"
info "fetching JetBrainsRuntime ${JBR_BRANCH} @ ${JBR_PIN:0:12}"
git init --quiet "$JBR_SRC"
git -C "$JBR_SRC" remote add origin "$JBR_REPO"
if ! git -C "$JBR_SRC" fetch --quiet --depth 1 origin "$JBR_PIN"; then
  warn "direct commit fetch was refused; falling back to a filtered branch fetch"
  git -C "$JBR_SRC" fetch --quiet --filter=blob:none origin "$JBR_BRANCH" \
    || { git -C "$JBR_SRC" remote remove origin; die "cannot fetch $JBR_REPO"; }
fi
git -C "$JBR_SRC" -c advice.detachedHead=false checkout --quiet FETCH_HEAD

have=$(git -C "$JBR_SRC" rev-parse HEAD)
[ "$have" = "$JBR_PIN" ] || die "checked out $have, expected $JBR_PIN"

# Full-checkout sanity: the port patch touches java.desktop and make/modules;
# if those are missing the clone is sparse/partial and the patch will not apply.
for f in make/modules/java.desktop/lib/Awt2dLibraries.gmk src/java.desktop/unix/native/libawt/awt/awt_LoadLibrary.c; do
  [ -f "$JBR_SRC/$f" ] || die "incomplete checkout, missing $f"
done

info "JBR source ready: $JBR_SRC"
info "next: ./scripts/02-apply-patches.sh"
