#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder_name="${OMARCHY_RELEASE_BUILDER_NAME:-omarchy-android-release-builder}"
builder_image=ghcr.io/btwiuse/arch:base-aarch64
container_root="${PREFIX:?Run this script from Termux}/var/lib/proot-distro/containers/$builder_name/rootfs"
container_manifest="${container_root%/rootfs}/manifest.json"
packages_file="$ROOT/builder/guest/runtime-packages.txt"
base_layer_digest=aee0640ab6ce7bb71b664767952402cfcde39df5402d5d691c494e72a8eb174f

command -v proot-distro >/dev/null || {
  printf 'Missing proot-distro. Install it with: pkg install proot-distro\n' >&2
  exit 1
}
[[ "$(uname -m)" == aarch64 ]] || {
  printf 'Release images are built natively on ARM64 only.\n' >&2
  exit 1
}
if [[ -d "$container_root" ]]; then
  [[ -x "$container_root/usr/bin/bash" && -f "$container_root/etc/pacman.conf" ]] || {
    printf 'Existing release builder is incomplete: %s\n' "$container_root" >&2
    exit 1
  }
  [[ ! -e "$container_root/etc/omarchy-android-release" ]] || {
    printf 'Existing release builder was already assembled; use a new builder name.\n' >&2
    exit 1
  }
  if grep -q '^omarchy:' "$container_root/etc/passwd"; then
    printf 'Existing release builder contains a partially assembled user; use a new builder name.\n' >&2
    exit 1
  fi
  printf 'Resuming clean release builder %s.\n' "$builder_name"
else
  printf 'Creating clean Arch Linux ARM release builder %s...\n' "$builder_name"
  proot-distro install --name "$builder_name" --architecture aarch64 "$builder_image"
fi

if ! grep -qF '"image_ref": "ghcr.io/btwiuse/arch:base-aarch64"' "$container_manifest" ||
   ! grep -qF "sha256:$base_layer_digest" "$container_manifest"; then
    printf 'Release builder base image does not match the locked Arch Linux ARM layer.\n' >&2
    exit 1
fi

pacman_conf="$container_root/etc/pacman.conf"
[[ -f "$pacman_conf" ]] || {
  printf 'Builder has no pacman.conf: %s\n' "$pacman_conf" >&2
  exit 1
}

if grep -q '^ParallelDownloads' "$pacman_conf"; then
  sed -i 's/^ParallelDownloads.*/ParallelDownloads = 1/' "$pacman_conf"
fi
proot-distro login "$builder_name" -- /mnt/project/builder/ci/prepare-pacman-conf.sh /etc/pacman.conf \
  || { printf 'prepare-pacman-conf.sh failed inside %s.\n' "$builder_name" >&2; exit 1; }

proot-distro login "$builder_name" -- pacman -Syu --noconfirm
proot-distro login "$builder_name" -- \
  /mnt/project/builder/ci/install-pkg-list.sh "/mnt/project/$packages_file"
proot-distro login \
  --isolated \
  --bind "$ROOT:/mnt/project" \
  "$builder_name" -- \
  /mnt/project/builder/guest/prune-release-packages.sh \
    /mnt/project/builder/guest/runtime-packages.txt
printf 'Release builder %s is ready.\n' "$builder_name"
