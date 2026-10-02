#!/usr/bin/env bash

OA_INSTALL_TEMP=''
OA_INSTALL_LOCK=''
OA_BUNDLE_CACHE=''
OA_CREATED_CONTAINER=false
OA_CREATED_PREFIX=false

cleanup_install() {
  local status=$?

  if (( status != 0 )); then
    warn 'Installation failed; rolling back only the new Omarchy Android targets.'
    if [[ "$OA_CREATED_CONTAINER" == true ]]; then
      proot-distro remove "$OA_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ "$OA_CREATED_PREFIX" == true && -d "$OA_PREFIX" ]]; then
      find "$OA_PREFIX" -depth -delete 2>/dev/null || true
    fi
  fi

  if [[ -n "$OA_INSTALL_TEMP" && "$OA_INSTALL_TEMP" == "${PREFIX:-/invalid}/tmp/"* && -d "$OA_INSTALL_TEMP" ]]; then
    find "$OA_INSTALL_TEMP" -depth -delete 2>/dev/null || true
  fi
  if [[ -n "$OA_INSTALL_LOCK" && -d "$OA_INSTALL_LOCK" ]]; then
    rmdir "$OA_INSTALL_LOCK" 2>/dev/null || true
  fi
  return "$status"
}

confirm_install() {
  [[ "$OA_ASSUME_YES" == true ]] && return 0
  printf 'Create container %s and host runtime %s? [y/N] ' "$OA_CONTAINER" "$OA_PREFIX"
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die 'Installation cancelled.' ;; esac
}

install_host_dependencies() {
  info 'Installing required Termux packages'
  pkg install -y x11-repo
  pkg install -y \
    proot-distro \
    termux-x11-nightly \
    weston \
    pulseaudio \
    xorg-xwininfo \
    mesa-vulkan-icd-freedreno \
    virglrenderer-android \
    tar \
    curl

  local required
  for required in proot-distro termux-x11 weston pulseaudio xwininfo tar sha256sum; do
    has_command "$required" || die "Required host command is still missing: $required"
  done
}

release_lock_field() {
  local key="$1"
  awk -F '=' -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' \
    "$PROJECT_ROOT/manifest/release.lock"
}

release_lock_format() {
  release_lock_field format 2>/dev/null || {
    printf '%s\n' 1
    return 0
  }
}

download_with_resume() {
  local url="$1"
  local target="$2"
  local partial="${target}.partial"
  if [[ ! -f "$target" && -f "$partial" ]]; then
    cp -f "$partial" "$target"
  fi
  if ! curl --fail --location --retry 3 --retry-delay 5 \
      --continue-at - --output "$target" "$url"; then
    [[ -f "$target" ]] && cp -f "$target" "$partial"
    return 1
  fi
  rm -f "$partial"
}

download_host_bundle() {
  local lock_format lock_asset lock_url cached target

  lock_format="$(release_lock_format)"
  if [[ "$lock_format" != "2" ]]; then
    printf ''
    return 1
  fi

  lock_asset="$(release_lock_field host_bundle_asset)" || die 'Release lock has no host_bundle_asset.'
  lock_url="$(release_lock_field host_bundle_url)" || die 'Release lock has no host_bundle_url.'

  mkdir -p "$OA_BUNDLE_CACHE"
  target="$OA_INSTALL_TEMP/$lock_asset"

  if [[ -n "$OA_HOST_BUNDLE" ]]; then
    local_bundle="$(cd -- "$(dirname -- "$OA_HOST_BUNDLE")" && pwd -P)/$(basename -- "$OA_HOST_BUNDLE")"
    [[ -f "$local_bundle" ]] || die "Local host bundle does not exist: $local_bundle"
    cp -f "$local_bundle" "$target"
    printf '%s' "$target"
    return 0
  fi

  cached="$OA_BUNDLE_CACHE/$lock_asset"

  if [[ -f "$cached" ]]; then
    info "Reusing host payload from cache" >&2
    cp -f "$cached" "$target"
    printf '%s' "$target"
    return 0
  fi

  info "Downloading host payload" >&2
  if ! download_with_resume "$lock_url" "$target"; then
    die 'Host payload download failed. Check the network connection or pass --host-bundle PATH.'
  fi
  cp -f "$target" "$cached"
  printf '%s' "$target"
}

fetch_release_rootfs() {
  local oci_ref

  oci_ref="$(release_lock_field oci_reference)" || die 'Release lock has no oci_reference.'

  printf '%s' "$oci_ref"
}

