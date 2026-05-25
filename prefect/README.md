# Prefect + Cube (Orchestration API)

Push-based pre-aggregation refresh and smoke queries against the local Cube
instance, using [prefect-cubejs](https://github.com/alessandrolollo/prefect-cubejs).

## Prerequisites

- Cube running: `make up && make ready`
- `cube.js` includes `contextToApiScopes` (grants `jobs` scope to analyst/admin)
- `.env` with `CUBEJS_API_SECRET` (flows load it automatically)

## Install

```bash
make prefect-install
```

The venv is created under **`~/.cache/cube-explorer/prefect-venv`** (not `prefect/.venv`)
so any Linux user (e.g. `modernadmin`) can install without write access to files
owned by another account. If you see `Permission denied` on `prefect/.venv`, ignore
that path — use `make prefect-install` again after pulling this Makefile change.

## Run flows

```bash
make prefect-query   # POST /v1/load — transaction counts by status
make prefect-build   # POST /v1/pre-aggregations/jobs — rebuild all pre-aggs, wait until done
```

Or directly (after `make prefect-install`):

```bash
~/.cache/cube-explorer/prefect-venv/bin/python prefect/cube_query.py
~/.cache/cube-explorer/prefect-venv/bin/python prefect/cube_build.py
```

## Self-hosted vs Cube docs

| Cube docs (Cloud) | This project |
|-------------------|--------------|
| `url=.../cubejs-api` | `http://localhost:4000/cubejs-api` |
| `api_secret=SECRET` | `CUBEJS_API_SECRET` from `.env` (via `api_secret_env_var`) |
| `Orders.count` | `transactions.posted_count`, etc. |
| `/cubejs-system/...` | **`/cubejs-api/v1/pre-aggregations/jobs`** (Cube 1.x) |

`build_pre_aggregations` signs a JWT with `CUBEJS_API_SECRET` and embeds
`security_context` (analyst role) so `contextToApiScopes` grants the `jobs` scope.

## Equivalent curl (no Prefect)

```bash
export SYS=$(python3 scripts/sign_jwt.py --system)
curl -s -X POST http://localhost:4000/cubejs-api/v1/pre-aggregations/jobs \
  -H "Authorization: $SYS" -H "Content-Type: application/json" \
  -d '{"action":"post","selector":{"timezones":["UTC"],"contexts":[{"securityContext":{"tenant_id":"default","roles":["analyst"]}}]}}'
```
