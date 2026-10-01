#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
version="${1:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"
repository="${2:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"
oci_reference="${3:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"
oci_manifest_digest="${4:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"
host_bundle_asset="${5:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"
host_bundle_sha256="${6:?usage: update-release-lock.sh VERSION REPOSITORY OCI_REFERENCE OCI_MANIFEST_DIGEST HOST_BUNDLE_ASSET HOST_BUNDLE_SHA256}"

[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ &&
   "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
   "$oci_manifest_digest" =~ ^sha256:[0-9a-f]{64}$ &&
   "$host_bundle_asset" == *.tar.xz &&
   "$host_bundle_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'Invalid release-lock version, repository, digest, or host-bundle checksum.\n' >&2
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
oci_manifest_digest=$oci_manifest_digest
host_bundle_asset=$host_bundle_asset
host_bundle_url=$host_url
host_bundle_sha256=$host_bundle_sha256
EOF
chmod 0644 "$temporary_lock"
mv "$temporary_lock" "$ROOT/manifest/release.lock"
trap - EXIT

printf 'Installer release lock now targets %s@%s with host bundle %s.\n' \
  "$oci_reference" "$oci_manifest_digest" "$host_bundle_asset"
