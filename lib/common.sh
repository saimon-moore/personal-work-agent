#!/usr/bin/env bash

set -u

LOCAL_HERMES_MANAGED_MARKER="# managed-by: local-hermes"
LOCAL_HERMES_INSTALLER_URL_DEFAULT="https://hermes-agent.nousresearch.com/install.sh"

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  have_cmd "$1" || die "Missing required command: $1"
}

detect_os() {
  case "$(uname -s)" in
    Linux) OS_FAMILY="linux" ;;
    Darwin) OS_FAMILY="macos" ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
}

init_defaults() {
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
  WRAPPER_PATH="${WRAPPER_PATH:-$HOME/.local/bin/hermes}"
  IMAGE_TAG="${IMAGE_TAG:-local-hermes-sandbox:node-lts}"
  NODE_STRATEGY="${NODE_STRATEGY:-auto}"
  NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
  TMP_ROOT="${TMPDIR:-/tmp}"
  INSTALLER_URL="${LOCAL_HERMES_INSTALLER_URL:-$LOCAL_HERMES_INSTALLER_URL_DEFAULT}"
  INSTALLER_PATH_OVERRIDE="${LOCAL_HERMES_INSTALLER_PATH:-}"
  CUSTOM_SKILLS_ENABLED="${CUSTOM_SKILLS_ENABLED:-1}"
  CUSTOM_SKILLS_MANIFEST="${CUSTOM_SKILLS_MANIFEST:-$REPO_DIR/skills-manifest.json}"
  CHIEF_OF_STAFF_ENABLED="${CHIEF_OF_STAFF_ENABLED:-0}"
  CHIEF_OF_STAFF_HOME="${CHIEF_OF_STAFF_HOME:-$HOME/chief-of-staff}"
  CHIEF_OF_STAFF_REPO_URL="${CHIEF_OF_STAFF_REPO_URL:-https://github.com/casim/ai-chief-of-staff-starter.git}"
  CHIEF_OF_STAFF_SKILLS_MANIFEST="${CHIEF_OF_STAFF_SKILLS_MANIFEST:-$REPO_DIR/chief-of-staff-skills-manifest.json}"
}

parse_common_arg() {
  case "${1:-}" in
    --hermes-home)
      [ $# -ge 2 ] || die "Missing value for $1"
      HERMES_HOME="$2"
      return 0
      ;;
    --wrapper)
      [ $# -ge 2 ] || die "Missing value for $1"
      WRAPPER_PATH="$2"
      return 0
      ;;
    --image-tag)
      [ $# -ge 2 ] || die "Missing value for $1"
      IMAGE_TAG="$2"
      return 0
      ;;
    --node-strategy)
      [ $# -ge 2 ] || die "Missing value for $1"
      NODE_STRATEGY="$2"
      return 0
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      return 0
      ;;
  esac
  return 1
}

is_url() {
  case "${1:-}" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_node_strategy() {
  case "$NODE_STRATEGY" in
    auto|mise|ambient) ;;
    *) die "Unsupported node strategy: $NODE_STRATEGY" ;;
  esac
}

have_mise() {
  have_cmd mise
}

mise_lts_available() {
  have_mise || return 1
  mise exec -C "$HOME" node@lts -- node -v >/dev/null 2>&1
}

run_with_node_context() {
  case "$NODE_STRATEGY" in
    auto)
      if mise_lts_available; then
        mise exec -C "$HOME" node@lts -- "$@"
      else
        "$@"
      fi
      ;;
    mise)
      mise_lts_available || die "node strategy 'mise' requested, but mise node@lts is unavailable"
      mise exec -C "$HOME" node@lts -- "$@"
      ;;
    ambient)
      "$@"
      ;;
  esac
}

runtime_node_mode() {
  case "$NODE_STRATEGY" in
    auto)
      if mise_lts_available; then
        printf 'mise\n'
      elif [ -x "$HERMES_HOME/node/bin/node" ]; then
        printf 'hermes-managed\n'
      else
        printf 'ambient\n'
      fi
      ;;
    mise)
      printf 'mise\n'
      ;;
    ambient)
      if [ -x "$HERMES_HOME/node/bin/node" ]; then
        printf 'hermes-managed\n'
      else
        printf 'ambient\n'
      fi
      ;;
  esac
}

