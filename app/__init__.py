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
  db_config = config['db_config']

db_config = {
  'host': os.getenv('DB_HOST', db_config['host']),
  'port': int(os.getenv('DB_PORT', db_config['port'])),
  'user': os.getenv('DB_USER', db_config['user']),
  'password': os.getenv('DB_PASSWORD', db_config['password']),
  'database': os.getenv('DB_NAME', db_config['database']),
}

DEPLOY_REF = os.getenv("DEPLOY_REF", "NA")

# --------------------------------------------------------------------------------
# Establish the Secret Key
# --------------------------------------------------------------------------------

secret_key = config['secret_key']


# --------------------------------------------------------------------------------
# Templates
# --------------------------------------------------------------------------------

templates = Jinja2Templates(directory="templates")
