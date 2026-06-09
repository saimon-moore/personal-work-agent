#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "Expected $file to contain: $pattern"
}

assert_path_exists() {
  [ -e "$1" ] || fail "Expected path to exist: $1"
}

assert_path_missing() {
  [ ! -e "$1" ] || fail "Expected path to be missing: $1"
}

make_fake_installer() {
  local root="$1"
  cat > "$root/fake-installer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HERMES_HOME/hermes-agent/venv/bin" "$HERMES_HOME" "$HOME/.local/bin"
printf '%s\n' "$PWD" > "$HERMES_HOME/install_pwd"
printf '%s\n' "$PATH" > "$HERMES_HOME/install_path"
printf '%s\n' "$*" > "$HERMES_HOME/install_args"
count=0
if [ -f "$HERMES_HOME/install_count" ]; then
  count="$(cat "$HERMES_HOME/install_count")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$HERMES_HOME/install_count"
cat > "$HERMES_HOME/hermes-agent/venv/bin/hermes" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
cfg="${HERMES_HOME:-$HOME/.hermes}/config.yaml"
skills_log="${HERMES_HOME:-$HOME/.hermes}/skills_log"
case "${1:-}" in
  --version)
    printf 'hermes-test 0.1.0\n'
    ;;
  skills)
    printf '%s\n' "$*" >> "$skills_log"
    if [ "${2:-}" = "install" ] && [ "${3:-}" = "${LOCAL_HERMES_TEST_FAIL_SKILL_URL:-}" ]; then
      printf 'simulated skills install failure\n' >&2
      exit 1
    fi
    printf 'hermes-test skills ok\n'
    ;;
  config)
    case "${2:-}" in
      show|"")
        cat "$cfg"
        ;;
      path)
        printf '%s\n' "$cfg"
        ;;
      check)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    printf 'hermes-test ok\n'
    ;;
esac
INNER
chmod +x "$HERMES_HOME/hermes-agent/venv/bin/hermes"
cat > "$HERMES_HOME/hermes-agent/venv/bin/python3" <<'INNER'
#!/usr/bin/env bash
exec python3 "$@"
INNER
chmod +x "$HERMES_HOME/hermes-agent/venv/bin/python3"
cat > "$HERMES_HOME/hermes-agent/venv/bin/python" <<'INNER'
#!/usr/bin/env bash
exec python3 "$@"
INNER
chmod +x "$HERMES_HOME/hermes-agent/venv/bin/python"
cat > "$HERMES_HOME/config.yaml" <<'INNER'
model:
  provider: "auto"
terminal:
  backend: "local"
INNER
cat > "$HERMES_HOME/.env" <<'INNER'
OPENROUTER_API_KEY=your-token-here
INNER
cat > "$HOME/.local/bin/hermes" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
chmod +x "$HOME/.local/bin/hermes"
if [ "${LOCAL_HERMES_TEST_CREATE_MANAGED_NODE:-0}" = "1" ]; then
  mkdir -p "$HERMES_HOME/node/bin"
  cat > "$HERMES_HOME/node/bin/node" <<'INNER'
#!/usr/bin/env bash
printf 'v22.99.0\n'
INNER
  chmod +x "$HERMES_HOME/node/bin/node"
fi
EOF
  chmod +x "$root/fake-installer.sh"
}

make_fake_curl() {
  local root="$1"
  cat > "$root/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
case "$url" in
  https://example.com/custom-skills.json)
    cp "$LOCAL_HERMES_TEST_MANIFEST_PATH" "$out"
    ;;
  *)
    cp "$LOCAL_HERMES_TEST_INSTALLER" "$out"
    ;;
esac
EOF
  chmod +x "$root/curl"
}

make_fake_git() {
  local root="$1"
  cat > "$root/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${LOCAL_HERMES_TEST_GIT_LOG:?}"
if [ "${1:-}" = "clone" ]; then
  target="${@: -1}"
  mkdir -p "$target"
  if [ -n "${LOCAL_HERMES_TEST_CHIEF_TEMPLATE:-}" ]; then
    cp -R "${LOCAL_HERMES_TEST_CHIEF_TEMPLATE}/." "$target/"
  fi
fi
exit 0
EOF
  chmod +x "$root/git"
}

