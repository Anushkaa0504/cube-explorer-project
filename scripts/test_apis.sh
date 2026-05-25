#!/usr/bin/env bash
# Quick smoke test for every Cube API surface.
# Requires `jq` and `curl`. Cube's REST endpoint may return "Continue wait"
# for cold queries; the load_with_retry helper handles that transparently.
#
# Usage:  ./scripts/test_apis.sh
set -euo pipefail

BASE=http://localhost:4000

load_with_retry() {
  local q="$1"
  for _ in $(seq 1 30); do
    local out
    out=$(curl -s -G "$BASE/cubejs-api/v1/load" --data-urlencode "query=$q")
    local err
    err=$(jq -r '.error // empty' <<<"$out")
    if [[ "$err" == "Continue wait" ]]; then
      sleep 2
      continue
    fi
    echo "$out"
    return 0
  done
  echo "Timed out waiting for Cube" >&2
  return 1
}

echo "== REST API – meta =="
curl -s "$BASE/cubejs-api/v1/meta" | jq '.cubes | map(.name) | sort'

echo
echo "== REST API – KPIs (income / expense / net / savings rate) =="
load_with_retry '{
  "measures": [
    "transactions.total_income",
    "transactions.total_expense",
    "transactions.net_cashflow",
    "transactions.savings_rate"
  ]
}' | jq '.data'

echo
echo "== REST API – top 5 spending categories =="
load_with_retry '{
  "measures": ["transactions.total_expense"],
  "dimensions": ["categories.name"],
  "segments": ["transactions.expenses_only"],
  "order": {"transactions.total_expense":"desc"},
  "limit": 5
}' | jq '.data'

echo
echo "== REST API – cashflow by month (last 6 months) =="
load_with_retry '{
  "measures": ["transactions.total_income", "transactions.total_expense"],
  "timeDimensions": [{
    "dimension": "transactions.transaction_date",
    "granularity": "month",
    "dateRange": "last 6 months"
  }]
}' | jq '.data'

echo
echo "== GraphQL API – categories with transaction counts =="
curl -s -X POST "$BASE/cubejs-api/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ cube { categories { name } transactions { count status } } }"}' \
  | jq '.data.cube | length'

echo
echo "== SQL API (requires psql) =="
if command -v psql >/dev/null 2>&1; then
  PGPASSWORD=cube psql "postgres://cube@localhost:15432/cube" \
    -c "SELECT status, MEASURE(count) FROM transactions GROUP BY status LIMIT 5;"
else
  echo "psql not installed – skipping"
fi
