#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

PROJECT_ROOT="$ROOT"
export PROJECT_ROOT
# shellcheck source=lib/manifest.sh
source "$ROOT/lib/manifest.sh"

# Only validate files that are part of this repository. `.work` contains exact
# upstream checkouts; linting those would report upstream issues that are not
# part of the Android distribution.
mapfile -t scripts < <(
  find "$ROOT" \
    \( -type d \( -name .git -o -name .work \) -prune \) -o \
    \( -type f -name '*.sh' -print \) | sort
)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${scripts[@]}"
fi

forbidden=(
  'omarchy-real'
  '/var/lib/proot-distro/containers/omarchy-arm'
  '/var/lib/proot-distro/containers/omarchy-utm'
  '/home/omarchy/.config/chromium'
  '/home/omarchy/.ssh'
  'BEGIN OPENSSH PRIVATE KEY'
  'BEGIN PGP PRIVATE KEY BLOCK'
  'gh auth login'
  'signed Arch Linux ARM rootfs'
)

for pattern in "${forbidden[@]}"; do
  hits="$(grep -R -n -F --exclude-dir=.git --exclude-dir=.work --exclude-dir=.crush \
      --exclude=validate.sh -- "$pattern" "$ROOT" \
      | grep -v 'build-rootfs\.sh:' || true)"
  if [[ -n "$hits" ]]; then
    printf 'forbidden development-install reference found: %s\n' "$pattern" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
done

validate_component_lock
validate_artifact_lock
validate_host_artifact_lock
validate_oci_image_lock

# The expected count is enforced to flag unintentional drift in the runtime
# closure. The expected values are derived from the most recently produced
# *.lock files and must be updated whenever the runtime closure legitimately
# changes (a runtime package added or dropped, or a transitive dependency
# rename / versioned split).
for package_inventory in \
  "$ROOT/manifest/packages-aarch64-0.1.0.lock:557" \
  "$ROOT/manifest/packages-aarch64-edge.lock:558"; do
  packages_lock="${package_inventory%:*}"
  expected_package_count="${package_inventory##*:}"
  [[ -f "$packages_lock" ]] || {
    printf 'missing package inventory: %s\n' "$packages_lock" >&2
    exit 1
  }
  package_count="$(grep -Evc '^[[:space:]]*(#|$)' "$packages_lock")"
  (( package_count == expected_package_count )) || {
    printf 'expected %s packages in %s, found %s\n' \
      "$expected_package_count" "$packages_lock" "$package_count" >&2
    exit 1
  }
  if ! grep -Ev '^[[:space:]]*(#|$)' "$packages_lock" | LC_ALL=C sort -cu; then
    printf 'package inventory is not unique and bytewise sorted: %s\n' "$packages_lock" >&2
    exit 1
  fi
  if grep -Ev '^[[:space:]]*(#|$)' "$packages_lock" | \
      grep -Ev '^[a-z0-9@._+:-]+ [^[:space:]]+$' >/dev/null; then
    printf 'package inventory contains an invalid line: %s\n' "$packages_lock" >&2
    exit 1
  fi
  # The runtime package manifest must be a strict subset of the latest
  # captured closure (packages-aarch64-edge.lock). The 0.1.0 lock is a
  # frozen historical artifact captured before the runtime list reached
  # its current shape; it is checked for shape and stability but not for
  # closure superset. If something is absent from edge.lock, the
  # disposable builder did not install it, or the captured lock is from a
  # stale build. Either way, drift must be resolved before publishing a
  # release.
  if [[ "$packages_lock" == "$ROOT/manifest/packages-aarch64-edge.lock" ]]; then
    runtime_manifest="$ROOT/builder/guest/runtime-packages.txt"
    [[ -f "$runtime_manifest" ]] || {
      printf 'missing runtime package manifest: %s\n' "$runtime_manifest" >&2
      exit 1
    }
    mapfile -t runtime_pkgs < <(
      sed -E -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$runtime_manifest" \
        | awk '{print $1}' | LC_ALL=C sort -u
    )
    mapfile -t captured_pkgs < <(
      grep -Ev '^[[:space:]]*(#|$)' "$packages_lock" | awk '{print $1}' | LC_ALL=C sort -u
    )
    missing="$(comm -23 \
      <(printf '%s\n' "${runtime_pkgs[@]}") \
      <(printf '%s\n' "${captured_pkgs[@]}"))"
    if [[ -n "$missing" ]]; then
      printf 'runtime packages missing from %s:\n%s\n' "$packages_lock" "$missing" >&2
      exit 1
    fi
  fi
done

"$ROOT/tests/options.sh"
"$ROOT/tests/runtime.sh"
"$ROOT/tests/remove.sh"
printf 'validation passed\n'