runtime_node_version() {
  local mode
  mode="$(runtime_node_mode)"
  case "$mode" in
    mise)
      mise exec -C "$HOME" node@lts -- node -v 2>/dev/null || true
      ;;
    hermes-managed)
      "$HERMES_HOME/node/bin/node" -v 2>/dev/null || true
      ;;
    ambient)
      if have_cmd node; then
        node -v 2>/dev/null || true
      fi
      ;;
  esac
}

hermes_venv_bin() {
  printf '%s\n' "$HERMES_HOME/hermes-agent/venv/bin/hermes"
}

hermes_is_healthy() {
  local bin
  bin="$(hermes_venv_bin)"
  [ -x "$bin" ] || return 1
  run_hermes --version >/dev/null 2>&1
}

run_hermes() {
  local bin
  bin="$(hermes_venv_bin)"
  [ -x "$bin" ] || die "Hermes binary not found at $bin"
  case "$(runtime_node_mode)" in
    mise)
      mise exec -C "$HOME" node@lts -- "$bin" "$@"
      ;;
    hermes-managed)
      PATH="$HERMES_HOME/node/bin:$PATH" "$bin" "$@"
      ;;
    ambient)
      "$bin" "$@"
      ;;
  esac
}

hermes_python_bin() {
  if [ -x "$HERMES_HOME/hermes-agent/venv/bin/python3" ]; then
    printf '%s\n' "$HERMES_HOME/hermes-agent/venv/bin/python3"
    return 0
  fi
  if [ -x "$HERMES_HOME/hermes-agent/venv/bin/python" ]; then
    printf '%s\n' "$HERMES_HOME/hermes-agent/venv/bin/python"
    return 0
  fi
  if have_cmd python3; then
    command -v python3
    return 0
  fi
  if have_cmd python; then
    command -v python
    return 0
  fi
  return 1
}

wrapper_dir() {
  dirname "$WRAPPER_PATH"
}

wrapper_owned() {
  [ -f "$WRAPPER_PATH" ] && grep -Fq "$LOCAL_HERMES_MANAGED_MARKER" "$WRAPPER_PATH"
}

write_wrapper() {
  local dir
  dir="$(wrapper_dir)"
  mkdir -p "$dir"
  if [ -e "$WRAPPER_PATH" ] && ! wrapper_owned; then
    die "Wrapper path is already occupied by an unmanaged file: $WRAPPER_PATH"
  fi
  cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
$LOCAL_HERMES_MANAGED_MARKER
set -euo pipefail
HERMES_HOME="\${HERMES_HOME:-$HERMES_HOME}"
NODE_STRATEGY="\${NODE_STRATEGY:-$NODE_STRATEGY}"
if command -v mise >/dev/null 2>&1; then
  if [ "\$NODE_STRATEGY" = "auto" ] || [ "\$NODE_STRATEGY" = "mise" ]; then
    if mise exec -C "\$HOME" node@lts -- node -v >/dev/null 2>&1; then
      exec mise exec -C "\$HOME" node@lts -- "\$HERMES_HOME/hermes-agent/venv/bin/hermes" "\$@"
    elif [ "\$NODE_STRATEGY" = "mise" ]; then
      printf 'local-hermes: mise node@lts is unavailable\n' >&2
      exit 1
    fi
  fi
fi
if [ -x "\$HERMES_HOME/node/bin/node" ]; then
  export PATH="\$HERMES_HOME/node/bin:\$PATH"
fi
exec "\$HERMES_HOME/hermes-agent/venv/bin/hermes" "\$@"
EOF
  chmod +x "$WRAPPER_PATH"
}

docker_cli_available() {
  have_cmd docker
}

docker_daemon_available() {
  docker_cli_available || return 1
  docker info >/dev/null 2>&1
}

docker_image_exists() {
  docker_cli_available || return 1
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1
}

build_sandbox_image() {
  docker_daemon_available || return 1
  docker build --pull -t "$IMAGE_TAG" -f "$REPO_DIR/Dockerfile.sandbox" "$REPO_DIR"
}

ensure_hermes_config_exists() {
  mkdir -p "$HERMES_HOME"
  [ -f "$HERMES_HOME/config.yaml" ] || cat > "$HERMES_HOME/config.yaml" <<'EOF'
model:
  provider: "auto"
terminal:
  backend: "local"
EOF
}

