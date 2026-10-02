#!/usr/bin/env bash
# Install a newline-delimited package list via pacman, stripping comments
# and blank lines. Used by every stage that consumes builder/guest/*.txt.
#
# Usage: install-pkg-list.sh PATH

set -euo pipefail

list="${1:?usage: install-pkg-list.sh PATH}"
[[ -f "$list" ]] || {
  printf 'package list not found: %s\n' "$list" >&2
  exit 1
}

mapfile -t _pkgs < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$list")
(( ${#_pkgs[@]} > 0 )) || {
  printf 'empty package list: %s\n' "$list" >&2
  exit 1
}

pacman -S --needed --noconfirm "${_pkgs[@]}"
rm -rf /var/cache/pacman/pkg/*
unset _pkgs