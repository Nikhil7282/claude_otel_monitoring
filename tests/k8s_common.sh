# shellcheck shell=bash
# Shared by the Kubernetes tests. Source it; it defines functions only. The tests count
# failures in their own `failures` variable.

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# copy_repo DEST: the repo as git sees it (tracked and new, not ignored) into DEST, so the
# tests can add settings files without touching the working tree.
copy_repo() {
  local dest=$1 f
  git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [[ -e $f ]] || continue
    mkdir -p "$dest/$(dirname "$f")"
    cp "$f" "$dest/$f"
  done
}
