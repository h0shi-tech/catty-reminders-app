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
APP_SERVICE="${APP_SERVICE:-catty-app.service}"
APP_RESTART_COMMAND="${APP_RESTART_COMMAND:-}"
APP_ENV_FILE="${APP_ENV_FILE:-$APP_DIR/.env}"
LOCK_FILE="${LOCK_FILE:-/tmp/catty-deploy.lock}"
LOCK_DIR="${LOCK_DIR:-/tmp/catty-deploy.lockdir}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RUN_TESTS="${RUN_TESTS:-1}"
TEST_COMMAND="${TEST_COMMAND:-.venv/bin/python -m pytest tests/test_unit.py}"

if [[ -z "$REPO_URL" ]]; then
  echo "REPO_URL is not set and could not be read from git remote origin" >&2
  exit 2
fi

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
git -C "$APP_DIR" reset --hard "origin/$BRANCH"

DEPLOYED_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"
if [[ -n "$REQUESTED_SHA" && "$DEPLOYED_SHA" != "$REQUESTED_SHA" ]]; then
  echo "Requested SHA $REQUESTED_SHA, deploying latest branch SHA $DEPLOYED_SHA"
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

touch "$APP_ENV_FILE"
if grep -q '^DEPLOY_REF=' "$APP_ENV_FILE"; then
  sed -i.bak "s/^DEPLOY_REF=.*/DEPLOY_REF=$DEPLOYED_SHA/" "$APP_ENV_FILE"
  rm -f "$APP_ENV_FILE.bak"
else
  printf 'DEPLOY_REF=%s\n' "$DEPLOYED_SHA" >> "$APP_ENV_FILE"
fi

if [[ -n "$APP_RESTART_COMMAND" ]]; then
  bash -lc "$APP_RESTART_COMMAND"
elif [[ -z "$APP_SERVICE" || "$APP_SERVICE" == "none" ]]; then
  echo "Skipping service restart"
elif [[ "$(id -u)" -eq 0 ]]; then
  systemctl restart "$APP_SERVICE"
else
  sudo systemctl restart "$APP_SERVICE"
fi

echo "Deployment completed at $DEPLOYED_SHA"