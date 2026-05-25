"""
Cube MCP server.

Exposes the local Cube semantic layer as a set of MCP tools that any
MCP-compatible client (Cursor, Claude Desktop, Continue, etc.) can call.

Why MCP and not a raw HTTP tool?
  An LLM that talks to Cube via MCP gets *semantic-layer-aware* tools instead
  of raw SQL. Claude doesn't have to know how to join transactions to
  categories — it just calls `query(measures=["spending.expense"],
  dimensions=["spending.category_name"])` and Cube does the rest. That's
  the whole point: governed, consistent metrics across every consumer.

Transport: stdio. Cursor / Claude Desktop spawn this script as a subprocess
and talk JSON-RPC over its stdin/stdout. Nothing listens on a port.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

CUBE_BASE = os.environ.get("CUBE_BASE", "http://localhost:4000")
CUBE_SECRET = os.environ.get("CUBEJS_API_SECRET", "super-secret-please-change-me")
DEFAULT_TIMEOUT = float(os.environ.get("CUBE_TIMEOUT", "30"))

mcp = FastMCP("cube-finance")


def _sign_jwt(role: str | None, user_id: int | None) -> str | None:
    """HS256 JWT using stdlib only. Returns None if no claims requested."""
    if not role and user_id is None:
        return None
    payload: dict[str, Any] = {}
    if role:
        payload["role"] = role
    if user_id is not None:
        payload["user_id"] = user_id

    def b64(b: bytes) -> str:
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64(json.dumps(payload, separators=(",", ":")).encode())
    sig = b64(hmac.new(CUBE_SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest())
    return f"{header}.{body}.{sig}"


def _headers(role: str | None = None, user_id: int | None = None) -> dict[str, str]:
    h = {"Content-Type": "application/json"}
    token = _sign_jwt(role, user_id)
    if token:
        h["Authorization"] = token
    return h


async def _get(
    path: str,
    params: dict | None = None,
    role: str | None = None,
    user_id: int | None = None,
) -> dict:
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
        r = await client.get(
            f"{CUBE_BASE}{path}",
            params=params,
            headers=_headers(role=role, user_id=user_id),
        )
        r.raise_for_status()
        return r.json()


# -------------------------------------------------------------------------
# Tools
# -------------------------------------------------------------------------

@mcp.tool()
async def list_cubes() -> dict:
    """List every cube/view exposed by the Cube semantic layer.

    Returns a compact map: cube name -> {measures, dimensions, segments}.
    Always call this FIRST when you don't know the schema.
    """
    meta = await _get("/cubejs-api/v1/meta")
    return {
        "cubes": [
            {
                "name": c["name"],
                "type": c.get("type", "cube"),
                "public": c.get("public", True),
                "description": c.get("description"),
                "measures": [m["name"] for m in c.get("measures", [])],
                "dimensions": [d["name"] for d in c.get("dimensions", [])],
                "segments": [s["name"] for s in c.get("segments", [])],
            }
            for c in meta.get("cubes", [])
        ]
    }


@mcp.tool()
async def describe_member(member: str) -> dict:
    """Return the full metadata for one measure or dimension (e.g.
    'transactions.total_expense'): title, description, type, format,
    rolling_window settings, etc. Useful before composing queries."""
    meta = await _get("/cubejs-api/v1/meta")
    cube_name, _, member_name = member.partition(".")
    for c in meta.get("cubes", []):
        if c["name"] != cube_name:
            continue
        for kind in ("measures", "dimensions", "segments"):
            for m in c.get(kind, []):
                if m["name"] == member:
                    return {"kind": kind[:-1], **m}
    return {"error": f"member '{member}' not found"}


@mcp.tool()
async def query(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
    segments: list[str] | None = None,
    order: dict | None = None,
    limit: int = 100,
    role: str | None = None,
    user_id: int | None = None,
) -> dict:
    """Run a Cube query and return the rows.

    Args:
        measures: e.g. ['transactions.total_expense']
        dimensions: e.g. ['categories.name']
        time_dimensions: e.g. [{'dimension': 'transactions.transaction_date',
                                'granularity': 'month',
                                'dateRange': 'last 6 months'}]
        filters: e.g. [{'member': 'transactions.status', 'operator': 'equals',
                        'values': ['posted']}]
        segments: e.g. ['transactions.expenses_only']
        order: e.g. {'transactions.total_expense': 'desc'}
        limit: max rows (default 100)
        role: optional dev override; normally pass user_id only (roles from config/users.json)
        user_id: optional user_id claim for row-level security
    """
    q: dict[str, Any] = {"limit": limit}
    if measures: q["measures"] = measures
    if dimensions: q["dimensions"] = dimensions
    if time_dimensions: q["timeDimensions"] = time_dimensions
    if filters: q["filters"] = filters
    if segments: q["segments"] = segments
    if order: q["order"] = order

    # Cube returns {"error": "Continue wait"} for cold pre-aggs. Poll briefly.
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
        for _ in range(20):
            r = await client.get(
                f"{CUBE_BASE}/cubejs-api/v1/load",
                params={"query": json.dumps(q)},
                headers=_headers(role, user_id),
            )
            r.raise_for_status()
            data = r.json()
            if data.get("error") == "Continue wait":
                continue
            return {
                "rowCount": len(data.get("data", [])),
                "data": data.get("data", []),
                "usedPreAggregations": list(
                    (data.get("results", [{}])[0].get("usedPreAggregations") or {}).keys()
                ),
            }
    return {"error": "timed out waiting for query"}


@mcp.tool()
async def preview_sql(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
    limit: int = 100,
) -> dict:
    """Return the warehouse SQL that Cube would generate for a query,
    without executing it. Use to debug or to teach yourself Cube's
    join + aggregation behavior."""
    q: dict[str, Any] = {"limit": limit}
    if measures: q["measures"] = measures
    if dimensions: q["dimensions"] = dimensions
    if time_dimensions: q["timeDimensions"] = time_dimensions
    if filters: q["filters"] = filters

    data = await _get(
        "/cubejs-api/v1/sql",
        params={"query": json.dumps(q)},
        role=None,
        user_id=None,
    )
    sql = data.get("sql", {})
    return {
        "sql": sql.get("sql", [None])[0],
        "params": sql.get("sql", [None, None])[1] if isinstance(sql.get("sql"), list) else None,
    }


@mcp.tool()
async def dry_run(
    measures: list[str] | None = None,
    dimensions: list[str] | None = None,
    time_dimensions: list[dict] | None = None,
    filters: list[dict] | None = None,
) -> dict:
    """Validate a query without running it. Cube returns the normalized
    form + the query type (e.g. 'regularQuery', 'compareDateRangeQuery').
    Cheap sanity check before calling `query`."""
    q: dict[str, Any] = {}
    if measures: q["measures"] = measures
    if dimensions: q["dimensions"] = dimensions
    if time_dimensions: q["timeDimensions"] = time_dimensions
    if filters: q["filters"] = filters
    return await _get(
        "/cubejs-api/v1/dry-run",
        params={"query": json.dumps(q)},
        role=None,
        user_id=None,
    )


@mcp.tool()
async def list_pre_aggregations() -> dict:
    """Show in-flight + recent pre-aggregation build jobs from Cube Store.
    Helps debug 'why is my dashboard slow?' (cold partition?  failed build?)."""
    # System endpoint expects any valid JWT
    headers = {"Authorization": _sign_jwt("admin", 0) or ""}
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT) as client:
        r = await client.get(
            f"{CUBE_BASE}/cubejs-system/v1/pre-aggregations/jobs", headers=headers
        )
        r.raise_for_status()
        return {"jobs": r.json()}


if __name__ == "__main__":
    mcp.run()
