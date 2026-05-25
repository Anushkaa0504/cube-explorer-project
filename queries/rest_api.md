# REST API – examples (personal-finance schema)

Base URL: `http://localhost:4000/cubejs-api/v1`
Docs: https://cube.dev/docs/product/apis-integrations/rest-api

In **dev mode** no auth header is required. In production every request must
include `Authorization: <JWT>` signed with `CUBEJS_API_SECRET`.

> Cold queries may return `{"error":"Continue wait"}`. Just re-run the same
> request until you get `data`, or use the retry helper in
> `scripts/test_apis.sh` / the dashboard.

---

## 1. KPIs – income, expense, savings rate

```bash
curl -s -G http://localhost:4000/cubejs-api/v1/load \
  --data-urlencode 'query={
    "measures": [
      "transactions.total_income",
      "transactions.total_expense",
      "transactions.net_cashflow",
      "transactions.savings_rate"
    ]
  }' | jq .
```

## 2. Top spending categories

```bash
curl -s -G http://localhost:4000/cubejs-api/v1/load \
  --data-urlencode 'query={
    "measures": ["transactions.total_expense"],
    "dimensions": ["categories.name"],
    "segments": ["transactions.expenses_only"],
    "order": {"transactions.total_expense": "desc"},
    "limit": 10
  }' | jq .
```

## 3. Monthly cashflow over the last year

```bash
curl -s -G http://localhost:4000/cubejs-api/v1/load \
  --data-urlencode 'query={
    "measures": ["transactions.total_income", "transactions.total_expense", "transactions.net_cashflow"],
    "timeDimensions": [{
      "dimension": "transactions.transaction_date",
      "granularity": "month",
      "dateRange": "last 12 months"
    }]
  }' | jq .
```

## 4. Rolling 30-day expense trend

```bash
curl -s -G http://localhost:4000/cubejs-api/v1/load \
  --data-urlencode 'query={
    "measures": ["transactions.trailing_30d_expense"],
    "timeDimensions": [{
      "dimension": "transactions.transaction_date",
      "granularity": "day",
      "dateRange": "last 90 days"
    }]
  }' | jq .
```

## 5. Inspect the generated SQL

```bash
curl -s -G http://localhost:4000/cubejs-api/v1/sql \
  --data-urlencode 'query={
    "measures": ["transactions.total_expense"],
    "dimensions": ["categories.name"]
  }' | jq -r '.sql.sql[0]'
```

## 6. Browse compiled metadata

```bash
curl -s http://localhost:4000/cubejs-api/v1/meta | jq '.cubes | map(.name) | sort'
```

## 7. Row-level security with a customer JWT

```bash
TOKEN=$(node -e "console.log(require('jsonwebtoken').sign({user_id:1,role:'customer'}, 'super-secret-please-change-me'))")
curl -s -G http://localhost:4000/cubejs-api/v1/load \
  -H "Authorization: $TOKEN" \
  --data-urlencode 'query={"measures":["transactions.count"]}' | jq .
```
