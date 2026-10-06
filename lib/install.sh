#!/usr/bin/env bash

OA_INSTALL_TEMP=''
OA_INSTALL_LOCK=''
OA_CREATED_CONTAINER=false

cleanup_install() {
  local status=$?

  if (( status != 0 )); then
    warn 'Installation failed; rolling back only the new Omarchy Android targets.'
    if [[ "$OA_CREATED_CONTAINER" == true ]]; then
      proot-distro remove "$OA_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -d "$OA_HOST_DIR" ]]; then
      find "$OA_HOST_DIR" -depth -delete 2>/dev/null || true
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
  printf 'Create container %s with host runtime at %s? [y/N] ' "$OA_CONTAINER" "$OA_HOST_DIR"
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

OA_RELEASE_REPOSITORY="${OA_RELEASE_REPOSITORY:-omarchy-android/omarchy-android}"
OA_RELEASE_TAG=''
OA_RELEASE_VERSION=''
OA_RELEASE_OCI_REFERENCE=''
OA_RELEASE_HOST_BUNDLE_ASSET=''
OA_RELEASE_HOST_BUNDLE_URL=''

# Resolve the latest published release by following the /releases/latest
# redirect on github.com. Avoids the GitHub API entirely (no auth, no rate
# limit) and does not require a hardcoded manifest/release.lock in the
# repo. Callers can target a fork by exporting OA_RELEASE_REPOSITORY or
# passing --repository OWNER/REPO.
resolve_release() {
  local url="https://github.com/$OA_RELEASE_REPOSITORY/releases/latest"
  local final
  final="$(curl --fail --silent --show-error --location \
            --output /dev/null --write-out '%{url_effective}' "$url")" \
    || die "Could not resolve latest release from $url. Pass --repository OWNER/REPO to target a fork."
  [[ "$final" =~ /tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] \
    || die "Latest release URL is not a vX.Y.Z tag: $final"
  OA_RELEASE_TAG="${BASH_REMATCH[1]}"
  OA_RELEASE_VERSION="${OA_RELEASE_TAG#v}"
  OA_RELEASE_OCI_REFERENCE="ghcr.io/${OA_RELEASE_REPOSITORY}:${OA_RELEASE_VERSION}"
  OA_RELEASE_HOST_BUNDLE_ASSET="omarchy-android-host-aarch64-${OA_RELEASE_VERSION}.tar.xz"
  OA_RELEASE_HOST_BUNDLE_URL="https://github.com/${OA_RELEASE_REPOSITORY}/releases/download/${OA_RELEASE_TAG}/${OA_RELEASE_HOST_BUNDLE_ASSET}"
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
  local target="$OA_INSTALL_TEMP/$OA_RELEASE_HOST_BUNDLE_ASSET"
  local local_bundle

  if [[ -n "$OA_HOST_BUNDLE" ]]; then
    local_bundle="$(cd -- "$(dirname -- "$OA_HOST_BUNDLE")" && pwd -P)/$(basename -- "$OA_HOST_BUNDLE")"
    [[ -f "$local_bundle" ]] || die "Local host bundle does not exist: $local_bundle"
    cp -f "$local_bundle" "$target"
    printf '%s' "$target"
    return 0
  fi

  info "Downloading host payload" >&2
  if ! download_with_resume "$OA_RELEASE_HOST_BUNDLE_URL" "$target"; then
    die 'Host payload download failed. Check the network connection or pass --host-bundle PATH.'
  fi
  printf '%s' "$target"
}

fetch_release_rootfs() {
  printf '%s' "$OA_RELEASE_OCI_REFERENCE"
}

verify_and_extract_bundle() {
  local bundle="$1" member manifest_version packages_file packages_checksum
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

  local manifest_file
  if [[ -f "$OA_INSTALL_TEMP/unpacked/BUNDLE-MANIFEST" ]]; then
    manifest_file="$OA_INSTALL_TEMP/unpacked/BUNDLE-MANIFEST"
  else
    die 'Bundle manifest is missing.'
  fi
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

  cat > "$OA_HOST_DIR/config/runtime.conf" <<EOF
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
  install -d -m 0755 \
    "$OA_HOST_DIR/bin" \
    "$OA_HOST_DIR/config" \
    "$OA_HOST_DIR/opt/weston/lib/libweston-14"

  install -m 0755 \
    "$PROJECT_ROOT/runtime/host/omarchy-android-start" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-stop" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-status" \
    "$PROJECT_ROOT/runtime/host/omarchy-android-hyprctl" \
    "$unpacked/host/bin/omarchy-process-guard" \
    "$unpacked/host/bin/omarchy-x11-keyboard" \
    "$OA_HOST_DIR/bin/"
  install -m 0755 \
    "$unpacked/host/opt/weston/lib/libweston-14/x11-backend.so" \
    "$OA_HOST_DIR/opt/weston/lib/libweston-14/x11-backend.so"
  ln -sf "$PROJECT_ROOT/runtime/host/omarchy-android" \
    "$OA_HOST_DIR/bin/omarchy-android"
  write_runtime_config
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
  local bundle rootfs_target rootfs_install_cmd target_root
  target_root="${PREFIX:?}/var/lib/proot-distro/containers/$OA_CONTAINER/rootfs"
  [[ ! -e "$target_root" ]] || die "Target container already exists: $OA_CONTAINER"
  [[ ! -e "$OA_HOST_DIR" ]] || die "Host runtime path already exists: $OA_HOST_DIR"

  confirm_install
  install_host_dependencies

  resolve_release

  OA_INSTALL_LOCK="$OA_HOST_DIR.install-lock"
  mkdir -p "$(dirname -- "$OA_HOST_DIR")"
  mkdir "$OA_INSTALL_LOCK" 2>/dev/null || die "Another installer owns the lock: $OA_INSTALL_LOCK"
  OA_INSTALL_TEMP="$(mktemp -d "${PREFIX:?}/tmp/omarchy-android-install.XXXXXX")"
  trap cleanup_install EXIT

  if [[ -n "$OA_BUNDLE" ]]; then
    bundle="$(cd -- "$(dirname -- "$OA_BUNDLE")" && pwd -P)/$(basename -- "$OA_BUNDLE")"
    [[ -f "$bundle" ]] || die "Local bundle does not exist: $bundle"
    bundle_is_oci_tarball "$bundle" \
      || die "--bundle must point to an OCI image-layout tarball (containing oci-layout and index.json)."
    info "Using local OCI image archive: $bundle"
    rootfs_install_cmd="$bundle"
    bundle_host_only=""
  else
    bundle_host_only=""
    rootfs_install_cmd=""
  fi

  if [[ -z "$bundle_host_only" ]]; then
    bundle_host_only="$(download_host_bundle)"
  fi
  verify_and_extract_bundle "$bundle_host_only"

  if [[ -z "$rootfs_install_cmd" ]]; then
    info "Pulling OCI rootfs $OA_RELEASE_OCI_REFERENCE from the registry"
    rootfs_target="$(fetch_release_rootfs)"
    rootfs_install_cmd="$rootfs_target"
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

  cat > "$OA_HOST_DIR/INSTALL-MANIFEST" <<EOF
version=$OA_RELEASE_VERSION
oci_reference=$OA_RELEASE_OCI_REFERENCE
container=$OA_CONTAINER
gpu=$OA_GPU
resolution=$OA_RESOLUTION
refresh=$OA_REFRESH
scale=$OA_SCALE
keyboard=$OA_KEYBOARD
sharing=$OA_SHARE
audio=$OA_AUDIO
EOF

  printf '\nStart it with:\n  source %s/env && omarchy-android start\n' "$PROJECT_ROOT"
  OA_CREATED_CONTAINER=false
  success 'Omarchy Android installed and passed the clean-image smoke tests.'
}

# Reverse of perform_install. Stops the running session, deletes the
# proot-distro container (which drops every guest file under it), the
# host runtime tree, and the cached installer artifacts for this release.
# Does NOT touch other proot-distro containers or shared Termux packages
# unless the caller accepts the optional removal prompt.
perform_remove() {
  local termux_prefix target_root stop_helper
  local removed_container=false removed_host=false

  termux_prefix="${PREFIX:?}"
  target_root="$termux_prefix/var/lib/proot-distro/containers/$OA_CONTAINER/rootfs"

  if [[ ! -e "$target_root" && ! -e "$OA_HOST_DIR" ]]; then
    die "No installation found for container '$OA_CONTAINER' at $target_root or $OA_HOST_DIR."
  fi

  confirm_remove

  stop_helper="$OA_HOST_DIR/bin/omarchy-android-stop"
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

  if [[ -e "$OA_HOST_DIR" ]]; then
    info "Removing host runtime at $OA_HOST_DIR"
    find "$OA_HOST_DIR" -depth -delete 2>/dev/null || true
    rmdir "$OA_HOST_DIR" 2>/dev/null || true
    removed_host=true
  fi

  local install_lock_dir="$OA_HOST_DIR.install-lock"
  if [[ -d "$install_lock_dir" ]]; then
    rmdir "$install_lock_dir" 2>/dev/null || true
  fi

  if [[ "$OA_KEEP_TERMUX_PACKAGES" != true ]]; then
    offer_remove_termux_packages
  fi

  local summary=()
  [[ "$removed_container" == true ]] && summary+=("container $OA_CONTAINER")
  [[ "$removed_host" == true ]] && summary+=("host runtime $OA_HOST_DIR")
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
    "$OA_CONTAINER" "$OA_HOST_DIR"
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
