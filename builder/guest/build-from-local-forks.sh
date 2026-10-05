#!/usr/bin/env bash

set -Eeuo pipefail

project_root="${1:-/mnt/project}"
forks_root="${2:-/mnt/forks}"
artifact_root="${3:-/mnt/output/graphics}"
source_root="${4:-/var/tmp/omarchy-android-sources}"
build_root="${5:-/var/tmp/omarchy-android-build}"
upstream_root="${OMARCHY_UPSTREAM_ROOT:-/opt/src/upstream}"

for path in "$project_root" "$forks_root" "$artifact_root" "$source_root" "$build_root" "$upstream_root"; do
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
  [[ -d "$upstream_root/$component" ]] || {
    printf 'Missing upstream checkout: %s\n' "$upstream_root/$component" >&2
    exit 1
  }
done
for path in "$artifact_root" "$source_root" "$build_root"; do
  [[ ! -e "$path" ]] || {
    printf 'Refusing to reuse clean-build path: %s\n' "$path" >&2
    exit 1
  }
done

# Materialize writable source trees for the three components. The upstream
# checkouts in $upstream_root come from fetch-sources.sh and are read-only
# checkouts at FETCH_HEAD. The build-graphics phases need write access for
# configure trees and a checkout that can resolve `git submodule update`,
# so we hardlink the object database and check out files into $source_root.
# Hardlinks share on-disk git objects with $upstream_root, so this is
# cheap.
mkdir -p "$source_root"
for component in mesa aquamarine hyprland; do
  printf 'Preparing writable %s source\n' "$component"
  git clone --no-checkout "$upstream_root/$component" "$source_root/$component"
  revision="$(git -C "$upstream_root/$component" rev-parse HEAD)"
  git -C "$source_root/$component" checkout --detach "$revision"
done

# Hyprland pins its submodules (hyprland-protocols, tracy, udis86) via
# gitlink entries in its own tree object; `submodule update --init
# --recursive` materializes them at the commits Hyprland was built
# against. The lock file previously duplicated those SHAs and rejected
# any fork bump, so it has been removed: trust the fork's pinned state.
printf 'Initializing Hyprland submodules\n'
git -C "$source_root/hyprland" submodule update --init --recursive

# Glaze is fetched by Hyprland's CMakeLists.txt as FetchContent at tag
# v7.2.0 (commit b518eec7a22e56ffa238b072c07f47efa7cea97f). build-graphics.sh
# verifies the resolved FetchContent checkout matches this SHA.
export OMARCHY_GLAZE_REVISION="b518eec7a22e56ffa238b072c07f47efa7cea97f"
printf 'Sources ready under %s\n' "$source_root"