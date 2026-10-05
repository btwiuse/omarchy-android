#!/usr/bin/env bash

OA_COMPONENTS_LOCK="${PROJECT_ROOT:?}/manifest/components.lock"
OA_ARTIFACTS_LOCK="${PROJECT_ROOT:?}/manifest/artifacts.lock"
OA_HOST_ARTIFACTS_LOCK="${PROJECT_ROOT:?}/manifest/host-artifacts.lock"
OA_OCI_IMAGES_LOCK="${PROJECT_ROOT:?}/manifest/oci-images.lock"

component_record() {
  local requested="$1"
  local name type upstream revision license

  while IFS='|' read -r name type upstream revision license; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    if [[ "$name" == "$requested" ]]; then
      printf '%s|%s|%s|%s|%s\n' "$name" "$type" "$upstream" "$revision" "$license"
      return 0
    fi
  done <"$OA_COMPONENTS_LOCK"

  return 1
}

list_git_components() {
  local name type upstream revision license
  while IFS='|' read -r name type upstream revision license; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    [[ "$type" == git ]] && printf '%s\n' "$name"
  done <"$OA_COMPONENTS_LOCK"
}

validate_component_lock() {
  local line=0 name type upstream revision license extra
  local failures=0
  declare -A seen=()

  while IFS='|' read -r name type upstream revision license extra; do
    line=$((line + 1))
    [[ -n "$name" && "$name" != \#* ]] || continue

    if [[ -n "${extra:-}" || -z "$type" || -z "$upstream" || -z "$revision" || -z "$license" ]]; then
      printf '%s:%d: malformed component record\n' "$OA_COMPONENTS_LOCK" "$line" >&2
      failures=$((failures + 1))
      continue
    fi

    if [[ -n "${seen[$name]:-}" ]]; then
      printf '%s:%d: duplicate component %s\n' "$OA_COMPONENTS_LOCK" "$line" "$name" >&2
      failures=$((failures + 1))
    fi
    seen[$name]=1

    case "$type" in
      git)
        if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
          printf '%s:%d: git revision must be a full commit hash\n' "$OA_COMPONENTS_LOCK" "$line" >&2
          failures=$((failures + 1))
        fi
        ;;
      archive) ;;
      *)
        printf '%s:%d: unsupported component type %s\n' "$OA_COMPONENTS_LOCK" "$line" "$type" >&2
        failures=$((failures + 1))
        ;;
    esac
  done <"$OA_COMPONENTS_LOCK"

  ((failures == 0))
}


validate_artifact_lock() {
  local line=0 name version upstream expected_hash license extra failures=0
  declare -A seen=()

  while IFS='|' read -r name version upstream expected_hash license extra; do
    line=$((line + 1))
    [[ -n "$name" && "$name" != \#* ]] || continue
    if [[ -n "${extra:-}" || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ||
          "$upstream" != https://* || ! "$expected_hash" =~ ^[0-9a-f]{64}$ ||
          -z "$license" ]]; then
      printf '%s:%d: malformed binary artifact record\n' "$OA_ARTIFACTS_LOCK" "$line" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ -n "${seen[$name]:-}" ]]; then
      printf '%s:%d: duplicate binary artifact %s\n' "$OA_ARTIFACTS_LOCK" "$line" "$name" >&2
      failures=$((failures + 1))
    fi
    seen[$name]=1
  done < "$OA_ARTIFACTS_LOCK"

  (( failures == 0 ))
}

validate_host_artifact_lock() {
  local line=0 name version upstream expected_hash source_bundle_hash extra failures=0
  declare -A seen=()

  while IFS='|' read -r name version upstream expected_hash source_bundle_hash extra; do
    line=$((line + 1))
    [[ -n "$name" && "$name" != \#* ]] || continue
    if [[ -n "${extra:-}" || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ||
          "$upstream" != https://* || ! "$expected_hash" =~ ^[0-9a-f]{64}$ ||
          ! "$source_bundle_hash" =~ ^[0-9a-f]{64}$ ]]; then
      printf '%s:%d: malformed host artifact record\n' "$OA_HOST_ARTIFACTS_LOCK" "$line" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ -n "${seen[$name]:-}" ]]; then
      printf '%s:%d: duplicate host artifact %s\n' "$OA_HOST_ARTIFACTS_LOCK" "$line" "$name" >&2
      failures=$((failures + 1))
    fi
    seen[$name]=1
  done < "$OA_HOST_ARTIFACTS_LOCK"

  [[ "${seen[android-host]:-}" == 1 ]] || {
    printf '%s: required android-host artifact is missing\n' "$OA_HOST_ARTIFACTS_LOCK" >&2
    failures=$((failures + 1))
  }
  (( failures == 0 ))
}

validate_oci_image_lock() {
  local line=0 name repository tag manifest_digest layer_digest extra failures=0
  declare -A seen=()

  while IFS='|' read -r name repository tag manifest_digest layer_digest extra; do
    line=$((line + 1))
    [[ -n "$name" && "$name" != \#* ]] || continue
    if [[ -n "${extra:-}" || ! "$repository" =~ ^[a-z0-9._/-]+$ ||
          ! "$tag" =~ ^[A-Za-z0-9._-]+$ ||
          ! "$manifest_digest" =~ ^sha256:[0-9a-f]{64}$ ||
          ! "$layer_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf '%s:%d: malformed OCI image record\n' "$OA_OCI_IMAGES_LOCK" "$line" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ -n "${seen[$name]:-}" ]]; then
      printf '%s:%d: duplicate OCI image %s\n' "$OA_OCI_IMAGES_LOCK" "$line" "$name" >&2
      failures=$((failures + 1))
    fi
    seen[$name]=1
  done < "$OA_OCI_IMAGES_LOCK"

  (( failures == 0 ))
}
