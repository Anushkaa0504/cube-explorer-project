# SQL API – examples (personal-finance schema)

Cube exposes a Postgres-wire-compatible endpoint so any BI tool (Tableau,
Metabase, Power BI, Superset, DBeaver, psql) can connect.

Endpoint: `localhost:15432`
Database: `cube`     User: `cube`     Password: `cube`

```bash
psql "postgres://cube:cube@localhost:15432/cube" \
  -c "SELECT status, MEASURE(count) AS transactions
      FROM transactions GROUP BY status;"
```

## Top spending categories (via the spending view)

```sql
SELECT
  categories_name,
  MEASURE(total_expense) AS spend
FROM spending
WHERE direction = 'Expense' AND status = 'posted'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;
```

## Monthly cashflow

```sql
SELECT
  DATE_TRUNC('month', transaction_date) AS month,
  MEASURE(total_income)                 AS income,
  MEASURE(total_expense)                AS expense,
  MEASURE(net_cashflow)                 AS net
FROM transactions
WHERE transaction_date >= NOW() - INTERVAL '1 year'
GROUP BY 1
ORDER BY 1;
```

## Trailing 30-day spend curve

```sql
SELECT
  DATE_TRUNC('day', transaction_date) AS day,
  MEASURE(trailing_30d_expense)       AS rolling_spend
FROM transactions
WHERE transaction_date >= NOW() - INTERVAL '90 days'
GROUP BY 1
ORDER BY 1;
```

## See compiled SQL Cube ran against the warehouse

Any query you run also produces a row in the **Query History** tab of the
Playground (http://localhost:4000) which shows the generated SQL, cache
hits, and pre-aggregation matches.
