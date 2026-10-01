#!/usr/bin/env bash

doctor_check() {
  local label="$1"
  local result="$2"
  local detail="$3"
  printf '  %-24s %-8s %s\n' "$label" "$result" "$detail"
}

run_doctor() {
  local failures=0
  local prefix_value="${PREFIX:-}"
  local arch android_api
  arch="$(uname -m 2>/dev/null || printf unknown)"
  android_api="$(getprop ro.build.version.sdk 2>/dev/null || printf unknown)"

  info "Host readiness"

  if [[ -n "$prefix_value" && -d "$prefix_value/bin" ]]; then
    doctor_check Termux PASS "$prefix_value"
  else
    doctor_check Termux FAIL "PREFIX is not a Termux prefix"
    failures=$((failures + 1))
  fi

  if [[ "$arch" == aarch64 || "$arch" == arm64 ]]; then
    doctor_check Architecture PASS "$arch"
  else
    doctor_check Architecture FAIL "$arch (ARM64 required)"
    failures=$((failures + 1))
  fi

  if [[ "$android_api" =~ ^[0-9]+$ ]] && ((android_api >= 31)); then
    doctor_check Android PASS "API $android_api"
  else
    doctor_check Android WARN "API $android_api; currently untested"
  fi

  detect_phantom_process_restriction
  case "$OA_PHANTOM_PROCESS_STATE" in
    disabled)
      doctor_check 'Phantom processes' PASS 'Android child-process restriction is disabled'
      ;;
    enabled)
      if [[ "$OA_ALLOW_PROCESS_LIMIT" == true ]]; then
        doctor_check 'Phantom processes' WARN 'restriction active; limited fallback explicitly accepted'
      else
        doctor_check 'Phantom processes' FAIL 'enable Developer options -> Disable child process restrictions'
        failures=$((failures + 1))
      fi
      ;;
    *)
      if [[ "$OA_ALLOW_PROCESS_LIMIT" == true ]]; then
        doctor_check 'Phantom processes' WARN 'state unknown; limited fallback explicitly accepted'
      else
        doctor_check 'Phantom processes' FAIL 'state unknown; enable Disable child process restrictions'
        failures=$((failures + 1))
      fi
      ;;
  esac

  local command_name
  for command_name in bash curl git proot proot-distro tar sha256sum; do
    if has_command "$command_name"; then
      doctor_check "$command_name" PASS "$(command -v "$command_name")"
    else
      doctor_check "$command_name" MISSING "installed automatically during a real install"
    fi
  done

  if has_command proot-distro; then
    # proot-distro has no --version flag; --version is treated as an unknown
    # command and exits non-zero. With inherit_errexit set, that fails the
    # whole doctor. Read the version from the package manager instead.
    proot_distro_version=""
    if has_command pip && pip show proot-distro 2>/dev/null \
       | sed -n 's/^Version: //p' | head -n1 | grep -q .; then
      proot_distro_version="$(pip show proot-distro 2>/dev/null \
        | sed -n 's/^Version: //p' | head -n1)"
    fi
    if [[ -z "$proot_distro_version" ]] && has_command dpkg; then
      proot_distro_version="$(dpkg -s proot-distro 2>/dev/null \
        | sed -n 's/^Version: //p' | head -n1)"
    fi
    if [[ -n "$proot_distro_version" ]]; then
      if printf '%s\n' "$proot_distro_version" | sort -V -C \
         && printf '%s\n%s\n' "0.7.0" "$proot_distro_version" | sort -V -C; then
        doctor_check 'proot-distro OCI' PASS "$proot_distro_version"
      else
        doctor_check 'proot-distro OCI' WARN \
          "$proot_distro_version is older than the minimum 0.7.0 required for OCI registry installs."
      fi
    else
      doctor_check 'proot-distro OCI' WARN \
        'unable to read proot-distro version; OCI registry installs may not work.'
    fi
  fi

  if [[ -e /dev/kgsl-3d0 ]]; then
    doctor_check GPU PASS '/dev/kgsl-3d0 (KGSL candidate)'
  else
    doctor_check GPU FALLBACK 'VirGL/pixman compatibility mode'
  fi

  if has_command termux-x11; then
    doctor_check Termux:X11 PASS "$(command -v termux-x11)"
  else
    doctor_check Termux:X11 MISSING 'companion package and Android app required'
  fi

  if command -v cmd >/dev/null 2>&1 && cmd package path com.termux.x11 >/dev/null 2>&1; then
    doctor_check 'Termux:X11 app' PASS 'com.termux.x11 is installed'
  else
    doctor_check 'Termux:X11 app' FAIL 'install and open the Termux:X11 Android app'
    failures=$((failures + 1))
  fi

  local target_root="${PREFIX:-/invalid}/var/lib/proot-distro/containers/$OA_CONTAINER/rootfs"
  if [[ -e "$target_root" ]]; then
    doctor_check 'Target container' EXISTS "$target_root (installer will not overwrite it)"
  else
    doctor_check 'Target container' PASS "$OA_CONTAINER is available"
  fi

  if ((failures)); then
    die "$failures mandatory host check(s) failed."
  fi
  success "Doctor completed without changing the system."
}
