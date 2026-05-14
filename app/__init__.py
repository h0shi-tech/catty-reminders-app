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


def get_deploy_ref() -> str:
  """
  Prefer DEPLOY_REF from DEPLOY_REF_FILE when set (updated by deploy.sh without
  restarting uvicorn). Otherwise use the DEPLOY_REF environment variable.
  """
  env_file = os.getenv("DEPLOY_REF_FILE")
  if env_file:
    path = os.path.expanduser(env_file)
    if os.path.isfile(path):
      try:
        with open(path, encoding='utf-8') as handle:
          for line in handle:
            stripped = line.strip()
            if stripped.startswith('DEPLOY_REF=') and not stripped.startswith('#'):
              return stripped.split('=', 1)[1].strip().strip('"').strip("'")
      except OSError:
        pass
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
