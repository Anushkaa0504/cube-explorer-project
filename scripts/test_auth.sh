#!/usr/bin/env bash
# Smoke test JSON-backed auth (config/users.json + cube.js).
set -euo pipefail

BASE="${CUBE_BASE:-http://localhost:4000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sign() {
  python3 "$ROOT/scripts/sign_jwt.py" "$1"
}

load() {
  local token="$1" query="$2"
  curl -fsS -G "$BASE/cubejs-api/v1/load" \
    -H "Authorization: $token" \
    --data-urlencode "query=$query"
}

echo "== User 1 (customer) – own posted_count =="
T1=$(sign 1)
load "$T1" '{"measures":["transactions.posted_count"]}' | jq '.data[0]'

echo
echo "== User 2 (analyst) – same measure, all users =="
T2=$(sign 2)
load "$T2" '{"measures":["transactions.posted_count"]}' | jq '.data[0]'

echo
echo "== User 5 (auditor) – meta hides masked user fields =="
T5=$(sign 5)
curl -fsS "$BASE/cubejs-api/v1/meta" -H "Authorization: $T5" \
  | jq '.cubes[] | select(.name=="users") | .dimensions | map(.name)'

echo
echo "Auth smoke test OK"