make_fake_docker() {
  local root="$1"
  cat > "$root/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${LOCAL_HERMES_TEST_DOCKER_STATE:?}"
cmd="${1:-}"
shift || true
case "$cmd" in
  info)
    exit 0
    ;;
  build)
    tag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t)
          tag="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s\n' "$tag" > "$state/image_tag"
    exit 0
    ;;
  image)
    sub="${1:-}"
    shift || true
    case "$sub" in
      inspect)
        [ -f "$state/image_tag" ] && [ "${1:-}" = "$(cat "$state/image_tag")" ]
        ;;
      rm)
        rm -f "$state/image_tag"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  run)
    image=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --rm)
          shift
          ;;
        *)
          image="$1"
          shift
          break
          ;;
      esac
    done
    [ "$image" = "$(cat "$state/image_tag")" ] || exit 1
    case "${1:-}" in
      node)
        printf 'v24.0.0\n'
        ;;
      python3)
        printf 'Python 3.11.0\n'
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$root/docker"
}

make_fake_mise() {
  local root="$1"
  cat > "$root/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${LOCAL_HERMES_TEST_MISE_LOG:?}"
if [ "${1:-}" = "exec" ]; then
  shift
  if [ "${1:-}" = "-C" ]; then
    shift 2
  fi
  if [ "${1:-}" = "node@lts" ]; then
    shift
  fi
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  if [ "${1:-}" = "node" ] && [ "${2:-}" = "-v" ]; then
    printf 'v24.14.1\n'
    exit 0
  fi
  exec "$@"
fi
exit 0
EOF
  chmod +x "$root/mise"
}

run_install_with_fakes() {
  local home_dir="$1"
  local bin_dir="$2"
  local state_dir="$3"
  PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" \
  HERMES_HOME="$home_dir/.hermes" \
  WRAPPER_PATH="$home_dir/.local/bin/hermes" \
  LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
  LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
  LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" \
  CUSTOM_SKILLS_MANIFEST="$state_dir/default-skills.json" \
  bash "$REPO_DIR/install.sh" --non-interactive > "$state_dir/install.out" 2>&1
}

run_install_with_extra_args() {
  local home_dir="$1"
  local bin_dir="$2"
  local state_dir="$3"
  shift 3
  PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" \
  HERMES_HOME="$home_dir/.hermes" \
  WRAPPER_PATH="$home_dir/.local/bin/hermes" \
  LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
  LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
  LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" \
  CUSTOM_SKILLS_MANIFEST="$state_dir/default-skills.json" \
  bash "$REPO_DIR/install.sh" --non-interactive "$@" > "$state_dir/install.out" 2>&1
}

make_manifest() {
  local path="$1"
  cat > "$path" <<'EOF'
{
  "skills": [
    {
      "url": "https://example.com/skills/alpha/SKILL.md",
      "name": "alpha-skill",
      "category": "research/tools"
    },
    {
      "url": "https://example.com/skills/bravo/SKILL.md"
    },
    {
      "url": "https://example.com/skills/disabled/SKILL.md",
      "enabled": false
    },
    {
      "name": "missing-url"
    }
  ]
}
EOF
}

make_identifier_manifest() {
  local path="$1"
  cat > "$path" <<'EOF'
{
  "skills": [
    {
      "identifier": "octocat/skills/collaboration/msteams",
      "name": "msteams",
      "category": "collaboration/tools"
    },
    {
      "url": "https://github.com/octocat/skills/tree/main/collaboration/msteams",
      "name": "msteams-tree",
      "category": "collaboration/tools"
    }
  ]
}
EOF
}

make_chief_of_staff_template() {
  local root="$1"
  mkdir -p "$root/daily" "$root/meta" "$root/meetings" "$root/working" "$root/concepts"
  cat > "$root/README.md" <<'EOF'
# AI Chief of Staff — Starter
EOF
  cat > "$root/AGENTS.md" <<'EOF'
# AGENTS
EOF
  cat > "$root/meta/goals.md" <<'EOF'
# Goals
EOF
}

