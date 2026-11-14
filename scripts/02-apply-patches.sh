#!/usr/bin/env bash
# AndroidJBR — step 2/5: apply patches/series on top of the pinned JBR tree.
#
# The series is applied with `git apply`; every patch must apply cleanly and is
# checked before it is allowed to touch the tree.  When the series is applied
# the result is committed locally, which makes `git diff <pin>` the canonical
# way to regenerate the patch after an edit (see patches/README.md).
set -euo pipefail

_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$_script_dir/env.sh"
# shellcheck source=lib.sh
source "$_script_dir/lib.sh"

PATCH_DIR="$ANDROIDJBR_HOME/patches"
SERIES="$PATCH_DIR/series"

need_cmd git
need_dir "$JBR_SRC/.git" "run ./scripts/01-clone-jbr.sh first"
need_file "$SERIES"
mkdir -p "$WORK"

# Give the checkout a local identity so committing the applied series does not
# depend on the user's global git config.
git -C "$JBR_SRC" config user.name "AndroidJBR" >/dev/null 2>&1 || true
git -C "$JBR_SRC" config user.email "androidjbr@localhost" >/dev/null 2>&1 || true

if ! git -C "$JBR_SRC" check-ignore -q dummy_libs 2>/dev/null; then
  printf 'dummy_libs/\n' >> "$JBR_SRC/.git/info/exclude"
fi

head=$(git -C "$JBR_SRC" rev-parse HEAD)
if [ "$head" != "$JBR_PIN" ]; then
  # The series was already committed by an earlier run; only re-apply when the
  # caller reset the tree themselves.
  if git -C "$JBR_SRC" diff --quiet "$JBR_PIN" -- 2>/dev/null; then
    info "tree already carries the patch series ($(git -C "$JBR_SRC" log --oneline -1))"
  else
    warn "HEAD is ${head:0:12}, not the pin; applying series on top as-is"
  fi
else
  if [ -n "$(git -C "$JBR_SRC" status --porcelain)" ]; then
    warn "resetting dirty JBR tree to the pin"
    git -C "$JBR_SRC" reset --hard --quiet "$JBR_PIN"
    git -C "$JBR_SRC" clean -fdq
  fi
fi

count=0
while IFS= read -r line; do
  line=${line%%#*}
  line=$(printf '%s' "$line" | xargs)
  [ -n "$line" ] || continue
  patch="$PATCH_DIR/$line"
  need_file "$patch" "listed in patches/series"

  if git -C "$JBR_SRC" apply --reverse --check --whitespace=nowarn "$patch" 2>/dev/null; then
    info "already applied: $line"
    continue
  fi
  info "checking $line"
  if ! git -C "$JBR_SRC" apply --check --whitespace=nowarn "$patch" 2>"$WORK/apply-error.log"; then
    cat "$WORK/apply-error.log" >&2
    die "patch does not apply cleanly: $line
  The JBR pin (${JBR_PIN:0:12}) and the patch must stay in sync.  Re-generate the
  patch against the pin or adjust JBR_PIN, see patches/README.md."
  fi
  info "applying $line"
  git -C "$JBR_SRC" apply --whitespace=nowarn "$patch" \
    || die "git apply failed: $line"
  count=$((count + 1))
done < "$SERIES"

# --- build-tree scaffolding the OpenJDK build expects ------------------------
# Empty archives for libraries bionic does not provide; configure's -L path
# resolves -lpthread/-lrt/-lthread_db against these instead of failing.
mkdir -p "$DUMMY_LIBS"
for lib in libpthread.a librt.a libthread_db.a; do
  [ -f "$DUMMY_LIBS/$lib" ] || printf '!<arch>\n' > "$DUMMY_LIBS/$lib"
done

# --- commit the result so "git diff PIN" is meaningful ----------------------
if [ -n "$(git -C "$JBR_SRC" status --porcelain)" ]; then
  git -C "$JBR_SRC" add -A
  git -C "$JBR_SRC" commit --quiet \
    -m "AndroidJBR: apply patch series on ${JBR_PIN:0:12} (${count} applied this run)"
fi

info "patched tree: $(git -C "$JBR_SRC" diff --stat "$JBR_PIN" | tail -1)"
info "next: ./scripts/03-configure.sh"
