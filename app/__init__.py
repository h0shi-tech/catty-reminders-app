"""
This module builds shared parts for other modules.
"""

# --------------------------------------------------------------------------------
# Imports
# --------------------------------------------------------------------------------

import json
import os

from fastapi.templating import Jinja2Templates


# --------------------------------------------------------------------------------
# Read Configuration
# --------------------------------------------------------------------------------

with open('config.json') as config_json:
  config = json.load(config_json)
  users = config['users']
  db_path = config['db_path']


def _deploy_ref_candidate_paths() -> list[str]:
  """Paths deploy.sh may update (APP_ENV_FILE defaults to APP_DIR/.env)."""
  seen: set[str] = set()
  ordered: list[str] = []

  def add(path: str | None) -> None:
    if not path:
      return
    expanded = os.path.expanduser(path)
    if expanded in seen:
      return
    seen.add(expanded)
    ordered.append(expanded)

  add(os.getenv("DEPLOY_REF_FILE"))
  app_dir = os.getenv("APP_DIR")
  if app_dir:
    add(os.path.join(app_dir, ".env"))
  add(os.path.join(os.path.expanduser("~"), "catty-app-deploy", ".env"))
  return ordered


def get_deploy_ref() -> str:
  """
  Use DEPLOY_REF from the first readable env file (updated by deploy.sh without
  restarting uvicorn). Falls back to DEPLOY_REF in the process environment.
  """
  for path in _deploy_ref_candidate_paths():
    if not os.path.isfile(path):
      continue
    try:
      with open(path, encoding='utf-8') as handle:
        for line in handle:
          stripped = line.strip()
          if stripped.startswith('DEPLOY_REF=') and not stripped.startswith('#'):
            return stripped.split('=', 1)[1].strip().strip('"').strip("'")
    except OSError:
      continue
  return os.getenv("DEPLOY_REF", "NA")


DEPLOY_REF = os.getenv("DEPLOY_REF", "NA")

# --------------------------------------------------------------------------------
# Establish the Secret Key
# --------------------------------------------------------------------------------

secret_key = config['secret_key']


# --------------------------------------------------------------------------------
# Templates
# --------------------------------------------------------------------------------

templates = Jinja2Templates(directory="templates")