test_install_with_mise() {
  local root home_dir bin_dir state_dir
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_fake_mise "$bin_dir"
  make_manifest "$state_dir/default-skills.json"

  run_install_with_fakes "$home_dir" "$bin_dir" "$state_dir"

  assert_path_exists "$home_dir/.local/bin/hermes"
  assert_file_contains "$home_dir/.local/bin/hermes" "# managed-by: local-hermes"
  assert_file_contains "$home_dir/.hermes/config.yaml" 'backend: "docker"'
  assert_file_contains "$home_dir/.hermes/config.yaml" 'docker_image: "local-hermes-sandbox:node-lts"'
  assert_file_contains "$home_dir/.hermes/config.yaml" '"--network=none"'
  assert_file_contains "$home_dir/.hermes/install_pwd" "$home_dir"
  assert_file_contains "$home_dir/.hermes/install_path" "$home_dir/.local/bin"
  assert_file_contains "$home_dir/.hermes/install_args" "--skip-browser --skip-setup --non-interactive"
  assert_file_contains "$state_dir/mise.log" "exec -C $home_dir node@lts -- bash"
  [ "$(cat "$home_dir/.hermes/install_count")" = "1" ] || fail "Expected single installer run"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install https://example.com/skills/alpha/SKILL.md --name alpha-skill --category research/tools -y"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install https://example.com/skills/bravo/SKILL.md -y"
  if grep -Fq "disabled" "$home_dir/.hermes/skills_log"; then
    fail "Disabled manifest entries should be skipped"
  fi
  assert_file_contains "$state_dir/install.out" "Skipping custom skill manifest entry without url or identifier"

  PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_HOME="$home_dir/.hermes" WRAPPER_PATH="$home_dir/.local/bin/hermes" LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" bash "$REPO_DIR/doctor.sh" --json > "$state_dir/doctor.json"
  assert_file_contains "$state_dir/doctor.json" '"hermes_installed":true'
  assert_file_contains "$state_dir/doctor.json" '"wrapper_managed":true'
  assert_file_contains "$state_dir/doctor.json" '"node_mode":"mise"'

  run_install_with_fakes "$home_dir" "$bin_dir" "$state_dir"
  [ "$(cat "$home_dir/.hermes/install_count")" = "1" ] || fail "Expected reinstall to be skipped"
}

test_install_without_mise_and_uninstall() {
  local root home_dir bin_dir state_dir
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_manifest "$state_dir/default-skills.json"

  PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" \
  HERMES_HOME="$home_dir/.hermes" \
  WRAPPER_PATH="$home_dir/.local/bin/hermes" \
  LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
  LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
  LOCAL_HERMES_TEST_CREATE_MANAGED_NODE=1 \
  bash "$REPO_DIR/install.sh" --non-interactive --node-strategy ambient > "$state_dir/install.out" 2>&1

  assert_file_contains "$home_dir/.local/bin/hermes" 'HERMES_HOME="${HERMES_HOME:-'"$home_dir/.hermes"'}"'
  PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_HOME="$home_dir/.hermes" WRAPPER_PATH="$home_dir/.local/bin/hermes" "$home_dir/.local/bin/hermes" --version > "$state_dir/version.out"
  assert_file_contains "$state_dir/version.out" "hermes-test 0.1.0"

  PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_HOME="$home_dir/.hermes" WRAPPER_PATH="$home_dir/.local/bin/hermes" LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" bash "$REPO_DIR/uninstall.sh" --node-strategy ambient > "$state_dir/uninstall.out" 2>&1
  assert_path_missing "$home_dir/.hermes"
  assert_path_missing "$home_dir/.local/bin/hermes"
}

test_unmanaged_wrapper_conflict() {
  local root home_dir bin_dir state_dir
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  printf '#!/usr/bin/env bash\n' > "$home_dir/.local/bin/hermes"
  chmod +x "$home_dir/.local/bin/hermes"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_HOME="$home_dir/.hermes" WRAPPER_PATH="$home_dir/.local/bin/hermes" LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" bash "$REPO_DIR/install.sh" --non-interactive > "$state_dir/conflict.out" 2>&1; then
    fail "Expected install to fail on unmanaged wrapper conflict"
  fi
  assert_file_contains "$state_dir/conflict.out" "unmanaged file"
}

test_skip_custom_skills_and_manifest_override() {
  local root home_dir bin_dir state_dir manifest
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  manifest="$root/custom-skills.json"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_manifest "$state_dir/default-skills.json"
  make_manifest "$manifest"

  run_install_with_extra_args "$home_dir" "$bin_dir" "$state_dir" --skills-manifest "$manifest"
  assert_path_exists "$home_dir/.hermes/skills_log"
  assert_file_contains "$state_dir/install.out" "Installing custom skills from $manifest"

  rm -rf "$home_dir/.hermes"
  mkdir -p "$state_dir/docker"
  run_install_with_extra_args "$home_dir" "$bin_dir" "$state_dir" --skip-custom-skills
  assert_path_missing "$home_dir/.hermes/skills_log"
  assert_file_contains "$state_dir/install.out" "Skipping custom skill installation"
}

test_custom_skill_failures_are_best_effort() {
  local root home_dir bin_dir state_dir manifest
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  manifest="$root/custom-skills.json"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_manifest "$manifest"

  if ! PATH="$bin_dir:/usr/bin:/bin" \
    HOME="$home_dir" \
    HERMES_HOME="$home_dir/.hermes" \
    WRAPPER_PATH="$home_dir/.local/bin/hermes" \
    LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
    LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
    LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" \
    LOCAL_HERMES_TEST_FAIL_SKILL_URL="https://example.com/skills/alpha/SKILL.md" \
    bash "$REPO_DIR/install.sh" --non-interactive --skills-manifest "$manifest" > "$state_dir/install.out" 2>&1; then
    fail "Expected install to continue after custom skill failure"
  fi
  assert_file_contains "$state_dir/install.out" "Custom skill install failed for https://example.com/skills/alpha/SKILL.md"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install https://example.com/skills/bravo/SKILL.md -y"
}

