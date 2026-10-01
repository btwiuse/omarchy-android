#!/usr/bin/env bash
# Stamp the release metadata file. Lives as a separate file because
# Dockerfile RUN blocks are passed through several layers of shell quoting
# (YAML -> docker buildx -> /bin/bash -> this script) and any awk with
# embedded quotes gets corrupted by escaped backslashes. Keeping the
# work in a real shell file makes the quoting boring and predictable.

set +e
version="$1"
precompile_digest="$2"

{
  printf 'OMARCHY_ANDROID_FORMAT=2\n'
  printf 'OMARCHY_ANDROID_ARCH=aarch64\n'
  printf 'OMARCHY_ANDROID_VERSION=%s\n' "$version"
  printf 'OMARCHY_ANDROID_IMAGE_DIGEST=%s\n' "$precompile_digest"
  printf 'OMARCHY_ANDROID_UPSTREAM_REVISION=%s\n' \
    "$(awk -F '|' '$1=="omarchy" {print $4}' /opt/src/manifest/components.lock)"
  printf 'OMARCHY_ANDROID_PATCHES_LOCK_SHA256=%s\n' \
    "$(sha256sum /opt/src/manifest/patches.lock | awk '{print $1}')"
  printf 'OMARCHY_ANDROID_PACKAGES_LOCK_SHA256=%s\n' \
    "$(sha256sum /opt/src/manifest/packages-aarch64-edge.lock | awk '{print $1}')"
  printf 'OMARCHY_ANDROID_HOST_BUNDLE_SHA256=%s\n' \
    "$(sha256sum /opt/src/manifest/host-artifacts.lock | awk '{print $1}')"
} > /etc/omarchy-android-release