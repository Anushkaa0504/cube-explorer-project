"""
Query Cube via REST /v1/load (Prefect + prefect-cubejs).

Prerequisites:
  - Cube up: make up && make ready
  - pip install -r prefect/requirements.txt  (or: make prefect-install)

Run:
  prefect/cube_query.py
  # or: make prefect-query
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from prefect import flow
from prefect_cubejs.tasks import run_query

from _env import cube_api_url, default_security_context, load_project_env


@flow(name="cube-explorer-query")
def cube_query_workflow() -> dict:
    load_project_env()
    return run_query(
        url=cube_api_url(),
        api_secret_env_var="CUBEJS_API_SECRET",
        security_context=default_security_context(),
        query={
            "measures": ["transactions.posted_count", "transactions.total_expense"],
            "dimensions": ["transactions.status"],
            "order": {"transactions.posted_count": "desc"},
            "limit": 10,
        },
        wait_time_between_api_calls=2,
        max_wait_time=120,
    )


if __name__ == "__main__":
    result = cube_query_workflow()
    data = result.get("data") if isinstance(result, dict) else result
    print("rows:", len(data) if data else 0)
    if data:
        print("first row:", data[0])
