"""
Trigger pre-aggregation rebuilds via Orchestration API (Prefect + prefect-cubejs).

Uses POST /cubejs-api/v1/pre-aggregations/jobs (requires `jobs` API scope from
cube.js contextToApiScopes — analyst JWT via security_context).

Prerequisites:
  - Cube up: make up && make ready
  - pip install -r prefect/requirements.txt

Run:
  python prefect/cube_build.py
  # or: make prefect-build
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from prefect import flow
from prefect_cubejs.tasks import build_pre_aggregations

from _env import cube_api_url, default_security_context, load_project_env

# Same selector we proved with curl; matches cube.js scheduledRefreshContexts.
BUILD_SELECTOR = {
    "timezones": ["UTC"],
    "contexts": [
        {
            "securityContext": {
                "tenant_id": "default",
                "roles": ["analyst"],
            }
        }
    ],
}


@flow(name="cube-explorer-build-pre-aggs")
def cube_build_workflow() -> bool | list:
    load_project_env()
    return build_pre_aggregations(
        url=cube_api_url(),
        api_secret_env_var="CUBEJS_API_SECRET",
        security_context=default_security_context(),
        selector=BUILD_SELECTOR,
        wait_for_job_run_completion=True,
        wait_time_between_api_calls=5,
    )


if __name__ == "__main__":
    out = cube_build_workflow()
    print("build result:", out)
