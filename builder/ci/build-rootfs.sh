#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
version="${1:-edge}"
work_root="$ROOT/.work/ci-image-$version"
output_root="$work_root/output"
image_tag="${OMARCHY_CI_IMAGE_TAG:-omarchy-android-ci:${version}}"
oci_record="$(awk -F '|' '$1 == "archlinuxarm" { print; found=1; exit } END { if (!found) exit 1 }' "$ROOT/manifest/oci-images.lock")"
IFS='|' read -r _ base_repository base_tag base_manifest base_layer <<<"$oci_record"
base_image="$base_repository:$base_tag"
pinned_base_image="$base_repository@$base_manifest"
container_name="omarchy-android-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}"
container_started=0
image_built=0

[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid image version: %s\n' "$version" >&2
  exit 2
}
for command_name in docker sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done
[[ ! -e "$work_root" ]] || {
  printf 'Refusing to replace existing CI work directory: %s\n' "$work_root" >&2
  exit 1
}

cleanup() {
  if (( container_started == 1 )); then
    docker rm --force "$container_name" >/dev/null 2>&1 || true
  fi
  if (( image_built == 1 )); then
    docker rmi --force "$image_tag" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$ROOT/scripts/validate.sh"
printf 'Locked Arch Linux ARM base: %s (primary layer %s)\n' \
  "$pinned_base_image" "$base_layer"

# Pull the base image and verify the resolved manifest matches the lock before
# it can be used as a build stage. This protects against a stale or swapped tag.
# --platform forces the arm64 variant on multi-arch manifests because GitHub's
# arm64 runner still pulls amd64 by default.
docker pull --platform linux/arm64 "$base_image"
if ! docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$base_image" |
    grep -qxF "$pinned_base_image"; then
  printf 'Arch Linux ARM base does not match locked manifest %s\n' "$base_manifest" >&2
  exit 1
fi

mkdir -p "$work_root"

# The Dockerfile is reproducible from the project root alone. Build with the
# pinned base as the FROM line so a swapped tag cannot introduce a different
# compiler toolchain.
docker build \
  --pull=false \
  --platform linux/arm64 \
  --tag "$image_tag" \
  --build-arg "ARCHLINUXARM_BASE=$pinned_base_image" \
  --build-arg "OMARCHY_VERSION=$version" \
  --label "org.opencontainers.image.title=Omarchy Android" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
  --file "$ROOT/builder/ci/Dockerfile.release" \
  "$ROOT"
image_built=1

# Record the produced image's manifest digest and config digest so the
# installer can pin the exact bytes of this build. After `docker build` but
# before `docker push`, RepoDigests is empty, so prefer the local image Id and
# fall back to RepoDigests[0] once available.
manifest_digest="$(docker inspect --format '{{.Id}}' "$image_tag" \
  | sed -e 's/^sha256://')"
if [[ -z "$manifest_digest" ]]; then
  manifest_digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$image_tag" \
    | sed -e 's/^[^@]*@//')"
fi
config_digest="$manifest_digest"
image_size="$(docker inspect --format '{{.Size}}' "$image_tag")"
created="$(docker inspect --format '{{.Created}}' "$image_tag")"

mkdir -p "$output_root"
package_inventory="$output_root/packages-aarch64-$version.lock"

# Run `pacman -Q` inside the built image so the published package inventory
# describes exactly what shipped, not what the disposable base provided. We
# start a throwaway container because the image has no pre-existing entry
# point we want to invoke and we want full control over cleanup.
docker create --name "$container_name" "$image_tag" /bin/true >/dev/null
container_started=1
docker start "$container_name" >/dev/null
docker exec "$container_name" /bin/sh -c 'pacman -Q | LC_ALL=C sort' \
  > "$package_inventory"
docker stop "$container_name" >/dev/null
docker rm --force "$container_name" >/dev/null
container_started=0

# Enforce the same package-closure contract as the phone release builder.
if [[ -n "${OMARCHY_PACKAGES_LOCK:-}" ]]; then
  [[ "$OMARCHY_PACKAGES_LOCK" == /* && -f "$OMARCHY_PACKAGES_LOCK" ]] || {
    printf 'OMARCHY_PACKAGES_LOCK is not an absolute file: %s\n' "$OMARCHY_PACKAGES_LOCK" >&2
    exit 2
  }
  expected_inventory_sha256="$(sha256sum "$OMARCHY_PACKAGES_LOCK" | awk '{print $1}')"
  actual_inventory_sha256="$(sha256sum "$package_inventory" | awk '{print $1}')"
  if [[ "$actual_inventory_sha256" != "$expected_inventory_sha256" ]]; then
    printf 'Release package closure does not match the pinned inventory.\n' >&2
    printf 'Expected SHA256: %s\nActual SHA256:   %s\n' \
      "$expected_inventory_sha256" "$actual_inventory_sha256" >&2
    exit 1
  fi
fi

# Re-run the privacy scrub assertions against the produced image so a bad
# build fails in CI rather than after release.
docker run --rm "$image_tag" /bin/sh -c '
  forbidden_path() {
    if [[ -e "$1" ]]; then
      printf "Refusing sensitive image path: %s\n" "$1" >&2
      exit 1
    fi
  }
  for p in \
    /root/.ssh /root/.gnupg /root/.bash_history \
    /home/omarchy/.ssh /home/omarchy/.gnupg /home/omarchy/.bash_history \
    /home/omarchy/.config/chromium/Default/History \
    /home/omarchy/.config/chromium/Default/Cookies \
    /home/omarchy/.config/chromium/Default/Login\ Data \
    /home/omarchy/.config/chromium/Default/Web\ Data; do
    forbidden_path "$p"
  done
  [[ ! -s /etc/machine-id ]] || { echo "Refusing nonempty image machine identity." >&2; exit 1; }
  ! find /var/cache/pacman/pkg /var/log -type f -print -quit 2>/dev/null | grep -q .
  test -f /etc/omarchy-android-release
  test -x /opt/omarchy-android/hyprland/bin/Hyprland
  test -f /home/omarchy/.config/hypr/hyprland.lua
  test -f /home/omarchy/.config/omarchy/proot-session-bus.conf
  test -x /usr/local/bin/omarchy-dbus-service
  test -x /usr/local/bin/omarchy-voxtype-daemon
  test -x /usr/local/bin/voxtype
  command -v quickshell
  command -v chromium
  command -v nautilus
  command -v foot
  command -v uwsm-app
  command -v omarchy-launch-shell
  locale -a | grep -Fxi "C.utf8"
'

oci_reference="${OMARCHY_CI_OCI_REFERENCE:-ghcr.io/${GITHUB_REPOSITORY:-btwiuse/omarchy-android}:$version}"
oci_repository="${oci_reference%:*}"

cat > "$output_root/IMAGE-MANIFEST" <<EOF
format=2
version=$version
architecture=aarch64
oci_repository=$oci_repository
oci_reference=$oci_reference
oci_manifest_digest=$manifest_digest
oci_config_digest=sha256:$config_digest
oci_size_bytes=$image_size
oci_created=$created
base_repository=$base_repository
base_tag=$base_tag
base_manifest=$base_manifest
base_layer=$base_layer
EOF
chmod 0644 "$output_root/IMAGE-MANIFEST"

# Save the produced image to a standard OCI image-layout tarball so the
# publish job can verify it offline and so on-device Termux installs can
# consume the same artifact without re-pulling from a registry.
image_tar="$output_root/omarchy-android-image-aarch64-$version.oci.tar"
docker save --output "$image_tar" "$image_tag"

components_lock_sha256=$(sha256sum "$ROOT/manifest/components.lock" | awk '{print $1}')
patches_lock_sha256=$(sha256sum "$ROOT/manifest/patches.lock" | awk '{print $1}')
artifacts_lock_sha256=$(sha256sum "$ROOT/manifest/artifacts.lock" | awk '{print $1}')
packages_lock_sha256=$(sha256sum "$package_inventory" | awk '{print $1}')
host_artifacts_lock_sha256=$(sha256sum "$ROOT/manifest/host-artifacts.lock" | awk '{print $1}')
image_tar_sha256=$(sha256sum "$image_tar" | awk '{print $1}')

cat > "$output_root/SHA256SUMS" <<EOF
$(printf '%s  %s\n' "$image_tar_sha256" "$(basename -- "$image_tar")")
$(printf '%s  %s\n' "$packages_lock_sha256" "$(basename -- "$package_inventory")")
$(printf '%s  IMAGE-MANIFEST\n' "$(sha256sum "$output_root/IMAGE-MANIFEST" | awk '{print $1}')")
$(printf '%s  components.lock\n' "$components_lock_sha256")
$(printf '%s  patches.lock\n' "$patches_lock_sha256")
$(printf '%s  artifacts.lock\n' "$artifacts_lock_sha256")
$(printf '%s  host-artifacts.lock\n' "$host_artifacts_lock_sha256")
EOF

(
  cd "$output_root"
  sha256sum -c SHA256SUMS
)

printf 'OCI image output: %s\n' "$output_root"
printf 'Image digest:     %s\n' "$manifest_digest"
