"""
GitHub webhook handler for automated deployments.
"""

# --------------------------------------------------------------------------------
# Imports
# --------------------------------------------------------------------------------

import hashlib
import hmac
import logging
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

import requests
from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request
from fastapi.responses import PlainTextResponse


# --------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DEPLOY_SCRIPT = PROJECT_ROOT / "scripts" / "deploy.sh"

DEPLOY_SCRIPT = os.getenv("DEPLOY_SCRIPT", str(DEFAULT_DEPLOY_SCRIPT))
DEPLOY_TIMEOUT_SECONDS = int(os.getenv("DEPLOY_TIMEOUT_SECONDS", "900"))
GITHUB_STATUS_CONTEXT = os.getenv("GITHUB_STATUS_CONTEXT", "catty-webhook-deploy")


# --------------------------------------------------------------------------------
# App Creation
# --------------------------------------------------------------------------------

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("catty.webhook")

app = FastAPI(
  title="Catty GitHub Webhook Handler",
  description="Receives GitHub webhook events and deploys the Catty app.",
  version="1.0.0",
)


# --------------------------------------------------------------------------------
# Private Functions
# --------------------------------------------------------------------------------

def _verify_signature(body: bytes, signature: Optional[str]) -> None:
  secret = os.getenv("WEBHOOK_SECRET")
  if not secret:
    return

  if not signature or not signature.startswith("sha256="):
    raise HTTPException(status_code=401, detail="Missing GitHub signature")

  digest = hmac.new(
    key=secret.encode("utf-8"),
    msg=body,
    digestmod=hashlib.sha256,
  ).hexdigest()
  expected = f"sha256={digest}"

  if not hmac.compare_digest(expected, signature):
    raise HTTPException(status_code=401, detail="Invalid GitHub signature")


def _branch_from_ref(ref: str) -> str:
  prefix = "refs/heads/"
  if not ref.startswith(prefix):
    raise ValueError(f"Unsupported ref: {ref}")
  return ref[len(prefix):]


def _repo_url_from_payload(payload: dict[str, Any]) -> Optional[str]:
  repository = payload.get("repository") or {}
  return repository.get("ssh_url") or repository.get("clone_url")


def _repo_full_name(payload: dict[str, Any]) -> Optional[str]:
  repository = payload.get("repository") or {}
  return repository.get("full_name")


def _set_github_status(
  payload: dict[str, Any],
  state: str,
  description: str,
) -> None:
  token = os.getenv("GITHUB_TOKEN")
  repo = _repo_full_name(payload)
  sha = payload.get("after")

  if not token or not repo or not sha:
    return

  response = requests.post(
    f"https://api.github.com/repos/{repo}/statuses/{sha}",
    headers={
      "Accept": "application/vnd.github+json",
      "Authorization": f"Bearer {token}",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    json={
      "state": state,
      "context": GITHUB_STATUS_CONTEXT,
      "description": description[:140],
    },
    timeout=10,
  )
  response.raise_for_status()


def _run_deploy(payload: dict[str, Any], branch: str, sha: str, delivery_id: str) -> None:
  logger.info("Starting deployment for delivery=%s branch=%s sha=%s", delivery_id, branch, sha)

  try:
    _set_github_status(payload, "pending", "Deployment started")
  except Exception:
    logger.exception("Could not set pending GitHub status")

  env = os.environ.copy()
  repo_url = _repo_url_from_payload(payload)
  if repo_url and not env.get("REPO_URL"):
    env["REPO_URL"] = repo_url

  try:
    result = subprocess.run(
      [DEPLOY_SCRIPT, branch, sha],
      env=env,
      text=True,
      capture_output=True,
      timeout=DEPLOY_TIMEOUT_SECONDS,
      check=True,
    )
    logger.info("Deployment finished for delivery=%s\n%s", delivery_id, result.stdout)
    _set_github_status(payload, "success", "Deployment finished")
  except Exception as exc:
    logger.exception("Deployment failed for delivery=%s", delivery_id)
    try:
      _set_github_status(payload, "failure", f"Deployment failed: {exc}")
    except Exception:
      logger.exception("Could not set failure GitHub status")


# --------------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------------

@app.get("/", response_class=PlainTextResponse)
async def healthcheck() -> str:
  """FRP healthcheck endpoint."""

  return "ok"


@app.post("/")
async def github_webhook(
  request: Request,
  background_tasks: BackgroundTasks,
  x_github_event: str = Header(default=""),
  x_github_delivery: str = Header(default=""),
  x_hub_signature_256: Optional[str] = Header(default=None),
) -> dict[str, str]:
  """Receives GitHub webhook events and starts deployment for push events."""

  body = await request.body()
  _verify_signature(body, x_hub_signature_256)

  try:
    payload = await request.json()
  except Exception:
    raise HTTPException(status_code=400, detail="Invalid JSON payload")

  if x_github_event == "ping":
    return {"status": "pong"}

  if x_github_event != "push":
    return {"status": "ignored", "event": x_github_event}

  try:
    branch = _branch_from_ref(payload["ref"])
  except Exception as exc:
    raise HTTPException(status_code=400, detail=str(exc))

  sha = payload.get("after", "")
  background_tasks.add_task(_run_deploy, payload, branch, sha, x_github_delivery)

  return {
    "status": "accepted",
    "branch": branch,
    "sha": sha,
  }