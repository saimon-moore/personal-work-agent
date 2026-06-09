#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Options:
  --hermes-home PATH
  --wrapper PATH
  --image-tag TAG
  --node-strategy auto|mise|ambient
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    if parse_common_arg "$@"; then
      shift 2
      continue
    fi
    case "$1" in
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

main() {
  init_defaults
  parse_args "$@"
  detect_os
  validate_node_strategy

  if wrapper_owned; then
    rm -f "$WRAPPER_PATH"
    log_info "Removed wrapper $WRAPPER_PATH"
  elif [ -e "$WRAPPER_PATH" ]; then
    log_warn "Leaving unmanaged wrapper in place: $WRAPPER_PATH"
  fi

  if [ -d "$HERMES_HOME" ]; then
    rm -rf "$HERMES_HOME"
    log_info "Removed $HERMES_HOME"
  else
    log_info "Hermes home already absent: $HERMES_HOME"
  fi

  if docker_image_exists; then
    docker image rm "$IMAGE_TAG" >/dev/null
    log_info "Removed Docker image $IMAGE_TAG"
  else
    log_info "Docker image already absent: $IMAGE_TAG"
  fi
}

main "$@"