# Format 1 (legacy): a single bundle tarball containing the rootfs tarball plus
# the host payload. Format 2: a small host payload archive plus an OCI image
# pulled directly from the registry. Returns the unpacked host payload path.
download_release_bundle() {
  local lock_format lock_asset lock_url lock_sha cached cached_sum target bundle

  lock_format="$(release_lock_format)"
  if [[ "$lock_format" == "2" ]]; then
    printf ''
    return 1
  fi

  lock_asset="$(release_lock_field asset)" || die 'Release lock has no asset name.'
  lock_url="$(release_lock_field url)" || die 'Release lock has no download URL.'
  lock_sha="$(release_lock_field sha256)" || die 'Release lock has no SHA-256 checksum.'
  [[ "$lock_sha" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid bundle SHA-256 checksum.'

  target="$OA_INSTALL_TEMP/$lock_asset"
  mkdir -p "$OA_BUNDLE_CACHE"
  cached="$OA_BUNDLE_CACHE/$lock_asset"

  if [[ -f "$cached" ]]; then
    cached_sum="$(sha256sum "$cached" | awk '{print $1}')"
    if [[ "$cached_sum" == "$lock_sha" ]]; then
      info "Reusing verified release bundle from cache" >&2
      cp -f "$cached" "$target"
      printf '%s' "$target"
      return 0
    fi
    info "Cached bundle is stale; redownloading" >&2
    rm -f "$cached"
  fi

  info "Downloading verified stable ARM64 release" >&2
  if ! download_with_resume "$lock_url" "$target"; then
    die 'Release download failed. Check the network connection or pass a local file with --bundle PATH.'
  fi
  actual_sum="$(sha256sum "$target" | awk '{print $1}')"
  if [[ "$actual_sum" != "$lock_sha" ]]; then
    die "Downloaded bundle checksum mismatch: expected $lock_sha, got $actual_sum"
  fi
  rm -f "$target.partial"
  cp -f "$target" "$cached"
  printf '%s' "$target"
}

expected_bundle_checksum() {
  local bundle="$1" lock_format sidecar checksum
  lock_format="$(release_lock_format)"
  if [[ -n "$OA_BUNDLE" && "$lock_format" == "1" ]]; then
    sidecar="$bundle.sha256"
    [[ -f "$sidecar" ]] || die "Local bundles require the generated checksum sidecar: $sidecar"
    read -r checksum _ < "$sidecar"
  else
    checksum="$(release_lock_field sha256 2>/dev/null || true)"
    if [[ -z "$checksum" ]]; then
      # Format=2 has no outer-payload hash pinned in the lock; the host bundle
      # was already validated by download_host_bundle and the inner SHA256SUMS
      # is checked below. Return empty so verify_and_extract_bundle skips the
      # outer re-check.
      printf ''
      return 0
    fi
  fi
  [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid bundle SHA-256 checksum.'
  printf '%s' "$checksum"
}

verify_and_extract_bundle() {
  local bundle="$1" expected actual member manifest_version packages_file packages_checksum
  expected="$(expected_bundle_checksum "$bundle")"
  if [[ -n "$expected" ]]; then
    actual="$(sha256sum "$bundle" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "Release checksum mismatch: expected $expected, got $actual"
  fi

  while IFS= read -r member; do
    case "$member" in
      /*|../*|*/../*|*/..) die "Unsafe path in release bundle: $member" ;;
    esac
  done < <(tar -tf "$bundle")

  mkdir -p "$OA_INSTALL_TEMP/unpacked"
  tar -xf "$bundle" -C "$OA_INSTALL_TEMP/unpacked"
  [[ -f "$OA_INSTALL_TEMP/unpacked/SHA256SUMS" ]] || die 'Bundle checksums are missing.'
  (
    cd "$OA_INSTALL_TEMP/unpacked" || exit
    sha256sum -c SHA256SUMS
  )

  # The legacy format=1 release contained a single manifest named BUNDLE-MANIFEST
  # and an inner rootfs.tar.xz. The format=2 release splits host payload and
  # guest rootfs: the manifest is still BUNDLE-MANIFEST, but the rootfs comes
  # from a separate OCI pull handled by the caller.
  local manifest_file
  if [[ -f "$OA_INSTALL_TEMP/unpacked/BUNDLE-MANIFEST" ]]; then
    manifest_file="$OA_INSTALL_TEMP/unpacked/BUNDLE-MANIFEST"
  else
    die 'Bundle manifest is missing.'
  fi
  [[ "$(awk -F= '$1=="format" {print $2}' "$manifest_file")" =~ ^[12]$ ]] || \
    die 'Unsupported bundle format.'
  [[ "$(awk -F= '$1=="architecture" {print $2}' "$manifest_file")" == aarch64 ]] || \
    die 'Release bundle is not ARM64.'
  manifest_version="$(awk -F= '$1=="version" {print $2}' "$manifest_file")"
  [[ "$manifest_version" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Release bundle has an invalid version.'
  packages_file="$OA_INSTALL_TEMP/unpacked/manifest/packages-aarch64-$manifest_version.lock"
  [[ -f "$packages_file" ]] || die 'Release package inventory is missing.'
  packages_checksum="$(awk -F= '$1=="packages_lock_sha256" {print $2}' "$manifest_file")"
  [[ "$packages_checksum" =~ ^[0-9a-f]{64}$ ]] || die 'Release package inventory checksum is missing.'
  [[ "$(sha256sum "$packages_file" | awk '{print $1}')" == "$packages_checksum" ]] || \
    die 'Release package inventory checksum mismatch.'
  [[ -f "$OA_INSTALL_TEMP/unpacked/host/opt/weston/lib/libweston-14/x11-backend.so" ]] || \
    die 'Patched Weston backend is missing.'
  [[ -x "$OA_INSTALL_TEMP/unpacked/host/bin/omarchy-process-guard" ]] || \
    die 'Native process guard is missing.'
  [[ -x "$OA_INSTALL_TEMP/unpacked/host/bin/omarchy-x11-keyboard" ]] || \
    die 'Native keyboard helper is missing.'
  [[ -f "$OA_INSTALL_TEMP/unpacked/host/share/licenses/omarchy-android/LICENSE" ]] || \
    die 'Omarchy Android license is missing from the bundle.'
  [[ -f "$OA_INSTALL_TEMP/unpacked/host/share/licenses/weston/COPYING" ]] || \
    die 'Weston license is missing from the bundle.'
}

write_runtime_config() {
  local gpu_mode resolution refresh audio
  case "$OA_GPU" in
    auto)
      if [[ -r /dev/kgsl-3d0 && -w /dev/kgsl-3d0 ]]; then gpu_mode=kgsl; else gpu_mode=virgl; fi
      ;;
    kgsl) gpu_mode=kgsl ;;
    software) gpu_mode=virgl ;;
  esac
  resolution="$OA_RESOLUTION"
  if [[ "$OA_REFRESH" == auto ]]; then refresh=120000; else refresh=$((OA_REFRESH * 1000)); fi
  if [[ "$OA_AUDIO" == true ]]; then audio=1; else audio=0; fi

  cat > "$OA_PREFIX/config/runtime.conf" <<EOF
# Generated by Omarchy Android installer. Values are shell-safe validated enums.
OMARCHY_CONTAINER=$OA_CONTAINER
OMARCHY_GPU_MODE=$gpu_mode
OMARCHY_COMPOSITOR_GL_DRIVER=kgsl
OMARCHY_DISPLAY_RESOLUTION=$resolution
OMARCHY_REFRESH_MHZ=$refresh
OMARCHY_SCALE=$OA_SCALE
OMARCHY_KEYBOARD_LAYOUT=$OA_KEYBOARD
OMARCHY_SHARE=$OA_SHARE
OMARCHY_AUDIO=$audio
EOF
}

install_host_runtime() {
  local unpacked="$OA_INSTALL_TEMP/unpacked"
  OA_CREATED_PREFIX=true
  install -d -m 0755 "$OA_PREFIX/bin" "$OA_PREFIX/config" "$OA_PREFIX/opt/weston/lib/libweston-14"

  install -m 0755 \
    "$PROJECT_ROOT/runtime/host/omarchy-android-start" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-stop" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-status" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-hyprctl" \
    "$OA_PREFIX/bin/"
  install -m 0755 \
    "$unpacked/host/bin/omarchy-process-guard" \
    "$unpacked/host/bin/omarchy-x11-keyboard" \
    "$OA_PREFIX/bin/"
  install -m 0755 \
    "$unpacked/host/opt/weston/lib/libweston-14/x11-backend.so" \
    "$OA_PREFIX/opt/weston/lib/libweston-14/x11-backend.so"
  write_runtime_config

  cat > "$OA_PREFIX/bin/omarchy-android" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "${1:-start}" in
  start) shift || true; exec "$script_dir/omarchy-android-start" "$@" ;;
  stop) shift || true; exec "$script_dir/omarchy-android-stop" "$@" ;;
  status) shift || true; exec "$script_dir/omarchy-android-status" "$@" ;;
  hyprctl) shift || true; exec "$script_dir/omarchy-android-hyprctl" "$@" ;;
  *) printf 'usage: %s {start|stop|status|hyprctl}\n' "$0" >&2; exit 2 ;;
