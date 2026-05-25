# GraphQL API – examples (personal-finance schema)

Endpoint: `http://localhost:4000/cubejs-api/graphql`
Docs: https://cube.dev/docs/product/apis-integrations/graphql-api

Open the GraphQL Playground in your browser to autocomplete the full schema.

## Monthly cashflow

```graphql
{
  cube(
    where: { transactions: { transaction_date: { inDateRange: "this year" } } }
    orderBy: { transactions: { transaction_date: asc } }
  ) {
    transactions(timezone: "UTC") {
      total_income
      total_expense
      net_cashflow
      transaction_date { month }
    }
  }
}
```

## Top spending categories

```graphql
{
  cube(
    limit: 10,
    orderBy: { transactions: { total_expense: desc } },
    where: { transactions: { amount: { lt: 0 }, status: { equals: "posted" } } }
  ) {
    categories { name parent_name type }
    transactions { total_expense posted_count }
  }
}
```

## Top merchants by spend

```graphql
{
  cube(
    limit: 10,
    orderBy: { transactions: { total_expense: desc } }
  ) {
    merchants { name }
    transactions { total_expense posted_count }
  }
}
```
