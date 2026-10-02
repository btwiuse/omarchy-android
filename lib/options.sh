#!/usr/bin/env bash

# These globals are consumed by the other sourced installer modules.
# shellcheck disable=SC2034
OA_ACTION=install
OA_GPU=auto
OA_RESOLUTION=auto
OA_REFRESH=auto
OA_SCALE=2
OA_KEYBOARD=auto
OA_SHARE=none
OA_AUDIO=true
OA_BUNDLE=''
OA_HOST_BUNDLE=''
OA_CONTAINER=omarchy-android
OA_DRY_RUN=false
OA_ASSUME_YES=false
OA_ALLOW_UNTESTED=false
OA_ALLOW_PROCESS_LIMIT=false
OA_KEEP_TERMUX_PACKAGES=false

print_help() {
  cat <<'EOF'
Usage: ./install.sh [ACTION] [OPTIONS]

Actions:
  install                 Plan or perform an installation (default)
  remove                  Uninstall a previous installation without touching shared Termux packages
  doctor                  Inspect host readiness without changing anything
  print-config            Print the resolved configuration
  help                    Show this help

Options:
  --gpu MODE              auto, kgsl, or software (default: auto)
  --resolution MODE       auto or WIDTHxHEIGHT (default: auto)
  --refresh HZ            auto or 30-240 (default: auto)
  --scale SCALE           1, 1.25, 1.5, 1.75, or 2 (default: 2)
  --keyboard LAYOUT       auto or an XKB layout such as us/fr (default: auto)
  --share MODE            none, termux, storage, or both (default: none)
  --audio / --no-audio    Enable or disable Android audio (default: enabled)
  --bundle PATH           Use a local OCI image-layout tarball (containing oci-layout and index.json) instead of pulling from the registry
  --host-bundle PATH      Use a local host payload tarball instead of downloading it
  --name NAME             PRoot container name (default: omarchy-android)
  --keep-termux-packages  (remove) Do not offer to uninstall Termux packages that the installer added
  --yes                   Accept non-destructive prompts
  --allow-untested        Permit an untested Android version
  --allow-process-limit   Continue with Android's restrictive process fallback
  --dry-run               Print the complete plan and change nothing
  -h, --help              Show this help

Existing containers are never replaced implicitly. File sharing is opt-in. Remove never touches
guest data inside the container or any other proot-distro distribution you have installed.
EOF
}

option_value() {
  local name="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$name requires a value."
  printf '%s' "$value"
}

parse_options() {
  while (($#)); do
    case "$1" in
      install|remove|doctor|print-config|help)
        OA_ACTION="$1"
        ;;
      -h|--help)
        OA_ACTION=help
        ;;
      --gpu)
        shift
        OA_GPU="$(option_value --gpu "${1:-}")"
        ;;
      --gpu=*) OA_GPU="${1#*=}" ;;
      --resolution)
        shift
        OA_RESOLUTION="$(option_value --resolution "${1:-}")"
        ;;
      --resolution=*) OA_RESOLUTION="${1#*=}" ;;
      --refresh)
        shift
        OA_REFRESH="$(option_value --refresh "${1:-}")"
        ;;
      --refresh=*) OA_REFRESH="${1#*=}" ;;
      --scale)
        shift
        OA_SCALE="$(option_value --scale "${1:-}")"
        ;;
      --scale=*) OA_SCALE="${1#*=}" ;;
      --keyboard)
        shift
        OA_KEYBOARD="$(option_value --keyboard "${1:-}")"
        ;;
      --keyboard=*) OA_KEYBOARD="${1#*=}" ;;
      --share)
        shift
        OA_SHARE="$(option_value --share "${1:-}")"
        ;;
      --share=*) OA_SHARE="${1#*=}" ;;
      --audio) OA_AUDIO=true ;;
      --no-audio) OA_AUDIO=false ;;
      --bundle)
        shift
        OA_BUNDLE="$(option_value --bundle "${1:-}")"
        ;;
      --bundle=*) OA_BUNDLE="${1#*=}" ;;
      --host-bundle)
        shift
        OA_HOST_BUNDLE="$(option_value --host-bundle "${1:-}")"
        ;;
      --host-bundle=*) OA_HOST_BUNDLE="${1#*=}" ;;
      --name)
        shift
        OA_CONTAINER="$(option_value --name "${1:-}")"
        ;;
      --name=*) OA_CONTAINER="${1#*=}" ;;
      --yes) OA_ASSUME_YES=true ;;
      --keep-termux-packages) OA_KEEP_TERMUX_PACKAGES=true ;;
      --allow-untested) OA_ALLOW_UNTESTED=true ;;
      --allow-process-limit) OA_ALLOW_PROCESS_LIMIT=true ;;
      --dry-run) OA_DRY_RUN=true ;;
      --)
        shift
        (($# == 0)) || die "Unexpected positional arguments: $*"
        break
        ;;
      -*) die "Unknown option: $1" ;;
      *) die "Unknown action or argument: $1" ;;
    esac
    shift
  done

  validate_options
}

validate_options() {
  case "$OA_GPU" in auto|kgsl|software) ;; *) die "Invalid GPU mode: $OA_GPU" ;; esac
  case "$OA_SHARE" in none|termux|storage|both) ;; *) die "Invalid sharing mode: $OA_SHARE" ;; esac
  case "$OA_SCALE" in 1|1.25|1.5|1.75|2) ;; *) die "Invalid scale: $OA_SCALE" ;; esac
  if [[ "$OA_KEYBOARD" != auto && ! "$OA_KEYBOARD" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]]; then
    die "Keyboard must be auto or a valid XKB layout name."
  fi

  if [[ "$OA_RESOLUTION" != auto && ! "$OA_RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    die "Resolution must be auto or WIDTHxHEIGHT."
  fi

  if [[ "$OA_REFRESH" != auto ]]; then
    [[ "$OA_REFRESH" =~ ^[0-9]{2,3}$ ]] || die "Refresh must be auto or an integer in Hz."
    ((OA_REFRESH >= 30 && OA_REFRESH <= 240)) || die "Refresh must be between 30 and 240 Hz."
  fi

  [[ "$OA_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid container name: $OA_CONTAINER"
  if [[ "$OA_ACTION" == "remove" ]]; then
    [[ -z "$OA_BUNDLE" ]] || die "--bundle cannot be combined with the remove action."
    [[ -z "$OA_HOST_BUNDLE" ]] || die "--host-bundle cannot be combined with the remove action."
  fi
}

print_config() {
  cat <<EOF
Resolved configuration:
  action:       $OA_ACTION
  gpu:          $OA_GPU
  resolution:   $OA_RESOLUTION
  refresh:      $OA_REFRESH
  scale:        $OA_SCALE
  keyboard:     $OA_KEYBOARD
  sharing:      $OA_SHARE
  audio:        $OA_AUDIO
  bundle:       ${OA_BUNDLE:-download release image from registry}
  host bundle:  ${OA_HOST_BUNDLE:-download host payload archive}
  container:    $OA_CONTAINER
  dry run:      $OA_DRY_RUN
  process limit override: $OA_ALLOW_PROCESS_LIMIT
EOF
}
