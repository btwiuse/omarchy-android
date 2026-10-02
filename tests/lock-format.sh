#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT_ROOT="$ROOT"
export PROJECT_ROOT
# shellcheck source=lib/manifest.sh
source "$ROOT/lib/manifest.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# Good lock
cat > "$tmp/good.lock" <<LOCK
version=0.2.0
tag=v0.2.0
oci_reference=ghcr.io/btwiuse/omarchy-android:0.2.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/good.lock"
if validate_release_lock; then
  echo "good: accepted"
else
  echo "good: REJECTED"; exit 1
fi

# Missing required field
sed -i '/host_bundle_url/d' offline.good.lock 2>/dev/null || true
cat > "$tmp/missing.lock" <<LOCK
version=0.2.0
tag=v0.2.0
oci_reference=ghcr.io/btwiuse/omarchy-android:0.2.0
host_bundle_asset=test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/missing.lock"
if validate_release_lock; then
  echo "missing field: WRONGLY ACCEPTED"; exit 1
fi
echo "missing field: rejected"

# Bad oci_reference
cat > "$tmp/badref.lock" <<LOCK
version=0.2.0
tag=v0.2.0
oci_reference=invalid ref with spaces:1.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/badref.lock"
if validate_release_lock; then
  echo "bad oci_reference: WRONGLY ACCEPTED"; exit 1
fi
echo "bad oci_reference: rejected"

# Port-based registry
cat > "$tmp/port.lock" <<LOCK
version=0.2.0
tag=v0.2.0
oci_reference=registry.example.com:5000/foo/bar:1.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/port.lock"
if validate_release_lock; then
  echo "port-based registry: accepted"
else
  echo "port-based registry: REJECTED"; exit 1
fi

# Lock file missing
if OA_RELEASE_LOCK="$tmp/nope.lock" validate_release_lock; then
  echo "missing lock: WRONGLY ACCEPTED"; exit 1
fi

echo "lock-format tests passed"