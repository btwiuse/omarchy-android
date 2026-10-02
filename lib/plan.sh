#!/usr/bin/env bash

declare -a OA_PLAN=()

plan_add() {
  OA_PLAN+=("$1")
}

build_install_plan() {
  OA_PLAN=()
  plan_add "Acquire an exclusive installer lock under $OA_PREFIX"
  plan_add "Install missing Termux host packages: PRoot Distro, Termux:X11, Weston, PulseAudio, and the Freedreno/Turnip runtime"
  plan_add "Verify that the Termux:X11 Android companion app is installed"
  plan_add "Verify Android's Disable child process restrictions setting; use the native safety guard only for an explicitly accepted fallback"

  if [[ -n "$OA_BUNDLE" ]]; then
    plan_add "Verify the local guest image and host payload: $OA_BUNDLE"
  else
    plan_add "Download and verify the host payload archive and OCI image digest"
  fi

  plan_add "Create a new isolated PRoot container named $OA_CONTAINER from the digest-pinned OCI release image"
  plan_add "Install the pinned Omarchy runtime and Android compatibility packages inside the new container"
  plan_add "Install host start, stop, status, and Hyprland-control commands under $OA_PREFIX/bin"
  plan_add "Configure display=$OA_RESOLUTION refresh=$OA_REFRESH scale=$OA_SCALE keyboard=$OA_KEYBOARD gpu=$OA_GPU audio=$OA_AUDIO"
  plan_add "Configure optional host sharing mode: $OA_SHARE"
  plan_add "Run image, graphics-linkage, shell, browser, terminal, file-manager, and privacy smoke tests"
  plan_add "Write an installation manifest containing versions and checksums only"
}

build_remove_plan() {
  OA_PLAN=()
  local stop_helper="$OA_PREFIX/bin/omarchy-android-stop"
  if [[ -x "$stop_helper" ]]; then
    plan_add "Stop any running Omarchy Android session via $stop_helper"
  else
    plan_add "No host-runtime stop helper found at $stop_helper (session may already be stopped)"
  fi
  plan_add "Remove the proot-distro container $OA_CONTAINER (drops every guest file under it)"
  plan_add "Delete the host runtime tree at $OA_PREFIX and its install-lock"
  plan_add "Remove the cached host payload archive for this release"

  if [[ "$OA_KEEP_TERMUX_PACKAGES" == true ]]; then
    plan_add "Leave shared Termux packages installed (proot-distro, termux-x11, weston, pulseaudio, freedreno)"
  else
    plan_add "Offer to uninstall shared Termux packages that the installer added (proot-distro, termux-x11, weston, pulseaudio, freedreno)"
  fi
}

print_install_plan() {
  local index=1 item
  info "Installation plan"
  for item in "${OA_PLAN[@]}"; do
    printf '  %2d. %s\n' "$index" "$item"
    index=$((index + 1))
  done
}
