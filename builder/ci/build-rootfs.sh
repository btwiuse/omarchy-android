#!/usr/bin/env bash

# build-rootfs.sh: produce the published OCI base image for the Android
# release. Runs only in build-edge; the release workflow re-tags and
# re-uses the same image.
#
# Side effects:
#   - logs in (the caller already did `docker/login-action`).
#   - pulls the locked base image (btwiuse/arch) and verifies its digest.
#   - runs `docker build` with the project-root Dockerfile.
#   - pushes `:edge` plus a per-build `:edge-<sha>` to GHCR.
#   - leaves no working-directory or scratch files behind.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
version="${1:-edge}"
image_tag="${OMARCHY_CI_IMAGE_TAG:-omarchy-android-ci:${version}}"
oci_record="$(awk -F '|' '$1 == "archlinuxarm" { print; found=1; exit } END { if (!found) exit 1 }' \
  "$ROOT/manifest/oci-images.lock")"
IFS='|' read -r _ base_repository base_tag base_manifest base_layer <<<"$oci_record"
base_image="$base_repository:$base_tag"
pinned_base_image="$base_repository@$base_manifest"
image_built=0

[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid image version: %s\n' "$version" >&2
  exit 2
}
command -v docker >/dev/null 2>&1 || {
  printf 'Missing required command: docker\n' >&2
  exit 1
}

cleanup() {
  if (( image_built == 1 )); then
    docker rmi --force "$image_tag" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$ROOT/scripts/validate.sh"
printf 'Locked Arch Linux ARM base: %s (primary layer %s)\n' \
  "$pinned_base_image" "$base_layer"

# Pull the locked base and verify the resolved digest before we let
# buildkit touch it. The --platform flag prevents the daemon from picking
# the amd64 slice of a multi-arch image.
docker pull --platform linux/arm64 "$base_image"
if ! docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$base_image" |
    grep -qxF "$pinned_base_image"; then
  printf 'Arch Linux ARM base does not match locked manifest %s\n' "$base_manifest" >&2
  exit 1
fi

# Build the multi-stage image. The Dockerfile lives at builder/ci/Dockerfile.release
# and depends only on the project root as its build context.
docker build \
  --pull=false \
  --platform linux/arm64 \
  --tag "$image_tag" \
  --build-arg "ARCHLINUXARM_BASE=$pinned_base_image" \
  --build-arg "OMARCHY_VERSION=$version" \
  --label "org.opencontainers.image.title=Omarchy Android" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-btwiuse/omarchy-android}" \
  --file "$ROOT/builder/ci/Dockerfile.release" \
  "$ROOT"
image_built=1

# Floating ':edge' tag — every successful build overwrites it.
edge_reference="${OMARCHY_CI_EDGE_REFERENCE:-ghcr.io/${GITHUB_REPOSITORY:-btwiuse/omarchy-android}:edge}"
docker tag "$image_tag" "$edge_reference"
docker push "$edge_reference"

# Pinned-per-build tag so consumers can pin a specific commit if needed.
pinned_reference="ghcr.io/${GITHUB_REPOSITORY:-btwiuse/omarchy-android}:${version}"
docker tag "$image_tag" "$pinned_reference"
docker push "$pinned_reference"

manifest_digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$edge_reference" | sed -e 's|^[^@]*@||')"
printf 'Pushed %s@%s\n' "$edge_reference" "$manifest_digest"