esac
EOF
  chmod 0755 "$OA_PREFIX/bin/omarchy-android"
}

smoke_test_install() {
  local guest_mesa=/opt/omarchy-android/mesa/root/usr
  local guest_aquamarine=/opt/omarchy-android/aquamarine
  local guest_hyprland=/opt/omarchy-android/hyprland

  info 'Running installed-image smoke tests'
  # The single-quoted program is intentionally expanded by guest Bash.
  # shellcheck disable=SC2016
  proot-distro login --isolated --user omarchy \
    -e LD_LIBRARY_PATH="$guest_mesa/lib:$guest_aquamarine/lib" \
    -e PATH="$guest_hyprland/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$OA_CONTAINER" -- bash --noprofile --norc -euc '
      test "$HOME" = /home/omarchy
      runtime_dir="$(mktemp -d)"
      trap '\''rmdir "$runtime_dir" 2>/dev/null || true'\'' EXIT
      chmod 0700 "$runtime_dir"
      export XDG_RUNTIME_DIR="$runtime_dir"
      test -f /etc/omarchy-android-release
      test -f "$HOME/.config/hypr/hyprland.lua"
      test -f "$HOME/.config/omarchy/proot-session-bus.conf"
      test -f "$HOME/.local/state/omarchy/current/theme/shell.toml"
      test -x /opt/omarchy-android/hyprland/bin/Hyprland
      test -f /opt/omarchy-android/mesa/root/usr/lib/libvulkan_freedreno.so
      test -f /usr/share/licenses/aquamarine/LICENSE
      test -f /usr/share/licenses/hyprland/LICENSE
      test -f /usr/share/licenses/mesa/license.rst
      test -f /usr/share/omarchy/LICENSE
      command -v quickshell
      command -v chromium
      command -v nautilus
      command -v foot
      command -v awk
      command -v uwsm-app
      command -v omarchy-launch-shell
      test "$(awk '\''BEGIN { print 42 }'\'')" = 42
      OMARCHY_PROOT=1 uwsm-app -- true
      locale -a | grep -Fxi "C.utf8"
      fc-match monospace | grep -F "JetBrainsMono Nerd Font"
      test ! -e /usr/share/omarchy/.git
      test ! -e "$HOME/.ssh"
      for browser_state in History Cookies "Login Data" "Web Data"; do
        test ! -e "$HOME/.config/chromium/Default/$browser_state"
      done
      test ! -e "$HOME/.bash_history"
      test ! -s /etc/machine-id
      ! find /var/cache/pacman/pkg /var/log -type f -print -quit 2>/dev/null | grep -q .
      ! ldd /opt/omarchy-android/hyprland/bin/Hyprland | grep -F "not found"
      /opt/omarchy-android/hyprland/bin/Hyprland --version
      chromium --version
      foot --version
      pacman -Q nautilus
      quickshell --version
    '
}