apply_terminal_config() {
  ensure_hermes_config_exists
  local cfg tmp
  cfg="$HERMES_HOME/config.yaml"
  tmp="$(mktemp "$TMP_ROOT/local-hermes-config.XXXXXX")"
  awk '
    function top_level(line) {
      return line ~ /^[^[:space:]#][^:]*:[[:space:]]*($|#)/
    }
    {
      if (skipping) {
        if (top_level($0)) {
          skipping=0
        } else {
          next
        }
      }
      if (!skipping && $0 ~ /^terminal:[[:space:]]*$/) {
        skipping=1
        next
      }
      print
    }
    END {
      print ""
      print "# Managed by local-hermes"
      print "terminal:"
      print "  backend: \"docker\""
      print "  cwd: \"/workspace\""
      print "  timeout: 180"
      print "  lifetime_seconds: 300"
      print "  docker_image: \"" image_tag "\""
      print "  docker_mount_cwd_to_workspace: false"
      print "  docker_persist_across_processes: true"
      print "  docker_run_as_host_user: true"
      print "  container_cpu: 1"
      print "  container_memory: 4096"
      print "  docker_extra_args:"
      print "    - \"--network=none\""
    }
  ' image_tag="$IMAGE_TAG" "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
}

onboarding_complete() {
  local env_file
  env_file="$HERMES_HOME/.env"
  [ -f "$env_file" ] || return 1
  grep -E '^[A-Z0-9_]+=' "$env_file" \
    | grep -vE '=(|your-token-here)$' \
    | grep -Eq '^(OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY|NOUS_API_KEY|GITHUB_TOKEN|HF_TOKEN|KIMI_API_KEY|GLM_API_KEY|MINIMAX_API_KEY|MINIMAX_CN_API_KEY|NVIDIA_API_KEY|ARCEEAI_API_KEY|KILOCODE_API_KEY|OLLAMA_API_KEY)='
}

path_contains_wrapper_dir() {
  local dir
  dir="$(wrapper_dir)"
  printf '%s\n' "$PATH" | tr ':' '\n' | grep -Fxq "$dir"
}

gateway_process_running() {
  if have_cmd pgrep; then
    pgrep -af 'hermes.*gateway' >/dev/null 2>&1
  else
    ps -ef | grep -E '[h]ermes.*gateway' >/dev/null 2>&1
  fi
}

gateway_service_installed() {
  case "${OS_FAMILY:-}" in
    linux)
      compgen -G "$HOME/.config/systemd/user/hermes-gateway*.service" >/dev/null 2>&1
      ;;
    macos)
      compgen -G "$HOME/Library/LaunchAgents/*hermes*gateway*.plist" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_installer() {
  local out
  out="$1"
  if [ -n "$INSTALLER_PATH_OVERRIDE" ]; then
    cp "$INSTALLER_PATH_OVERRIDE" "$out"
  else
    curl -fsSL "$INSTALLER_URL" -o "$out"
  fi
  chmod +x "$out"
}

fetch_manifest_source() {
  local source out
  source="$1"
  out="$2"
  if is_url "$source"; then
    curl -fsSL "$source" -o "$out"
  else
    cp "$source" "$out"
  fi
}

append_pending_step() {
  PENDING_STEPS+=("$1")
}

collect_pending_steps() {
  PENDING_STEPS=()
  if ! path_contains_wrapper_dir; then
    append_pending_step "Add $(wrapper_dir) to PATH"
  fi
  if ! docker_daemon_available; then
    append_pending_step "Install or start Docker so Hermes can use the docker backend"
  fi
  if ! onboarding_complete; then
    append_pending_step "Run 'hermes setup'"
  fi
  if [ -e "$WRAPPER_PATH" ] && ! wrapper_owned; then
    append_pending_step "Resolve unmanaged wrapper conflict at $WRAPPER_PATH"
  fi
}

print_pending_steps() {
  if [ "${#PENDING_STEPS[@]}" -eq 0 ]; then
    log_info "No remaining manual steps."
    return 0
  fi
  printf 'Manual steps:\n'
  local step
  for step in "${PENDING_STEPS[@]}"; do
    printf ' - %s\n' "$step"
  done
}
