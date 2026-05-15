#!/usr/bin/env bash
# Deploy Catty stack (app + MariaDB) via Docker Compose after syncing the git tree.
set -Eeuo pipefail

main() {
  local branch="${1:-}"
  local target_sha="${2:-}"

  if [[ -z "$branch" ]]; then
    echo "Usage: $0 <branch> [commit-sha]" >&2
    return 2
  fi

  load_paths
  require_image
  acquire_deploy_lock

  echo "[deploy] branch=${branch} dir=${APP_ROOT} image=${CATTY_IMAGE}"
  ensure_repository "$branch" "$target_sha"
  run_optional_unit_tests
  publish_compose_stack
  echo "[deploy] finished at $(git -C "$APP_ROOT" rev-parse --short HEAD) with ${CATTY_IMAGE}"
}

load_paths() {
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  APP_ROOT="${APP_DIR:-/opt/catty/app}"
  GIT_REMOTE="${REPO_URL:-$(git -C "${script_root}/.." remote get-url origin 2>/dev/null || true)}"
  COMPOSE_SPEC="${COMPOSE_FILE_PATH:-${APP_ROOT}/docker-compose.yaml}"
  STACK_NAME="${COMPOSE_PROJECT_NAME:-catty-nikishin}"
  CATTY_IMAGE="${CATTY_IMAGE:-${IMAGE:-}}"
  REGISTRY_CONFIG="${DOCKER_CONFIG:-/tmp/catty-ghcr-auth-$$}"

  APP_CONTAINER="${CONTAINER_NAME:-catty-reminders-app}"
  DB_CONTAINER="${DB_CONTAINER_NAME:-catty-db}"
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  RUN_UNIT_TESTS="${RUN_TESTS:-1}"
  UNIT_TEST_CMD="${TEST_COMMAND:-.venv/bin/python -m pytest tests/test_unit.py}"

  DOCKER_BIN="${DOCKER_BIN:-}"
  COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-}"

  LOCK_PATH="${LOCK_FILE:-/tmp/catty-deploy.lock}"
  LOCK_DIR_PATH="${LOCK_DIR:-/tmp/catty-deploy.lockdir}"

  [[ -n "$GIT_REMOTE" ]] || {
    echo "REPO_URL is missing and origin remote is unavailable" >&2
    exit 2
  }
}

require_image() {
  [[ -n "$CATTY_IMAGE" ]] || {
    echo "IMAGE variable must point to the application container tag" >&2
    exit 2
  }
}

acquire_deploy_lock() {
  mkdir -p "$(dirname "$LOCK_PATH")"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_PATH"
    flock -x 9
    return
  fi
  until mkdir "$LOCK_DIR_PATH" 2>/dev/null; do sleep 1; done
  trap 'rmdir "$LOCK_DIR_PATH"' EXIT
}

ensure_repository() {
  local branch="$1"
  local sha="$2"

  if [[ ! -d "${APP_ROOT}/.git" ]]; then
    mkdir -p "$(dirname "$APP_ROOT")"
    git clone "$GIT_REMOTE" "$APP_ROOT"
  fi

  git -C "$APP_ROOT" fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$APP_ROOT" checkout -B "$branch" "origin/${branch}"

  if [[ -n "$sha" ]]; then
    git -C "$APP_ROOT" reset --hard "$sha"
  else
    git -C "$APP_ROOT" reset --hard "origin/${branch}"
  fi

  local head_sha
  head_sha="$(git -C "$APP_ROOT" rev-parse HEAD)"
  if [[ -n "$sha" && "$head_sha" != "$sha" ]]; then
    echo "Commit mismatch: wanted ${sha}, got ${head_sha}" >&2
    exit 1
  fi
}

run_optional_unit_tests() {
  [[ "$RUN_UNIT_TESTS" == "0" ]] && return 0

  if [[ ! -x "${APP_ROOT}/.venv/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "${APP_ROOT}/.venv"
  fi
  "${APP_ROOT}/.venv/bin/python" -m pip install --upgrade pip
  "${APP_ROOT}/.venv/bin/python" -m pip install -r "${APP_ROOT}/requirements.txt"
  (cd "$APP_ROOT" && bash -lc "$UNIT_TEST_CMD")
}

publish_compose_stack() {
  resolve_container_tools
  write_registry_config
  remove_legacy_containers

  export CATTY_IMAGE="$CATTY_IMAGE"
  stack compose -f "$COMPOSE_SPEC" --project-name "$STACK_NAME" pull
  stack compose -f "$COMPOSE_SPEC" --project-name "$STACK_NAME" up -d --remove-orphans
  docker_with_config image prune -af >/dev/null 2>&1 || true
}

resolve_container_tools() {
  local candidates=(
    "$DOCKER_BIN"
    "$(command -v docker 2>/dev/null || true)"
    /opt/homebrew/bin/docker
    /usr/local/bin/docker
  )
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] && DOCKER_BIN="$candidate" && break
  done
  [[ -n "$DOCKER_BIN" ]] || {
    echo "Docker CLI was not found on this host" >&2
    exit 1
  }
  export PATH="$(dirname "$DOCKER_BIN"):$PATH"
  export DOCKER_CONFIG="$REGISTRY_CONFIG"
}

write_registry_config() {
  rm -rf "$REGISTRY_CONFIG"
  mkdir -p "$REGISTRY_CONFIG"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo '{}' >"${REGISTRY_CONFIG}/config.json"
    return
  fi

  python3 - <<'PY' "${REGISTRY_CONFIG}/config.json" "${GITHUB_ACTOR:-github-actions}" "${GITHUB_TOKEN}"
import base64, json, pathlib, sys
path, actor, token = sys.argv[1:4]
payload = {
    "auths": {
        "ghcr.io": {
            "auth": base64.b64encode(f"{actor}:{token}".encode()).decode()
        }
    }
}
pathlib.Path(path).write_text(json.dumps(payload))
PY
}

remove_legacy_containers() {
  local name
  for name in "$APP_CONTAINER" "$DB_CONTAINER"; do
    docker_with_config rm -f "$name" 2>/dev/null || true
  done
}

docker_with_config() {
  "$DOCKER_BIN" --config "$REGISTRY_CONFIG" "$@"
}

stack() {
  if [[ -n "$COMPOSE_BIN" ]]; then
    "$COMPOSE_BIN" "$@"
    return
  fi
  if docker_with_config compose version >/dev/null 2>&1; then
    docker_with_config compose "$@"
    return
  fi
  local legacy=(
    "$(command -v docker-compose 2>/dev/null || true)"
    /opt/homebrew/bin/docker-compose
    /usr/local/bin/docker-compose
  )
  for bin in "${legacy[@]}"; do
    [[ -x "$bin" ]] && "$bin" "$@" && return
  done
  echo "Neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 1
}

main "$@"