test_manifest_url_override() {
  local root home_dir bin_dir state_dir manifest
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  manifest="$root/custom-skills.json"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_manifest "$manifest"

  PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" \
  HERMES_HOME="$home_dir/.hermes" \
  WRAPPER_PATH="$home_dir/.local/bin/hermes" \
  LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
  LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
  LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" \
  LOCAL_HERMES_TEST_MANIFEST_PATH="$manifest" \
  bash "$REPO_DIR/install.sh" --non-interactive --skills-manifest https://example.com/custom-skills.json > "$state_dir/install.out" 2>&1

  assert_file_contains "$state_dir/install.out" "Installing custom skills from https://example.com/custom-skills.json"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install https://example.com/skills/alpha/SKILL.md --name alpha-skill --category research/tools -y"
}

test_identifier_and_github_tree_skill_sources() {
  local root home_dir bin_dir state_dir manifest
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  manifest="$root/custom-skills.json"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_identifier_manifest "$manifest"

  run_install_with_extra_args "$home_dir" "$bin_dir" "$state_dir" --skills-manifest "$manifest"

  assert_file_contains "$home_dir/.hermes/skills_log" "skills install octocat/skills/collaboration/msteams --name msteams --category collaboration/tools -y"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install octocat/skills/collaboration/msteams --name msteams-tree --category collaboration/tools -y"
}

test_with_chief_of_staff_bootstraps_vault_and_installs_skills() {
  local root home_dir bin_dir state_dir chief_template chief_home
  root="$(mktemp -d /tmp/local-hermes-test.XXXXXX)"
  home_dir="$root/home"
  bin_dir="$root/bin"
  state_dir="$root/state"
  chief_template="$root/chief-template"
  chief_home="$home_dir/chief-of-staff"
  mkdir -p "$home_dir/.local/bin" "$bin_dir" "$state_dir/docker"
  make_fake_installer "$state_dir"
  make_fake_curl "$bin_dir"
  make_fake_docker "$bin_dir"
  make_fake_git "$bin_dir"
  make_manifest "$state_dir/default-skills.json"
  make_chief_of_staff_template "$chief_template"

  PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" \
  HERMES_HOME="$home_dir/.hermes" \
  WRAPPER_PATH="$home_dir/.local/bin/hermes" \
  LOCAL_HERMES_TEST_INSTALLER="$state_dir/fake-installer.sh" \
  LOCAL_HERMES_TEST_DOCKER_STATE="$state_dir/docker" \
  LOCAL_HERMES_TEST_MISE_LOG="$state_dir/mise.log" \
  LOCAL_HERMES_TEST_GIT_LOG="$state_dir/git.log" \
  LOCAL_HERMES_TEST_CHIEF_TEMPLATE="$chief_template" \
  CUSTOM_SKILLS_MANIFEST="$state_dir/default-skills.json" \
  bash "$REPO_DIR/install.sh" --non-interactive --with-chief-of-staff > "$state_dir/install.out" 2>&1

  assert_file_contains "$home_dir/.hermes/skills_log" "skills install casim/ai-chief-of-staff-starter/.claude/skills/plan-my-day --category chief-of-staff -y"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install casim/ai-chief-of-staff-starter/.claude/skills/weekly-review --category chief-of-staff -y"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install casim/ai-chief-of-staff-starter/.claude/skills/review-against-concept --category chief-of-staff -y"
  assert_file_contains "$home_dir/.hermes/skills_log" "skills install casim/ai-chief-of-staff-starter/.claude/skills/sync --category chief-of-staff -y"
  assert_path_exists "$chief_home/README.md"
  assert_path_exists "$chief_home/AGENTS.md"
  assert_path_exists "$chief_home/meta/goals.md"
  assert_file_contains "$state_dir/git.log" "clone --depth 1 https://github.com/casim/ai-chief-of-staff-starter.git $chief_home"
  assert_file_contains "$state_dir/install.out" "Bootstrapping AI Chief of Staff vault into $chief_home"
}

test_install_with_mise
test_install_without_mise_and_uninstall
test_unmanaged_wrapper_conflict
test_skip_custom_skills_and_manifest_override
test_custom_skill_failures_are_best_effort
test_manifest_url_override
test_identifier_and_github_tree_skill_sources
test_with_chief_of_staff_bootstraps_vault_and_installs_skills
printf 'PASS\n'
