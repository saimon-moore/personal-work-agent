#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

JSON=0

usage() {
  cat <<'EOF'
Usage: ./doctor.sh [options]

Options:
  --hermes-home PATH
  --wrapper PATH
  --image-tag TAG
  --node-strategy auto|mise|ambient
  --json
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    if parse_common_arg "$@"; then
      case "$1" in
        --non-interactive) shift 1 ;;
        *) shift 2 ;;
      esac
      continue
    fi
    case "$1" in
      --json)
        JSON=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

bool_string() {
  if "$1"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

config_backend() {
  local cfg
  cfg="$HERMES_HOME/config.yaml"
  [ -f "$cfg" ] || return 1
  awk '
    /^terminal:[[:space:]]*$/ { in_terminal=1; next }
    in_terminal && /^[^[:space:]#][^:]*:/ { in_terminal=0 }
    in_terminal && /^[[:space:]]+backend:[[:space:]]*/ {
      gsub(/^[[:space:]]+backend:[[:space:]]*"?/, "", $0)
      gsub(/"$/, "", $0)
      print $0
      exit
    }
  ' "$cfg"
}

config_uses_image() {
  local cfg
  cfg="$HERMES_HOME/config.yaml"
  [ -f "$cfg" ] || return 1
  grep -Fq "docker_image: \"$IMAGE_TAG\"" "$cfg"
}

config_network_none() {
  local cfg
  cfg="$HERMES_HOME/config.yaml"
  [ -f "$cfg" ] || return 1
  grep -Fq '"--network=none"' "$cfg"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

main() {
  init_defaults
  parse_args "$@"
  detect_os
  validate_node_strategy

  local hermes_ok wrapper_ok docker_cli docker_daemon image_ok backend image_cfg net_none gateway_proc gateway_service node_mode node_version
  hermes_ok=false
  wrapper_ok=false
  docker_cli=false
  docker_daemon=false
  image_ok=false
  backend=""
  image_cfg=false
  net_none=false
  gateway_proc=false
  gateway_service=false
  node_mode="$(runtime_node_mode)"
  node_version="$(runtime_node_version)"

  if hermes_is_healthy; then hermes_ok=true; fi
  if wrapper_owned; then wrapper_ok=true; fi
  if docker_cli_available; then docker_cli=true; fi
  if docker_daemon_available; then docker_daemon=true; fi
  if docker_image_exists; then image_ok=true; fi
  if backend="$(config_backend 2>/dev/null)"; then :; else backend=""; fi
  if config_uses_image; then image_cfg=true; fi
  if config_network_none; then net_none=true; fi
  if gateway_process_running; then gateway_proc=true; fi
  if gateway_service_installed; then gateway_service=true; fi

  collect_pending_steps

  if [ "$JSON" -eq 1 ]; then
    printf '{'
    printf '"hermes_installed":%s,' "$hermes_ok"
    printf '"wrapper_managed":%s,' "$wrapper_ok"
    printf '"docker_cli":%s,' "$docker_cli"
    printf '"docker_daemon":%s,' "$docker_daemon"
    printf '"docker_image":%s,' "$image_ok"
    printf '"config_backend":"%s",' "$(json_escape "$backend")"
    printf '"config_image":%s,' "$image_cfg"
    printf '"config_network_none":%s,' "$net_none"
    printf '"gateway_process":%s,' "$gateway_proc"
    printf '"gateway_service":%s,' "$gateway_service"
    printf '"node_mode":"%s",' "$(json_escape "$node_mode")"
    printf '"node_version":"%s",' "$(json_escape "$node_version")"
    printf '"pending_steps":['
    local idx
    idx=0
    for step in "${PENDING_STEPS[@]}"; do
      if [ "$idx" -gt 0 ]; then printf ','; fi
      printf '"%s"' "$(json_escape "$step")"
      idx=$((idx + 1))
    done
    printf ']}'
    printf '\n'
    exit 0
  fi

  printf 'Hermes installed: %s\n' "$hermes_ok"
  printf 'Managed wrapper: %s\n' "$wrapper_ok"
  printf 'Node mode: %s\n' "$node_mode"
  printf 'Node version: %s\n' "${node_version:-unknown}"
  printf 'Docker CLI: %s\n' "$docker_cli"
  printf 'Docker daemon: %s\n' "$docker_daemon"
  printf 'Docker image: %s\n' "$image_ok"
  printf 'Config backend: %s\n' "${backend:-missing}"
  printf 'Config image: %s\n' "$image_cfg"
  printf 'Config network none: %s\n' "$net_none"
  printf 'Gateway process: %s\n' "$gateway_proc"
  printf 'Gateway service: %s\n' "$gateway_service"
  print_pending_steps
}

main "$@"