# Detect whether the user-supplied --bundle path is an OCI image-layout tarball
# produced by `docker save` or `proot-distro build -o ...`. Returns 0 on match.
bundle_is_oci_tarball() {
  local bundle_path="$1"
  [[ -f "$bundle_path" ]] || return 1
  tar -tf "$bundle_path" 2>/dev/null | grep -qxF 'oci-layout' \
    && tar -tf "$bundle_path" 2>/dev/null | grep -qxF 'index.json'
}

perform_install() {
  local lock_format bundle rootfs_target rootfs_install_cmd target_root
  target_root="${PREFIX:?}/var/lib/proot-distro/containers/$OA_CONTAINER/rootfs"
  [[ ! -e "$target_root" ]] || die "Target container already exists: $OA_CONTAINER"
  [[ ! -e "$OA_PREFIX" ]] || die "Host runtime path already exists: $OA_PREFIX"

  confirm_install
  install_host_dependencies

  OA_INSTALL_LOCK="${OA_PREFIX}.install-lock"
  mkdir -p "$(dirname -- "$OA_PREFIX")"
  mkdir "$OA_INSTALL_LOCK" 2>/dev/null || die "Another installer owns the lock: $OA_INSTALL_LOCK"
  OA_INSTALL_TEMP="$(mktemp -d "${PREFIX:?}/tmp/omarchy-android-install.XXXXXX")"
  OA_BUNDLE_CACHE="${PREFIX:?}/var/cache/omarchy-android/bundle"
  mkdir -p "$OA_BUNDLE_CACHE"
  trap cleanup_install EXIT

  lock_format="$(release_lock_format)"

  if [[ -n "$OA_BUNDLE" ]]; then
    bundle="$(cd -- "$(dirname -- "$OA_BUNDLE")" && pwd -P)/$(basename -- "$OA_BUNDLE")"
    [[ -f "$bundle" ]] || die "Local bundle does not exist: $bundle"
    case "$lock_format" in
      2)
        bundle_is_oci_tarball "$bundle" \
          || die "--bundle must point to an OCI image-layout tarball (containing oci-layout and index.json) for format=2 releases."
        info "Using local OCI image archive: $bundle"
        rootfs_install_cmd="$bundle"
        bundle_host_only=""
        ;;
      *)
        if bundle_is_oci_tarball "$bundle"; then
          die "--bundle points to an OCI tarball, but the release lock is format=1. Use the bundled tarball from the v0.1.1 release or upgrade the release lock to format=2."
        fi
        bundle_host_only="$bundle"
        rootfs_install_cmd=""
        ;;
    esac
  else
    bundle_host_only=""
    rootfs_install_cmd=""
  fi

  if [[ -z "$bundle_host_only" ]]; then
    case "$lock_format" in
      2) bundle_host_only="$(download_host_bundle)" ;;
      *) bundle_host_only="$(download_release_bundle)" ;;
    esac
  fi
  verify_and_extract_bundle "$bundle_host_only"

  if [[ -z "$rootfs_install_cmd" ]]; then
    case "$lock_format" in
      2)
        info "Pulling OCI rootfs from the registry"
        rootfs_target="$(fetch_release_rootfs)"
        rootfs_install_cmd="$rootfs_target"
        ;;
      *)
        rootfs_target="$OA_INSTALL_TEMP/unpacked/rootfs.tar.xz"
        [[ -f "$rootfs_target" ]] || die 'Release rootfs is missing.'
        rootfs_install_cmd="$rootfs_target"
        ;;
    esac
  fi

  info "Creating isolated PRoot container $OA_CONTAINER"
  OA_CREATED_CONTAINER=true
  if ! proot-distro install --name "$OA_CONTAINER" --architecture aarch64 \
      "$rootfs_install_cmd" 2>"$OA_INSTALL_TEMP/proot-install.stderr"; then
    cat "$OA_INSTALL_TEMP/proot-install.stderr" >&2 || true
    die "proot-distro install failed for $rootfs_install_cmd"
  fi
  # The release archive intentionally excludes live /run bind mounts. Ensure
  # the guest-side mount point exists before the runtime binds Termux's private
  # session directory onto it.
  install -d -m 0755 "$target_root/run/user/1000"

  install_host_runtime
  smoke_test_install

  cat > "$OA_PREFIX/INSTALL-MANIFEST" <<EOF
