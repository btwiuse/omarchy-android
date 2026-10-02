#!/usr/bin/env bash
# Configure the omarchy git checkout so subsequent `git am` patches
# carry an identifiable author and the original patch timestamps.
#
# Usage: apply-omarchy-patches.sh [OMARCHY_DIR]
#   OMARCHY_DIR defaults to /opt/src/upstream/omarchy.

set -euo pipefail

omarchy_dir="${1:-/opt/src/upstream/omarchy}"
[[ -d "$omarchy_dir/.git" ]] || {
  printf 'omarchy checkout is missing: %s\n' "$omarchy_dir" >&2
  exit 1
}

git -C "$omarchy_dir" config user.name 'Omarchy Android Builder'
git -C "$omarchy_dir" config user.email 'builder@omarchy-android.invalid'
git -C "$omarchy_dir" am --committer-date-is-author-date /opt/src/patches/omarchy-shell/*.patch