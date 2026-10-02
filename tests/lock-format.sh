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

# format=1
cat > "$tmp/f1.lock" <<LOCK
format=1
version=0.1.0
tag=v0.1.0
asset=test.tar
url=https://example.com/test.tar
sha256=$(printf '%064d' 0)
LOCK
OA_RELEASE_LOCK="$tmp/f1.lock"
if validate_release_lock; then
  echo "format=1: accepted"
else
  echo "format=1: REJECTED"; exit 1
fi

# format=2 (good)
cat > "$tmp/f2.lock" <<LOCK
format=2
version=0.2.0
tag=v0.2.0
oci_reference=ghcr.io/btwiuse/omarchy-android:0.2.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/f2.lock"
if validate_release_lock; then
  echo "format=2: accepted"
else
  echo "format=2: REJECTED"; exit 1
fi

# format=2 with bad oci_reference
cat > "$tmp/f2bad.lock" <<LOCK
format=2
version=0.2.0
tag=v0.2.0
oci_reference=invalid ref with spaces:1.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/f2bad.lock"
if validate_release_lock; then
  echo "bad oci_reference: WRONGLY ACCEPTED"; exit 1
fi
echo "bad oci_reference: rejected"

# unsupported format
cat > "$tmp/f99.lock" <<'LOCK'
format=99
version=0.2.0
LOCK
OA_RELEASE_LOCK="$tmp/f99.lock"
if validate_release_lock; then
  echo "format=99: WRONGLY ACCEPTED"; exit 1
fi
echo "format=99: rejected"

# format=2 with port-based registry
cat > "$tmp/f2port.lock" <<LOCK
format=2
version=0.2.0
tag=v0.2.0
oci_reference=registry.example.com:5000/foo/bar:1.0
host_bundle_asset=test.tar.xz
host_bundle_url=https://example.com/test.tar.xz
LOCK
OA_RELEASE_LOCK="$tmp/f2port.lock"
if validate_release_lock; then
  echo "format=2 with port: accepted"
else
  echo "format=2 with port: REJECTED"; exit 1
fi

echo "lock-format tests passed"