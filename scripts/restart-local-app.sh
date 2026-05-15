#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_ENV_FILE="${APP_ENV_FILE:-$APP_DIR/.env}"
APP_LOG_FILE="${APP_LOG_FILE:-$APP_DIR/.uvicorn.log}"

pkill -f "uvicorn app.main:app" 2>/dev/null || true

set -a
if [[ -f "$APP_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$APP_ENV_FILE"
fi
set +a

cd "$APP_DIR"
nohup "$APP_DIR/.venv/bin/python" -m uvicorn app.main:app --host 0.0.0.0 --port 8181 > "$APP_LOG_FILE" 2>&1 &
