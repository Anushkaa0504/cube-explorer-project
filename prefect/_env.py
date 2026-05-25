"""Load project .env so Prefect flows see CUBEJS_API_SECRET without manual export."""
from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / ".env"


def load_project_env() -> None:
    if not ENV_FILE.exists():
        return
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def cube_api_url() -> str:
    return os.environ.get("CUBE_API_URL", "http://localhost:4000/cubejs-api").rstrip("/")


def default_security_context() -> dict:
    """Matches cube.js scheduledRefreshContexts + contextToApiScopes (analyst → jobs)."""
    return {
        "tenant_id": "default",
        "roles": ["analyst"],
        "user_id": 2,
    }
