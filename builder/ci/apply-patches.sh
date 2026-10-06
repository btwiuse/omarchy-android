#!/usr/bin/env bash

# Apply the patches/ tree on top of the upstream checkouts materialized
# under $OMARCHY_UPSTREAM_ROOT. Each entry in manifest/patches.lock pins
# the base revision the patch was generated against; refuse to apply
# the patch if the working tree's HEAD does not match.
#
# The patch file is verified against the sha256 recorded in patches.lock
# so a stale patch cannot be silently applied on top of an unrelated
# revision.

set -Eeuo pipefail

project_root="${1:-/opt/src}"
upstream_root="${2:-/opt/src/upstream}"

[[ -f "$project_root/manifest/patches.lock" ]] || {
  printf 'Missing patches.lock: %s\n' "$project_root/manifest/patches.lock" >&2
  exit 1
}
[[ -d "$upstream_root" ]] || {
  printf 'Missing upstream root: %s\n' "$upstream_root" >&2
  exit 1
}

while IFS='|' read -r component base_revision patch_path expected_sha256 _; do
  [[ -z "$component" || "$component" == \#* ]] && continue
  upstream_dir="$upstream_root/$component"
  [[ -d "$upstream_dir/.git" || -d "$upstream_dir" ]] || {
    printf 'Skipping %s: upstream dir %s not present\n' "$component" "$upstream_dir"
    continue
  }
  current_revision="$(git -C "$upstream_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$current_revision" ]]; then
    printf 'Skipping %s: no HEAD in %s\n' "$component" "$upstream_dir"
    continue
  fi
  if [[ "${current_revision:0:40}" != "${base_revision:0:40}" ]]; then
    printf 'Skipping %s: HEAD %s does not match patch base %s\n' \
      "$component" "$current_revision" "$base_revision"
    continue
  fi
  full_patch="$project_root/$patch_path"
  [[ -f "$full_patch" ]] || {
    printf 'Missing patch file: %s\n' "$full_patch" >&2
    exit 1
  }
  actual_sha256="$(sha256sum "$full_patch" | awk '{print $1}')"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    printf 'Patch sha256 mismatch for %s: expected %s got %s\n' \
      "$component" "$expected_sha256" "$actual_sha256" >&2
    exit 1
  }
  printf 'Applying %s to %s\n' "$patch_path" "$component"
  git -C "$upstream_dir" apply --3way --whitespace=nowarn "$full_patch"
done < "$project_root/manifest/patches.lock"
