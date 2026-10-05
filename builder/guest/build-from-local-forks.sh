#!/usr/bin/env bash

set -Eeuo pipefail

project_root="${1:-/mnt/project}"
forks_root="${2:-/mnt/forks}"
artifact_root="${3:-/mnt/output/graphics}"
source_root="${4:-/var/tmp/omarchy-android-sources}"
build_root="${5:-/var/tmp/omarchy-android-build}"

for path in "$project_root" "$forks_root" "$artifact_root" "$source_root" "$build_root"; do
  [[ "$path" == /* ]] || {
    printf 'All paths must be absolute: %s\n' "$path" >&2
    exit 2
  }
done
[[ -f "$project_root/manifest/components.lock" ]] || {
  printf 'Invalid project checkout: %s\n' "$project_root" >&2
  exit 1
}
for component in mesa aquamarine hyprland; do
  [[ -d "$forks_root/$component/.git" ]] || {
    printf 'Missing local fork: %s\n' "$forks_root/$component" >&2
    exit 1
  }
done
for path in "$artifact_root" "$source_root" "$build_root"; do
  [[ ! -e "$path" ]] || {
    printf 'Refusing to reuse clean-build path: %s\n' "$path" >&2
    exit 1
  }
done

revision_for() {
  local component="$1"
  awk -F '|' -v component="$component" '$1 == component { print $4; found=1; exit } END { if (!found) exit 1 }' \
    "$project_root/manifest/components.lock"
}

clone_at_revision() {
  local component="$1"
  local revision
  revision="$(revision_for "$component")"
  git clone --no-hardlinks --no-checkout "$forks_root/$component" "$source_root/$component"
  git -C "$source_root/$component" checkout --detach "$revision"
}

mkdir -p "$source_root"
clone_at_revision mesa
clone_at_revision aquamarine
clone_at_revision hyprland

# Hyprland pins its submodules (hyprland-protocols, tracy, udis86) via
# gitlink entries in its own tree object; `submodule update --init
# --recursive` materializes them at the commits Hyprland was built
# against. The lock file previously duplicated those SHAs and rejected
# any fork bump, so it has been removed: trust the fork's pinned state.
git -C "$source_root/hyprland" submodule update --init --recursive
# Glaze is fetched by Hyprland's CMakeLists.txt as FetchContent at tag
# v7.2.0 (commit b518eec7a22e56ffa238b072c07f47efa7cea97f). build-graphics.sh
# verifies the resolved FetchContent checkout matches this SHA.
export OMARCHY_GLAZE_REVISION="b518eec7a22e56ffa238b072c07f47efa7cea97f"

"$project_root/builder/guest/build-graphics.sh" \
  "$source_root/mesa" \
  "$source_root/aquamarine" \
  "$source_root/hyprland" \
  "$artifact_root" \
  "$build_root"