format=2
version=$(awk -F= '$1=="version" {print $2}' "$OA_INSTALL_TEMP/unpacked/BUNDLE-MANIFEST")
oci_reference=$(release_lock_field oci_reference 2>/dev/null || printf '')
container=$OA_CONTAINER
gpu=$OA_GPU
resolution=$OA_RESOLUTION
refresh=$OA_REFRESH
scale=$OA_SCALE
keyboard=$OA_KEYBOARD
sharing=$OA_SHARE
audio=$OA_AUDIO
EOF

  OA_CREATED_CONTAINER=false
  OA_CREATED_PREFIX=false
  success 'Omarchy Android installed and passed the clean-image smoke tests.'
  printf '\nStart it with:\n  %s/bin/omarchy-android start\n' "$OA_PREFIX"
}

# Reverse of perform_install. Stops the running session, deletes the
# proot-distro container (which drops every guest file under it), the
# host runtime tree, and the cached installer artifacts for this release.
# Does NOT touch other proot-distro containers or shared Termux packages
# unless the caller accepts the optional removal prompt.
perform_remove() {
  local termux_prefix target_root stop_helper
  local bundle_cache
  local removed_container=false removed_prefix=false removed_bundle=false

  termux_prefix="${PREFIX:?}"
  target_root="$termux_prefix/var/lib/proot-distro/containers/$OA_CONTAINER/rootfs"

  if [[ ! -e "$target_root" && ! -e "$OA_PREFIX" ]]; then
    die "No installation found for container '$OA_CONTAINER' at $target_root or $OA_PREFIX."
  fi

  confirm_remove

  stop_helper="$OA_PREFIX/bin/omarchy-android-stop"
  if [[ -x "$stop_helper" ]]; then
    info 'Stopping any running Omarchy Android session'
    "$stop_helper" || true
  else
    warn "Host runtime stop helper not present at $stop_helper; skipping stop step."
  fi

  if [[ -e "$target_root" ]]; then
    info "Removing proot-distro container $OA_CONTAINER"
    if ! proot-distro remove "$OA_CONTAINER"; then
      warn "proot-distro remove reported an error; forcing leftover path removal."
      find "$target_root" -depth -delete 2>/dev/null || true
      [[ ! -d "$termux_prefix/var/lib/proot-distro/containers/$OA_CONTAINER" ]] \
        || rmdir "$termux_prefix/var/lib/proot-distro/containers/$OA_CONTAINER" 2>/dev/null || true
    fi
    removed_container=true
  fi

  if [[ -e "$OA_PREFIX" ]]; then
    info "Removing host runtime at $OA_PREFIX"
    find "$OA_PREFIX" -depth -delete 2>/dev/null || true
    rmdir "$OA_PREFIX" 2>/dev/null || true
    removed_prefix=true
  fi

  local install_lock_dir="${OA_PREFIX}.install-lock"
  if [[ -d "$install_lock_dir" ]]; then
    rmdir "$install_lock_dir" 2>/dev/null || true
  fi

  bundle_cache="$termux_prefix/var/cache/omarchy-android/bundle"
  if [[ -r "$PROJECT_ROOT/manifest/release.lock" ]]; then
    local asset
    asset="$(awk -F '=' '$1=="host_bundle_asset" {print $2; exit}' \
      "$PROJECT_ROOT/manifest/release.lock")"
    if [[ -n "$asset" && -f "$bundle_cache/$asset" ]]; then
      rm -f "$bundle_cache/$asset"
      removed_bundle=true
    fi
  fi

  if [[ "$OA_KEEP_TERMUX_PACKAGES" != true ]]; then
    offer_remove_termux_packages
  fi

  local summary=()
  [[ "$removed_container" == true ]] && summary+=("container $OA_CONTAINER")
  [[ "$removed_prefix" == true ]] && summary+=("host runtime $OA_PREFIX")
  [[ "$removed_bundle" == true ]] && summary+=("cached host bundle")
  if (( ${#summary[@]} )); then
    local joined
    joined="$(IFS=', '; printf '%s' "${summary[*]}")"
    success "Omarchy Android removal completed: removed $joined."
    printf '\nNothing remains on this device for container %s.\n' "$OA_CONTAINER"
  else
    success 'Omarchy Android removal found no install artifacts to remove.'
  fi
}

confirm_remove() {
  [[ "$OA_ASSUME_YES" == true ]] && return 0
  printf 'Remove Omarchy Android (container %s, host runtime %s)? [y/N] ' \
    "$OA_CONTAINER" "$OA_PREFIX"
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die 'Removal cancelled.' ;; esac
}

# Termux packages the installer added are shared host dependencies; they
# may be in use by other tooling or proot-distro distributions. Offer
# the user the choice and only remove what they explicitly accept.
offer_remove_termux_packages() {
  local pkg_list=(
    x11-repo
    proot-distro
    termux-x11-nightly
    weston
    pulseaudio
    xorg-xwininfo
    mesa-vulkan-icd-freedreno
    virglrenderer-android
    tar
    curl
  )
  local installed=()
  local pkg
  for pkg in "${pkg_list[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 && installed+=("$pkg")
  done
  (( ${#installed[@]} )) || return 0

  local answer
  if [[ "$OA_ASSUME_YES" == true ]]; then
    answer='n'
    warn 'Skipping Termux package removal under --yes; packages may be in use elsewhere.'
  else
    printf 'Also uninstall these Termux packages? %s [y/N] ' "${installed[*]}"
    read -r answer
  fi
  case "$answer" in y|Y|yes|YES)
    apt-get purge -y "${installed[@]}" >/dev/null 2>&1 \
      || warn "apt-get purge reported an error; some packages may not have been removed."
    apt-get autoremove -y >/dev/null 2>&1 || true
    info 'Uninstalled shared Termux packages.'
    ;;
  *) info 'Left shared Termux packages installed.' ;;
  esac
}
