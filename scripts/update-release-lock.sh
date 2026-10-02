#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
version="${1:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE HOST_BUNDLE_ASSET}"
repository="${2:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE HOST_BUNDLE_ASSET}"
oci_reference="${3:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE HOST_BUNDLE_ASSET}"
host_bundle_asset="${4:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE HOST_BUNDLE_ASSET}"

[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ &&
   "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
   "$host_bundle_asset" == *.tar.xz ]] || {
  printf 'Invalid release-lock version, repository, or host-bundle asset.\n' >&2
  exit 2
}

[[ "$oci_reference" =~ ^[A-Za-z0-9._/-]+(:[0-9]+)?(/[A-Za-z0-9._/-]+)*:[A-Za-z0-9._-]+$ ]] || {
  printf 'OCI reference must be of the form host/owner/repo:tag.\n' >&2
  exit 2
}

tag="v$version"
host_url="https://github.com/$repository/releases/download/$tag/$host_bundle_asset"
temporary_lock="$(mktemp "$ROOT/manifest/release.lock.XXXXXX")"
cleanup() {
  if [[ "$temporary_lock" == "$ROOT/manifest/release.lock."* && -f "$temporary_lock" ]]; then
    rm "$temporary_lock"
  fi
}
trap cleanup EXIT

cat > "$temporary_lock" <<EOF
format=2
version=$version
tag=$tag
oci_reference=$oci_reference
host_bundle_asset=$host_bundle_asset
host_bundle_url=$host_url
EOF
chmod 0644 "$temporary_lock"
mv "$temporary_lock" "$ROOT/manifest/release.lock"
trap - EXIT

printf 'Installer release lock now targets %s with host bundle %s.\n' \
  "$oci_reference" "$host_bundle_asset"