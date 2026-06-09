#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --hermes-home PATH
  --wrapper PATH
  --image-tag TAG
  --node-strategy auto|mise|ambient
  --non-interactive
  --skip-custom-skills
  --skills-manifest PATH|URL
  --with-chief-of-staff
  --chief-of-staff-home PATH
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
      --skip-custom-skills)
        CUSTOM_SKILLS_ENABLED=0
        shift
        ;;
      --skills-manifest)
        [ $# -ge 2 ] || die "Missing value for $1"
        CUSTOM_SKILLS_MANIFEST="$2"
        shift 2
        ;;
      --with-chief-of-staff)
        CHIEF_OF_STAFF_ENABLED=1
        shift
        ;;
      --chief-of-staff-home)
        [ $# -ge 2 ] || die "Missing value for $1"
        CHIEF_OF_STAFF_HOME="$2"
        shift 2
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

run_installer() {
  local installer tmp_path dir
  installer="$(mktemp "$TMP_ROOT/local-hermes-installer.XXXXXX")"
  fetch_installer "$installer"
  dir="$(wrapper_dir)"
  mkdir -p "$dir"
  tmp_path="$dir:$PATH"
  (
    cd "$HOME"
    PATH="$tmp_path" HERMES_HOME="$HERMES_HOME" run_with_node_context bash "$installer" --skip-browser --skip-setup --non-interactive
  )
  rm -f "$installer"
}

install_skills_from_manifest() {
  local manifest_source manifest_tmp python_bin label
  manifest_source="$1"
  label="$2"

  if [ -z "$manifest_source" ]; then
    log_info "No $label manifest configured; skipping $label installation"
    return 0
  fi

  if ! python_bin="$(hermes_python_bin)"; then
    log_warn "No Python interpreter available for $label manifest parsing; skipping $label installation"
    return 0
  fi

  manifest_tmp="$(mktemp "$TMP_ROOT/local-hermes-skills.XXXXXX.json")"
  if ! fetch_manifest_source "$manifest_source" "$manifest_tmp" 2>/dev/null; then
    rm -f "$manifest_tmp"
    log_warn "Unable to read $label manifest from $manifest_source; skipping $label installation"
    return 0
  fi

  log_info "Installing $label from $manifest_source"
  HERMES_WRAPPER="$WRAPPER_PATH" MANIFEST_PATH="$manifest_tmp" "$python_bin" - <<'PY'
import json
import os
import subprocess
import sys
from urllib.parse import urlparse

manifest_path = os.environ["MANIFEST_PATH"]
hermes_wrapper = os.environ["HERMES_WRAPPER"]


def github_tree_url_to_identifier(value: str) -> str | None:
    try:
        parsed = urlparse(value)
    except Exception:
        return None
    if parsed.scheme not in {"http", "https"} or parsed.netloc != "github.com":
        return None
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 5:
        return None
    owner, repo, marker = parts[0], parts[1], parts[2]
    if marker != "tree":
        return None
    path_parts = parts[4:]
    if not path_parts:
        return None
    return "/".join([owner, repo, *path_parts])

try:
    with open(manifest_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception as exc:
    print(f"[WARN] Failed to parse custom skills manifest {manifest_path}: {exc}")
    sys.exit(0)

skills = payload.get("skills", []) if isinstance(payload, dict) else []
if not isinstance(skills, list):
    print(f"[WARN] Custom skills manifest {manifest_path} has no 'skills' list; skipping custom skill installation")
    sys.exit(0)

for entry in skills:
    if not isinstance(entry, dict):
        print("[WARN] Skipping custom skill manifest entry that is not an object")
        continue
    if entry.get("enabled", True) is False:
        continue

    identifier = str(entry.get("identifier", "")).strip()
    url = str(entry.get("url", "")).strip()
    source = identifier
    if not source and url:
        source = github_tree_url_to_identifier(url) or url
    if not source:
      print("[WARN] Skipping custom skill manifest entry without url or identifier")
      continue

    cmd = [hermes_wrapper, "skills", "install", source]
    name = str(entry.get("name", "")).strip()
    if name:
        cmd.extend(["--name", name])
    category = str(entry.get("category", "")).strip()
    if category:
        cmd.extend(["--category", category])
    cmd.append("-y")

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout)
    if result.stderr:
        sys.stderr.write(result.stderr)
    if result.returncode != 0:
        print(f"[WARN] Custom skill install failed for {source}")
PY
  rm -f "$manifest_tmp"
}

install_custom_skills() {
  if [ "$CUSTOM_SKILLS_ENABLED" != "1" ]; then
    log_info "Skipping custom skill installation"
    return 0
  fi

  install_skills_from_manifest "$CUSTOM_SKILLS_MANIFEST" "custom skills"
}

bootstrap_chief_of_staff() {
  local parent_dir

  if [ "$CHIEF_OF_STAFF_ENABLED" != "1" ]; then
    return 0
  fi

  install_skills_from_manifest "$CHIEF_OF_STAFF_SKILLS_MANIFEST" "AI Chief of Staff skills"

  if [ -e "$CHIEF_OF_STAFF_HOME" ] && [ ! -d "$CHIEF_OF_STAFF_HOME" ]; then
    log_warn "Chief of Staff home path exists and is not a directory: $CHIEF_OF_STAFF_HOME"
    return 0
  fi

  if [ -d "$CHIEF_OF_STAFF_HOME" ] && find "$CHIEF_OF_STAFF_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    log_info "AI Chief of Staff vault already exists at $CHIEF_OF_STAFF_HOME; leaving it in place."
    return 0
  fi

  log_info "Bootstrapping AI Chief of Staff vault into $CHIEF_OF_STAFF_HOME"
  parent_dir="$(dirname "$CHIEF_OF_STAFF_HOME")"
  mkdir -p "$parent_dir"
  git clone --depth 1 "$CHIEF_OF_STAFF_REPO_URL" "$CHIEF_OF_STAFF_HOME" >/dev/null 2>&1 || {
    log_warn "Failed to clone AI Chief of Staff starter into $CHIEF_OF_STAFF_HOME"
    return 0
  }
  cat > "$CHIEF_OF_STAFF_HOME/LOCAL_HERMES_SETUP.md" <<EOF
# local-hermes Chief of Staff Setup

This vault was bootstrapped by local-hermes.

- Global Hermes skills from the starter repo were installed into \$HOME/.hermes/skills under the \`chief-of-staff\` category.
- Use Hermes from this directory when you want the starter vault's \`daily/\`, \`meetings/\`, \`concepts/\`, and \`meta/\` folders to be in scope.
EOF
}

main() {
  init_defaults
  parse_args "$@"
  detect_os
  validate_node_strategy
  require_cmd bash
  require_cmd curl
  require_cmd git

  if [ -e "$WRAPPER_PATH" ] && ! wrapper_owned; then
    die "Wrapper path is already occupied by an unmanaged file: $WRAPPER_PATH"
  fi

  if hermes_is_healthy; then
    log_info "Existing Hermes install is healthy; skipping reinstall."
  else
    log_info "Installing Hermes into $HERMES_HOME"
    run_installer
  fi

  log_info "Writing managed wrapper to $WRAPPER_PATH"
  rm -f "$WRAPPER_PATH"
  write_wrapper

  if docker_daemon_available; then
    log_info "Building sandbox image $IMAGE_TAG"
    build_sandbox_image
  else
    log_warn "Docker is unavailable; skipping sandbox image build"
  fi

  log_info "Applying managed Hermes terminal config"
  apply_terminal_config

  if hermes_is_healthy; then
    run_hermes --version >/dev/null
  else
    die "Hermes install did not produce a healthy runtime"
  fi

  install_custom_skills
  bootstrap_chief_of_staff

  collect_pending_steps
  print_pending_steps
}

main "$@"
