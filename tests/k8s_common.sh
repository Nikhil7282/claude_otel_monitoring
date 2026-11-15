# shellcheck shell=bash
# Shared by the Kubernetes tests. Source it; it defines functions only.

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
