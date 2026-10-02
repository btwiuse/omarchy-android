#!/usr/bin/env bash
# Configure pacman.conf for the nested build environments:
#   - Pacman 7's Landlock/seccomp download sandbox cannot run under
#     Docker or PRoot, so disable both sandbox settings.
#   - BuildKit runs as root, so DownloadUser = root is harmless there
#     and required inside PRoot builders.
#   - ParallelDownloads = 4 speeds up Docker builds; PRoot builders
#     override it back to 1 themselves (single CPU visibility).
#
# Usage: prepare-pacman-conf.sh [PACMAN_CONF]
#   PACMAN_CONF defaults to /etc/pacman.conf.

set -euo pipefail

pacman_conf="${1:-/etc/pacman.conf}"
[[ -f "$pacman_conf" ]] || {
  printf 'pacman.conf not found: %s\n' "$pacman_conf" >&2
  exit 1
}

sed -i \
  -e '/^DisableSandboxFilesystem$/d' \
  -e '/^DisableSandboxSyscalls$/d' \
  "$pacman_conf"
sed -i \
  -e '/^\[options\]$/a DisableSandboxSyscalls' \
  -e '/^\[options\]$/a DisableSandboxFilesystem' \
  "$pacman_conf"

if ! grep -q '^ParallelDownloads' "$pacman_conf"; then
  sed -i '/^\[options\]$/a ParallelDownloads = 4' "$pacman_conf"
fi
if ! grep -q '^DownloadUser' "$pacman_conf"; then
  sed -i '/^\[options\]$/a DownloadUser = root' "$pacman_conf"
fi