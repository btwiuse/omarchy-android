#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder_name="${OMARCHY_BUILDER_NAME:-omarchy-android-builder}"
builder_image=ghcr.io/btwiuse/arch:base-aarch64
container_root="${PREFIX:?Run this script from Termux}/var/lib/proot-distro/containers/$builder_name/rootfs"
container_manifest="${container_root%/rootfs}/manifest.json"
packages_file="$ROOT/builder/guest/packages.txt"
base_layer_digest=aee0640ab6ce7bb71b664767952402cfcde39df5402d5d691c494e72a8eb174f

command -v proot-distro >/dev/null || {
  printf 'Missing proot-distro. Install it with: pkg install proot-distro\n' >&2
  exit 1
}
[[ "$(uname -m)" == aarch64 ]] || {
  printf 'The clean builder currently supports native ARM64 Android only.\n' >&2
  exit 1
}

if [[ ! -d "$container_root" ]]; then
  printf 'Creating disposable Arch Linux ARM builder %s...\n' "$builder_name"
  proot-distro install --name "$builder_name" --architecture aarch64 "$builder_image"
else
  printf 'Reusing existing builder %s.\n' "$builder_name"
fi

if ! grep -qF '"image_ref": "ghcr.io/btwiuse/arch:base-aarch64"' "$container_manifest" ||
   ! grep -qF "sha256:$base_layer_digest" "$container_manifest"; then
    printf 'Builder base image does not match the locked Arch Linux ARM layer.\n' >&2
    exit 1
fi

pacman_conf="$container_root/etc/pacman.conf"
[[ -f "$pacman_conf" ]] || {
  printf 'Builder has no pacman.conf: %s\n' "$pacman_conf" >&2
  exit 1
}

# Pacman 7 download isolation depends on kernel features unavailable through
# PRoot. Limit concurrency and disable only those nested pacman sandboxes; the
# entire builder remains isolated by PRoot and is disposable.
if grep -q '^ParallelDownloads' "$pacman_conf"; then
  sed -i 's/^ParallelDownloads.*/ParallelDownloads = 1/' "$pacman_conf"
fi
proot-distro login "$builder_name" -- /mnt/project/builder/ci/prepare-pacman-conf.sh /etc/pacman.conf \
  || { printf 'prepare-pacman-conf.sh failed inside %s.\n' "$builder_name" >&2; exit 1; }

printf 'Updating the disposable builder...\n'
proot-distro login "$builder_name" -- pacman -Syu --noconfirm

printf 'Installing %d pinned build dependency names...\n' \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$packages_file")"
proot-distro login "$builder_name" -- \
  /mnt/project/builder/ci/install-pkg-list.sh "/mnt/project/$packages_file"

printf 'Builder %s is ready.\n' "$builder_name"
