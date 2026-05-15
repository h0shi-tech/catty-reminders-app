#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="${1:-}"
REQUESTED_SHA="${2:-}"

if [[ -z "$BRANCH" ]]; then
  echo "Usage: $0 <branch> [sha]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_URL="$(git -C "$SCRIPT_DIR/.." remote get-url origin 2>/dev/null || true)"

REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
APP_DIR="${APP_DIR:-/opt/catty/app}"
IMAGE="${IMAGE:-}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-$APP_DIR/docker-compose.yaml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-catty}"
CONTAINER_NAME="${CONTAINER_NAME:-catty-reminders-app}"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-catty-db}"
DOCKER_BIN="${DOCKER_BIN:-}"
DOCKER_COMPOSE_BIN="${DOCKER_COMPOSE_BIN:-}"
LOCK_FILE="${LOCK_FILE:-/tmp/catty-deploy.lock}"
LOCK_DIR="${LOCK_DIR:-/tmp/catty-deploy.lockdir}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RUN_TESTS="${RUN_TESTS:-1}"
TEST_COMMAND="${TEST_COMMAND:-.venv/bin/python -m pytest tests/test_unit.py}"

if [[ -z "$REPO_URL" ]]; then
  echo "REPO_URL is not set and could not be read from git remote origin" >&2
  exit 2
fi

docker_cli() {
  "$DOCKER_BIN" --config "$DOCKER_CONFIG" "$@"
}

setup_ghcr_auth() {
  DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/catty-docker-config-$$}"
  rm -rf "$DOCKER_CONFIG"
  mkdir -p "$DOCKER_CONFIG"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    printf '%s\n' '{}' > "$DOCKER_CONFIG/config.json"
    return
  fi

  local auth
  auth=$(printf '%s' "${GITHUB_ACTOR:-github-actions}:${GITHUB_TOKEN}" | base64 | tr -d '\n')
  cat > "$DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {
    "ghcr.io": {
      "auth": "${auth}"
    }
  }
}
EOF
}

run_docker_deploy() {
  if [[ -z "$IMAGE" ]]; then
    echo "IMAGE is required for compose deployment" >&2
    exit 1
  fi

  if [[ -z "$DOCKER_BIN" ]]; then
    DOCKER_BIN="$(command -v docker || true)"
  fi
  if [[ -z "$DOCKER_BIN" && -x /opt/homebrew/bin/docker ]]; then
    DOCKER_BIN="/opt/homebrew/bin/docker"
  fi
  if [[ -z "$DOCKER_BIN" && -x /usr/local/bin/docker ]]; then
    DOCKER_BIN="/usr/local/bin/docker"
  fi
  if [[ -z "$DOCKER_BIN" ]]; then
    echo "docker command not found" >&2
    exit 1
  fi

  export PATH="$(dirname "$DOCKER_BIN"):$PATH"
  setup_ghcr_auth

  compose() {
    if [[ -n "$DOCKER_COMPOSE_BIN" ]]; then
      "$DOCKER_COMPOSE_BIN" "$@"
    elif docker_cli compose version >/dev/null 2>&1; then
      docker_cli compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
      "$(command -v docker-compose)" "$@"
    elif [[ -x /opt/homebrew/bin/docker-compose ]]; then
      /opt/homebrew/bin/docker-compose "$@"
    elif [[ -x /usr/local/bin/docker-compose ]]; then
      /usr/local/bin/docker-compose "$@"
    else
      echo "docker compose command not found" >&2
      exit 1
    fi
  }

  if [[ ! -f "$COMPOSE_FILE_PATH" ]]; then
    echo "docker compose file not found at $COMPOSE_FILE_PATH" >&2
    exit 1
  fi

  docker_cli stop "$CONTAINER_NAME" 2>/dev/null || true
  docker_cli rm "$CONTAINER_NAME" 2>/dev/null || true
  docker_cli stop "$DB_CONTAINER_NAME" 2>/dev/null || true
  docker_cli rm "$DB_CONTAINER_NAME" 2>/dev/null || true

  export IMAGE
  compose -f "$COMPOSE_FILE_PATH" --project-name "$COMPOSE_PROJECT_NAME" pull
  compose -f "$COMPOSE_FILE_PATH" --project-name "$COMPOSE_PROJECT_NAME" up -d --remove-orphans
  docker_cli image prune -af >/dev/null 2>&1 || true
}

mkdir -p "$(dirname "$LOCK_FILE")"
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  flock -x 200
else
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 1
  done
  trap 'rmdir "$LOCK_DIR"' EXIT
fi

echo "Deploying branch '$BRANCH' from '$REPO_URL' into '$APP_DIR'"

if [[ ! -d "$APP_DIR/.git" ]]; then
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$REPO_URL" "$APP_DIR"
fi

git -C "$APP_DIR" fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'
git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
if [[ -n "$REQUESTED_SHA" ]]; then
  git -C "$APP_DIR" reset --hard "$REQUESTED_SHA"
else
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
fi

DEPLOYED_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"
if [[ -n "$REQUESTED_SHA" && "$DEPLOYED_SHA" != "$REQUESTED_SHA" ]]; then
  echo "Requested SHA $REQUESTED_SHA, deployed SHA $DEPLOYED_SHA" >&2
  exit 1
fi

if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/.venv"
fi

"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/.venv/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

if [[ "$RUN_TESTS" != "0" ]]; then
  (
    cd "$APP_DIR"
    bash -lc "$TEST_COMMAND"
  )
fi

run_docker_deploy
echo "Docker Compose deployment completed at $DEPLOYED_SHA with $IMAGE"
