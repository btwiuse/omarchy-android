#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
version="${1:-$(date -u +%Y%m%d)}"
output_dir="${2:-$ROOT/.work/releases}"
graphics_root="$ROOT/.work/guest-artifacts/graphics"
weston_root="$ROOT/.work/artifact-test/host-weston"
release_work="$ROOT/.work/release-$version"
image_tag="${OMARCHY_LOCAL_IMAGE_TAG:-omarchy-android-local:${version}}"
image_tar="$output_dir/omarchy-android-image-aarch64-$version.oci.tar"
host_bundle="$output_dir/omarchy-android-host-aarch64-$version.tar.xz"
packages_lock="$ROOT/manifest/packages-aarch64-$version.lock"
oci_record="$(awk -F '|' '$1 == "archlinuxarm" { print; found=1; exit } END { if (!found) exit 1 }' "$ROOT/manifest/oci-images.lock")"
IFS='|' read -r _ base_repository base_tag base_manifest base_layer <<<"$oci_record"
pinned_base_image="$base_repository@$base_manifest"

[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid release version: %s\n' "$version" >&2
  exit 2
}
for required in \
  "$graphics_root/SHA256SUMS" \
  "$weston_root/lib/libweston-14/x11-backend.so" \
  "$packages_lock" \
  "$ROOT/licenses/weston-COPYING" \
  "$ROOT/builder/ci/Dockerfile.release"; do
  [[ -f "$required" ]] || {
    printf 'Missing clean build artifact: %s\n' "$required" >&2
    exit 1
  }
done
command -v proot-distro >/dev/null 2>&1 || {
  printf 'proot-distro is required for on-device OCI builds.\n' >&2
  exit 1
}
[[ ! -e "$image_tar" && ! -e "$host_bundle" && ! -e "$host_bundle.sha256" ]] || {
  printf 'Refusing to overwrite completed release output for %s.\n' "$version" >&2
  exit 1
}

"$ROOT/scripts/validate.sh"

# Build the OCI image directly with proot-distro build using the same
# Dockerfile CI uses. proot-distro installs and runs proot under the hood, so
# the build does not need root or a Docker daemon on the phone.
proot-distro build \
  --tag "$image_tag" \
  --architecture aarch64 \
  --build-arg "ARCHLINUXARM_BASE=$pinned_base_image" \
  --build-arg "OMARCHY_VERSION=$version" \
  --output "$image_tar" \
  --file "$ROOT/builder/ci/Dockerfile.release" \
  "$ROOT"

# proot-distro build emits an OCI image-layout tarball. Re-export it through
# `proot-distro list --image` to capture the published manifest digest for the
# local release record.
image_id="$(proot-distro list --image --quiet | awk -v t="$image_tag" '$1 == t { print $2; exit }')"
[[ -n "$image_id" ]] || {
  printf 'Built image %s is missing from the local manifest cache.\n' "$image_tag" >&2
  exit 1
}
image_tar_sha256="$(sha256sum "$image_tar" | awk '{print $1}')"

# Build the host payload archive from the artifacts we just verified.
host_temporary="$release_work/host-bootstrap"
mkdir -p "$host_temporary"
cleanup() {
  if [[ -d "$host_temporary" && "$host_temporary" == "$ROOT"/.work/release-* ]]; then
    find "$host_temporary" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

install -d -m 0755 \
  "$host_temporary/host/bin" \
  "$host_temporary/host/opt/weston/lib/libweston-14" \
  "$host_temporary/host/share/licenses/omarchy-android" \
  "$host_temporary/host/share/licenses/weston" \
  "$host_temporary/manifest"
install -m 0644 "$ROOT/LICENSE" \
  "$host_temporary/host/share/licenses/omarchy-android/LICENSE"
install -m 0644 "$ROOT/licenses/weston-COPYING" \
  "$host_temporary/host/share/licenses/weston/COPYING"
install -m 0755 "$weston_root/lib/libweston-14/x11-backend.so" \
  "$host_temporary/host/opt/weston/lib/libweston-14/x11-backend.so"
"$ROOT/runtime/host/build-helpers.sh" "$host_temporary/host/bin"
install -m 0644 "$packages_lock" \
  "$host_temporary/manifest/$(basename -- "$packages_lock")"

for elf in \
  "$host_temporary/host/bin/omarchy-process-guard" \
  "$host_temporary/host/bin/omarchy-x11-keyboard" \
  "$host_temporary/host/opt/weston/lib/libweston-14/x11-backend.so"; do
  machine="$(od -An -tx1 -j18 -N2 "$elf" | tr -d '[:space:]')"
  [[ "$machine" == b700 ]] || {
    printf 'Host artifact is not AArch64: %s\n' "$elf" >&2
    exit 1
  }
done

patches_lock_sha256="$(sha256sum "$ROOT/manifest/patches.lock" | awk '{print $1}')"
components_lock_sha256="$(sha256sum "$ROOT/manifest/components.lock" | awk '{print $1}')"
packages_lock_sha256="$(sha256sum "$packages_lock" | awk '{print $1}')"
artifacts_lock_sha256="$(sha256sum "$ROOT/manifest/artifacts.lock" | awk '{print $1}')"
cat > "$host_temporary/BUNDLE-MANIFEST" <<EOF
format=2
version=$version
architecture=aarch64
oci_reference=$image_tag
oci_repository=local
oci_manifest_digest=$image_id
base_repository=$base_repository
base_tag=$base_tag
base_manifest=$base_manifest
base_layer=$base_layer
components_lock_sha256=$components_lock_sha256
patches_lock_sha256=$patches_lock_sha256
artifacts_lock_sha256=$artifacts_lock_sha256
packages_lock_sha256=$packages_lock_sha256
host_source_bundle_sha256=$image_tar_sha256
EOF
chmod 0644 "$host_temporary/BUNDLE-MANIFEST"

(
  cd "$host_temporary"
  find ./host ./manifest -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum BUNDLE-MANIFEST >> SHA256SUMS
  sha256sum -c SHA256SUMS
)

mkdir -p "$output_dir"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -C "$host_temporary" -cJf "$host_bundle.partial" .
mv "$host_bundle.partial" "$host_bundle"
host_bundle_sha256="$(sha256sum "$host_bundle" | awk '{print $1}')"
(
  cd "$output_dir"
  asset="$(basename -- "$host_bundle")"
  sha256sum "$asset" > "$asset.sha256"
)
chmod 0644 "$host_bundle" "$host_bundle.sha256"

cat > "$release_work/IMAGE-MANIFEST" <<EOF
format=2
version=$version
architecture=aarch64
oci_repository=local
oci_reference=$image_tag
oci_manifest_digest=$image_id
oci_size_bytes=$(stat -c %s "$image_tar" 2>/dev/null || stat -f %z "$image_tar")
base_repository=$base_repository
base_tag=$base_tag
base_manifest=$base_manifest
base_layer=$base_layer
host_bundle_asset=$(basename -- "$host_bundle")
host_bundle_sha256=$host_bundle_sha256
EOF
chmod 0644 "$release_work/IMAGE-MANIFEST"

printf 'Local OCI image:      %s\n' "$image_tar"
printf 'Local image digest:   %s\n' "$image_id"
printf 'Host payload bundle:  %s\n' "$host_bundle"
printf 'Host payload checksum: %s\n' "$host_bundle.sha256"
