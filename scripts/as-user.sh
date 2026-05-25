#!/usr/bin/env bash
# Query Cube as a demo user from identity.json (no shell aliases needed).
#
# Usage:
#   bash scripts/as-user.sh 1 '{"dimensions":["users.email"],"limit":2}'
#   bash scripts/as-user.sh 2 '{"measures":["transactions.posted_count"]}'
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

BASE="${CUBE_BASE:-http://localhost:4000}"
USER_ID="${1:?Usage: as-user.sh USER_ID 'JSON_QUERY'}"
QUERY="${2:?Usage: as-user.sh USER_ID 'JSON_QUERY'}"
shift 2 || true

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install: sudo apt install jq" >&2
  exit 1
fi

# Cube still starting?
if ! curl -fsS "$BASE/readyz" >/dev/null 2>&1 && \
   ! curl -fsS "$BASE/livez" >/dev/null 2>&1 && \
   ! curl -fsS "$BASE" >/dev/null 2>&1; then
  echo "Cube is not reachable at $BASE" >&2
  echo "Run: docker compose up -d && sleep 30 && docker compose logs cube | tail -30" >&2
  exit 1
fi

TOKEN="$(python3 "$ROOT/scripts/sign_jwt.py" "$USER_ID")"
echo "# user_id=$USER_ID  BASE=$BASE" >&2

load_with_retry() {
  local attempt=1
  while [[ $attempt -le 30 ]]; do
    local resp http_code
    resp="$(curl -sS -w $'\n__HTTP__%{http_code}' -G "$BASE/cubejs-api/v1/load" \
      -H "Authorization: $TOKEN" \
      --data-urlencode "query=$QUERY" \
      "$@" 2>&1)" || {
      echo "$resp" >&2
      echo "curl failed (is Cube up on $BASE ?)" >&2
      exit 1
    }
    http_code="${resp##*$'\n__HTTP__'}"
    resp="${resp%$'\n__HTTP__'*}"
    if [[ "$http_code" != "200" ]]; then
      echo "HTTP $http_code" >&2
      echo "$resp" | jq . 2>/dev/null || echo "$resp"
      exit 1
    fi
    if echo "$resp" | jq -e '.error == "Continue wait"' >/dev/null 2>&1; then
      echo "# Continue wait (attempt $attempt)..." >&2
      sleep 2
      attempt=$((attempt + 1))
      continue
    fi
    if [[ -z "$resp" ]]; then
      echo "Empty response from Cube (attempt $attempt)" >&2
      sleep 2
      attempt=$((attempt + 1))
      continue
    fi
    echo "$resp" | jq .
    return 0
  done
  echo "Timed out waiting for query (30 attempts)" >&2
  exit 1
}

load_with_retry
