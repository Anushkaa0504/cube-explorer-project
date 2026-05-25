# Model, users & access

> **Main doc for the model** (curl tests, users, policies). `cubes/README.md` is a short index pointing here; `cubes-js/` is generated — do not edit.

One guide for the semantic model, Postgres tables, demo users, access policies, and how to test with `curl` + `jq`.

**Registry file:** `cubes/identity.json` · **Runtime:** `cube.js` + generated `cubes-js/*.js`

---

## Quick start

```bash
cd ~/cube-explorer-project
make sync-identity
make up && make ready

export BASE=http://localhost:4000
bash scripts/as-user.sh 1 '{"dimensions":["users.email"],"limit":2}'
# Expect: "users.email": "a***@example.com"
```

After editing `identity.json` or `*.schema.json`:

```bash
make sync-identity-install  # use this if sync-identity writes to ~/.cache only
docker compose restart cube
```

---

## Folder layout

| Path | Purpose | Edit? |
|------|---------|-------|
| `cubes/identity.json` | Users, roles, `accessPolicies` | Yes |
| `cubes/*.schema.json` | Dimensions, measures, joins per cube | Yes |
| `cubes-js/*.js` | Generated cubes Cube loads in Docker | No |
| `views/spending.yml` | Curated explore surface | Yes |
| `dynamic/*.jinja` | Extra cubes from templates | Yes |

Build: `cubes/*.schema.json` + `identity.json` → `make sync-identity` → `cubes-js/*.js`  
Docker mounts `cubes-js/` over `model/cubes/` in the container.

---

## Postgres tables → cubes

| Postgres table | Cube | Schema file | Access policy |
|----------------|------|-------------|---------------|
| `public.users` | users | `users.schema.json` | Yes |
| `public.accounts` | accounts | `accounts.schema.json` | Yes |
| `public.categories` | categories | `categories.schema.json` | No (public) |
| `public.merchants` | merchants | `merchants.schema.json` | No (public) |
| `public.transactions` | transactions | `transactions.schema.json` | Yes |

```
users ──< accounts ──< transactions >── categories
  │                              └── merchants
  └──────────────────────────────< transactions
```

---

## Demo users

JWT payload is only `{"user_id": <id>}`. Roles come from `identity.json` (via `cube.js` / `scripts/sign_jwt.py`).

| **ID** | **Name**              | **Email**            | **Role(s)**         | **Country** | **In DB seed?** |
|:------:|:---------------------:|:--------------------:|:-------------------:|:-----------:|:---------------:|
| 1      | Ada Lovelace          | ada@example.com      | customer            | GB          | yes             |
| 2      | Alan Turing           | alan@example.com     | analyst             | GB          | yes             |
| 3      | Grace Hopper          | grace@example.com    | customer            | US          | yes             |
| 4      | Linus Torvalds        | linus@example.com    | support_agent       | FI          | yes             |
| 5      | Margaret Hamilton     | margaret@example.com | auditor             | US          | yes             |
| 6      | Ops Admin             | ops@example.com      | admin               | US          | yes             |
| 7      | Priya Sharma          | priya@example.com    | **marketing**       | IN          | yes             |
| 8      | James Lee             | james@example.com    | **finance_viewer**  | US          | yes             |
| 9      | Carlos Mendez         | carlos@example.com   | **regional_lead**   | US          | yes             |
| 10     | Zoe Martin            | zoe@example.com      | **premium_customer**| GB          | yes             |

| **ID** | **Role** | **Summary** |
|:------:|:---------|:------------|
| 1, 3   | customer | Own transactions; mask email, country, income measures |
| 10     | premium_customer | Same row scope as customer; **real** `total_income` / `savings_rate` |
| 2, 6   | analyst / admin | Full model |
| 4      | support_agent | All rows; mask contact + descriptions |
| 5      | auditor | All rows; mask identity + descriptions |
| 7      | marketing | **categories + merchants + users** only (no accounts/transactions) |
| 8      | finance_viewer | **Measures only** on transactions (no dimensions) |
| 9      | regional_lead | Rows where `users.country` = JWT `country` (US); mask email, descriptions |

---

## Roles

| **Role** | **Description** |
|----------|-----------------|
| analyst | Full semantic layer, no masking |
| admin | Same as analyst (`groups: [analyst, admin]`) |
| customer | Own transactions; mask PII + income measures |
| premium_customer | Own transactions; income measures **not** masked |
| support_agent | All rows; mask contact fields + descriptions |
| auditor | All rows; strict user fields + masked descriptions |
| **marketing** | Users (masked email) + categories + merchants only |
| **finance_viewer** | Transaction **measures only** (global aggregates) |
| **regional_lead** | Transactions for users in JWT `country`; categories/merchants read |

`categories` / `merchants`: only **analyst, admin, marketing, regional_lead** (others denied).

**customer** and **premium_customer:** `cube.js` `queryRewrite` adds `transactions.user_id = <user_id>` when the query uses `transactions.*`.

**regional_lead:** JWT includes `country` from `sign_jwt.py`. `cube.js` `queryRewrite` filters `transactions.user_id` to users in that country (Cube cannot use `users.country` in `transactions` access_policy).

### Try the new users

Each probe below targets a different policy mechanism — annotations after `#` say what each line proves.

```bash
export BASE=http://localhost:4000

# 7 marketing
./scripts/q -a -u 7 '{"measures":["categories.count"]}'
# → member_level: marketing IS in the categories policy block → succeeds
./scripts/q -a -u 7 '{"measures":["transactions.count"]}'
# → denied: marketing has NO policy entry on transactions → cube hidden

# 8 finance_viewer
./scripts/q -a -u 8 '{"measures":["transactions.posted_count"]}'
# → member_level (allow): posted_count is in the finance_viewer whitelist
./scripts/q -a -u 8 '{"dimensions":["transactions.description"],"limit":1}'
# → member_level (deny): finance_viewer is "measures only" — dimension rejected

# 9 regional_lead (US)
./scripts/q -a -u 9 '{"measures":["transactions.posted_count"]}'
# → row_level via queryRewrite in cube.js → US users only (between 33 and 2907)

# 10 premium_customer vs 1 customer
./scripts/q -a -u 10 '{"measures":["transactions.total_income","transactions.posted_count"]}'
# → row_level (own rows) WITHOUT member_masking → real total_income
./scripts/q -a -u 1  '{"measures":["transactions.total_income","transactions.posted_count"]}'
# → row_level (own rows) WITH member_masking → total_income = -1 (mask scalar)
```

---

## Access policies (from `identity.json`)

### `users` cube

| **Group**         | **Visible members**                      | **Masked members**     |
|-------------------|------------------------------------------------------------------ |
| analyst, admin    | `*`                                      | —                               
| customer          | `id`, `full_name`, `created_at`, `count` | `email`, `country`             |
| support_agent     | `id`, `full_name`, `created_at`, `count` | `email`, `country`             |
| auditor           | `id`, `created_at`, `count`              | `email`, `full_name`, `country`|

Mask SQL (in schema): email → `a***@domain`; full_name → `ANON-{id}`; country → `XX`.

### `accounts` cube

| Group | Visible members | Masked members |
|-------|-----------------|----------------|
| analyst, admin | `*` | — |
| customer, support_agent, auditor | id, user_id, type, currency, opened_at, liquidity_tier, count | name (`***` + last 4 chars) |

### `transactions` cube

| **Group**           | **Rows**                                | **Visible measures**                          | **Masked measures**                |
|---------------------|-----------------------------------------|-----------------------------------------------|------------------------------------|
| analyst, admin      | all                                     | all (`*`)                                     | —                                  |
| customer            | `user_id = securityContext.user_id`      | expenses, counts, cashflow,<br>YTD/QTD/MTD,<br>multi-stage, etc.<br>(see `identity.json`) | total_income → **−1**<br>savings_rate → **0** |
| support_agent       | all                                     | all (`*`)                                     | description → `[redacted]`         |
| auditor             | all                                     | all (`*`)                                     | description → `[redacted]`         |

---

## Test matrix

| **User(s)** | **Role(s)**             | **Query**                   | **Expected Result**                            |
|-------------|-------------------------|-----------------------------|------------------------------------------------|
| 1           | customer                | `users.email`               | Masked, e.g. `a***@example.com`                |
| 1           | customer                | `transactions.posted_count` | Count for Ada only                             |
| 2           | analyst                 | `users.email`               | Real emails                                    |
| 2           | analyst                 | `transactions.posted_count` | Global total (all users)                       |
| 3           | customer                | `transactions.posted_count` | Different number than user 1                   |
| 4           | support_agent           | `transactions.description`  | `[redacted]`                                   |
| 5           | auditor                 | meta `users` dimensions     | No `full_name` in list                         |
| 1 vs 2      | customer vs analyst     | `transactions.total_income` | 1 → −1; 2 → real sum                           |

---

## Visualize access policies with `curl`

Same API query, **different person** → different JWT → different rules in `identity.json`.

### Who is who

| user_id | Person | Role | Restrictions (short) |
|---------|--------|------|----------------------|
| **1** | Ada Lovelace | customer | Mask email/country & account name; **only her** transactions; income hidden |
| **2** | Alan Turing | analyst | **No masking**, all rows, all measures |
| **3** | Grace Hopper | customer | Same rules as Ada; **different** transaction count |
| **4** | Linus Torvalds | support_agent | Mask contact fields; **all** transactions; descriptions redacted |
| **5** | Margaret Hamilton | auditor | Stricter user fields; descriptions redacted |
| **6** | Ops Admin | admin | Same as analyst |

```bash
cd ~/cube-explorer-project
export BASE=http://localhost:4000
```

Always sign JWT with:

```bash
TOKEN=$(python3 scripts/sign_jwt.py <user_id>)   # 1=Ada, 2=Alan, 4=Linus, 5=Margaret
```

Do **not** use `sign 1` unless you defined `sign() { python3 scripts/sign_jwt.py "$1"; }` in this shell.

---

### Same query, different people (copy-paste)

**Run this setup first** (new terminal = run again).

```bash
cd ~/cube-explorer-project
export BASE=http://localhost:4000
```

Below: **TEST 1** (JSON output) and **TEST 1b–5b** (one line per row — best for spotting masked vs clear values). All curls use inline `'query={...}'` so you do not need `$Q_EMAIL` / `$Q_TX` variables.

**TEST 1 — Ada (customer) vs Alan (analyst): email masking**

> **What this proves:** `member_masking` on `users.email` and `users.country` for `customer` (values redacted via the dimension's `mask:` SQL). No `row_level` on `users` — both users see all 10 rows.

Use **inline `query=...`** (works even if `$Q_EMAIL` was never set). Or use `bash scripts/as-user.sh` (no env vars).

```bash
# Ada — masked (copy whole block)
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name","users.country"],"order":{"users.id":"asc"},"limit":3}' \
  | jq '{data, error}'

# Alan — real emails
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name","users.country"],"order":{"users.id":"asc"},"limit":3}' \
  | jq '{data, error}'

# Same thing, no curl vars at all:
bash scripts/as-user.sh 1 '{"dimensions":["users.id","users.email","users.full_name","users.country"],"order":{"users.id":"asc"},"limit":3}'
bash scripts/as-user.sh 2 '{"dimensions":["users.id","users.email","users.full_name","users.country"],"order":{"users.id":"asc"},"limit":3}'
```

If you still see `"Query param is required"`, check: `echo "Q_EMAIL=[$Q_EMAIL]"` — empty brackets = variable not set; use the inline curl above instead.

**Expected output (Ada, user 1):**

```json
{
  "data": [
    { "users.id": 1.0, "users.email": "a***@example.com", "users.full_name": "Ada Lovelace", "users.country": "XX" },
    { "users.id": 2.0, "users.email": "a***@example.com", "users.full_name": "Alan Turing", "users.country": "XX" },
    { "users.id": 3.0, "users.email": "g***@example.com", "users.full_name": "Grace Hopper", "users.country": "XX" }
  ],
  "error": null
}
```

**Expected output (Alan, user 2):** same shape; `users.email` is real (`ada@example.com`, …) and `users.country` is not `XX`.

| Ada (1) | Alan (2) |
|---------|----------|
| `a***@example.com` | `ada@example.com` |
| `XX` country | real country |
| sees `full_name` | sees `full_name` |

---

### Masked vs clear — all attributes on one line (easy to read)

Same pattern as TEST 1: inline `query=...`, then `jq -r` prints each field as `key=value`. Run **masked** block, then **clear** block, and compare.

**TEST 1b — `users` cube: every dimension (email + country masked for customer)**

> **What this proves:** Same `member_masking` as TEST 1, but printed one field per line so masked vs clear values are obvious. `id`, `full_name`, `created_at` flow through unchanged (`member_level` whitelist).

```bash
# MASKED — Ada (customer): access_policy masks email → a***@…, country → XX
echo "========== users · MASKED (user 1 Ada, customer) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name","users.country","users.created_at"],"order":{"users.id":"asc"},"limit":3}' \
  | jq -r '.data[] | "id=\(.["users.id"])  email=\(.["users.email"])  name=\(.["users.full_name"])  country=\(.["users.country"])  created=\(.["users.created_at"])"'

# CLEAR — Alan (analyst): full PII, no masking on users
echo "========== users · CLEAR (user 2 Alan, analyst) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name","users.country","users.created_at"],"order":{"users.id":"asc"},"limit":3}' \
  | jq -r '.data[] | "id=\(.["users.id"])  email=\(.["users.email"])  name=\(.["users.full_name"])  country=\(.["users.country"])  created=\(.["users.created_at"])"'
```

**Expected (first row only):**

| Who | Line looks like |
|-----|-----------------|
| Ada | `email=a***@example.com  country=XX` |
| Alan | `email=ada@example.com  country=GB` (real country from seed) |

---

**TEST 2 — `transactions.posted_count`: RLS (customer sees own rows only)**

> **What this proves:** `row_level` on `transactions`. Two `customer`s (1 Ada, 3 Grace) return the SAME shape but DIFFERENT counts → the filter is bound to `securityContext.user_id`, not hardcoded. Analyst/support have no `row_level` → full global count.

```bash
# Small count = only your transactions; large count = all users in DB
for U in 1 2 3 4; do
  echo "========== posted_count · user_id=$U =========="
  curl -s -G "$BASE/cubejs-api/v1/load" \
    -H "Authorization: $(python3 scripts/sign_jwt.py $U)" \
    --data-urlencode 'query={"measures":["transactions.posted_count"]}' \
    | jq -r '.data[0] | "posted_count=\(.["transactions.posted_count"] // "error")"'
done
```

| user_id | Role | posted_count (typical) |
|---------|------|----------------------|
| 1 Ada | customer | `33` (her rows only) |
| 2 Alan | analyst | `2907` (everyone) |
| 3 Grace | customer | `33` (her rows only) |
| 4 Linus | support | `2907` (everyone) |

---

**TEST 3 — `accounts` cube: all main dimensions (name masked for customer)**

> **What this proves:** `member_masking` on a single dimension (`accounts.name`) while `id`/`user_id`/`type`/`currency`/`opened_at` come through clear. **No `row_level` on `accounts`** — even Ada (customer) sees every account in the DB, just with masked names. Demonstrates that masking and row filtering are independent dials.

```bash
# MASKED — account name → ***king (last 4 chars only)
echo "========== accounts · MASKED (user 1 Ada) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode 'query={"dimensions":["accounts.id","accounts.user_id","accounts.name","accounts.type","accounts.currency","accounts.opened_at"],"order":{"accounts.id":"asc"},"limit":3}' \
  | jq -r '.data[] | "id=\(.["accounts.id"])  user=\(.["accounts.user_id"])  name=\(.["accounts.name"])  type=\(.["accounts.type"])  currency=\(.["accounts.currency"])"'

# CLEAR — real account names (e.g. Primary Checking)
echo "========== accounts · CLEAR (user 2 Alan) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode 'query={"dimensions":["accounts.id","accounts.user_id","accounts.name","accounts.type","accounts.currency","accounts.opened_at"],"order":{"accounts.id":"asc"},"limit":3}' \
  | jq -r '.data[] | "id=\(.["accounts.id"])  user=\(.["accounts.user_id"])  name=\(.["accounts.name"])  type=\(.["accounts.type"])  currency=\(.["accounts.currency"])"'
```

**Expected (Ada, first account):** `name=***king` · **Alan:** `name=Primary Checking` (or similar from seed).

---

**TEST 4 — `transactions.description`: free text (support/auditor policies mask description)**

> **What this proves:** `member_masking` on a single string dimension for `support_agent`. `id`/`amount`/`status` come back clear; only `description` is replaced with the literal `"[redacted]"` from the mask SQL. Support has no `row_level` on transactions → all 2907 rows visible.

```bash
# CLEAR — analyst sees real merchant / salary text
echo "========== description · CLEAR (user 2 Alan) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode 'query={"dimensions":["transactions.id","transactions.description","transactions.amount","transactions.status"],"order":{"transactions.id":"asc"},"limit":2}' \
  | jq -r '.data[] | "id=\(.["transactions.id"])  desc=\(.["transactions.description"])  amount=\(.["transactions.amount"])  status=\(.["transactions.status"])"'

# MASKED — support_agent / auditor: description should show [redacted] when member_masking applies
echo "========== description · MASKED (user 4 Linus, support) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 4)" \
  --data-urlencode 'query={"dimensions":["transactions.id","transactions.description","transactions.amount","transactions.status"],"order":{"transactions.id":"asc"},"limit":2}' \
  | jq -r '.data[] | "id=\(.["transactions.id"])  desc=\(.["transactions.description"])  amount=\(.["transactions.amount"])  status=\(.["transactions.status"])"'
```

---

**TEST 5 — masked measures: income hidden, savings zeroed (customer vs analyst)**

> **What this proves:** `member_masking` applied to **measures** (not just dimensions). The cube defines `total_income.mask = -1` and `savings_rate.mask = 0`; the customer policy lists those in `member_masking`, so the aggregate is returned as the mask scalar instead of the real sum. Stacks on top of `row_level` (Ada's own rows only).

```bash
# MASKED — customer: total_income → -1, savings_rate → 0 (member_masking on measures)
echo "========== measures · MASKED (user 1 Ada) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode 'query={"measures":["transactions.posted_count","transactions.total_income","transactions.savings_rate","transactions.total_expense"]}' \
  | jq -r '.data[0] | "posted=\(.["transactions.posted_count"])  income=\(.["transactions.total_income"])  savings=\(.["transactions.savings_rate"])  expense=\(.["transactions.total_expense"])"'

# CLEAR — analyst: real aggregates on all rows
echo "========== measures · CLEAR (user 2 Alan) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode 'query={"measures":["transactions.posted_count","transactions.total_income","transactions.savings_rate","transactions.total_expense"]}' \
  | jq -r '.data[0] | "posted=\(.["transactions.posted_count"])  income=\(.["transactions.total_income"])  savings=\(.["transactions.savings_rate"])  expense=\(.["transactions.total_expense"])"'
```

**Expected:**

| Who | `posted` | `income` | `savings` |
|-----|----------|----------|-----------|
| Ada | `33` | `-1` | `0` |
| Alan | `2907` | `664338.96` | large positive number |

---

**TEST 5b — auditor vs customer on `users` (fewer fields allowed for auditor)**

> **What this proves:** Different roles → different `member_masking` lists. Customer masks `email`/`country` but `full_name` is clear. Auditor's stricter policy adds `full_name` to `member_masking` → returns `ANON-1` from the mask SQL. Three masks active at once for auditor: `email`, `full_name`, `country`.

```bash
# Customer can query full_name; auditor policy may hide it from meta (see TEST 6)
echo "========== users row · customer (user 1) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name"],"limit":1}' \
  | jq -r '.data[0] | "id=\(.["users.id"])  email=\(.["users.email"])  name=\(.["users.full_name"])"'

echo "========== users row · auditor (user 5 Margaret) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 5)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name"],"limit":1}' \
  | jq -r '.data[0] | "id=\(.["users.id"])  email=\(.["users.email"])  name=\(.["users.full_name"])"'
```

**Expected:** Ada → `name=Ada Lovelace` · Margaret → `email=a***@example.com  name=ANON-1` (auditor masks identity fields).

---

### All transaction measures — one curl per user (copy-paste)

Same query for every role; only the JWT user changes. Set this once:

```bash
cd ~/cube-explorer-project
export BASE=http://localhost:4000

Q_MEASURES='{"measures":["transactions.count","transactions.posted_count","transactions.pending_count","transactions.failed_count","transactions.total_amount","transactions.total_income","transactions.total_expense","transactions.net_cashflow","transactions.savings_rate","transactions.avg_transaction_amount","transactions.avg_expense","transactions.trailing_30d_expense","transactions.cumulative_income","transactions.ytd_expense","transactions.qtd_expense","transactions.mtd_expense"]}'
```

Run each block below. Your terminal should match the **Expected output** (after `make ready` + seeded DB).

---

#### User 1 — Ada Lovelace · `customer`

> **What this proves:** All three policy dials at once on `transactions` — `row_level` (33 own rows), `member_level` (whitelisted measure subset), `member_masking` (`total_income → -1`, `savings_rate → 0`). The `null`s on expense measures aren't policy: Ada's 33 rows happen to all be income, so the `amount < 0` filter inside `total_expense`/`*_expense` matches nothing.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "33",
  "transactions.posted_count": "33",
  "transactions.pending_count": "0",
  "transactions.failed_count": "0",
  "transactions.total_amount": "140100.84",
  "transactions.total_income": -1.0,
  "transactions.total_expense": null,
  "transactions.net_cashflow": null,
  "transactions.savings_rate": 0.0,
  "transactions.avg_transaction_amount": "4245.4800000000000000",
  "transactions.avg_expense": null,
  "transactions.trailing_30d_expense": null,
  "transactions.cumulative_income": "140100.84",
  "transactions.ytd_expense": null,
  "transactions.qtd_expense": null,
  "transactions.mtd_expense": null
}
```

---

#### User 2 — Alan Turing · `analyst`

> **What this proves:** Baseline. `member_level: *`, no masking, no row filter → real global numbers across all 2907 posted transactions. Compare every other user's output against this row.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "3089",
  "transactions.posted_count": "2907",
  "transactions.pending_count": "161",
  "transactions.failed_count": "21",
  "transactions.total_amount": "293872.71",
  "transactions.total_income": "664338.96",
  "transactions.total_expense": "345540.75",
  "transactions.net_cashflow": "318798.21",
  "transactions.savings_rate": "66433895.47987281974250012373",
  "transactions.avg_transaction_amount": "95.1352249919067659",
  "transactions.avg_expense": "126.0177789934354486",
  "transactions.trailing_30d_expense": "345540.75",
  "transactions.cumulative_income": "664338.96",
  "transactions.ytd_expense": "345540.75",
  "transactions.qtd_expense": "345540.75",
  "transactions.mtd_expense": "345540.75"
}
```

---

#### User 3 — Grace Hopper · `customer`

> **What this proves:** Same policy as Ada (row_level + member_level + member_masking) but a **different `total_amount`** (`129151.35` vs Ada's `140100.84`). Confirms the row filter is dynamically bound to `securityContext.user_id`, not hardcoded.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 3)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "33",
  "transactions.posted_count": "33",
  "transactions.pending_count": "0",
  "transactions.failed_count": "0",
  "transactions.total_amount": "129151.35",
  "transactions.total_income": -1.0,
  "transactions.total_expense": null,
  "transactions.net_cashflow": null,
  "transactions.savings_rate": 0.0,
  "transactions.avg_transaction_amount": "3913.6772727272727273",
  "transactions.avg_expense": null,
  "transactions.trailing_30d_expense": null,
  "transactions.cumulative_income": "129151.35",
  "transactions.ytd_expense": null,
  "transactions.qtd_expense": null,
  "transactions.mtd_expense": null
}
```

---

#### User 4 — Linus Torvalds · `support_agent`

> **What this proves:** Output is **identical** to Alan's. Support_agent has `member_level: *` on `transactions` and only masks `description` (a dimension). This query has no dimensions, so masking has nothing to bite on. Tells you: masking is per-member, not per-role-globally — see TEST 4 for where support actually differs from analyst.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 4)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "3089",
  "transactions.posted_count": "2907",
  "transactions.pending_count": "161",
  "transactions.failed_count": "21",
  "transactions.total_amount": "293872.71",
  "transactions.total_income": "664338.96",
  "transactions.total_expense": "345540.75",
  "transactions.net_cashflow": "318798.21",
  "transactions.savings_rate": "66433895.47987281974250012373",
  "transactions.avg_transaction_amount": "95.1352249919067659",
  "transactions.avg_expense": "126.0177789934354486",
  "transactions.trailing_30d_expense": "345540.75",
  "transactions.cumulative_income": "664338.96",
  "transactions.ytd_expense": "345540.75",
  "transactions.qtd_expense": "345540.75",
  "transactions.mtd_expense": "345540.75"
}
```

---

#### User 5 — Margaret Hamilton · `auditor`

> **What this proves:** Also identical to analyst here. Auditor's `transactions` policy is `member_level: *` + masks only `description`. Auditor's stricter masking (`full_name`, `email`, `country`) lives on the `users` cube — see TEST 5b for proof.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 5)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "3089",
  "transactions.posted_count": "2907",
  "transactions.pending_count": "161",
  "transactions.failed_count": "21",
  "transactions.total_amount": "293872.71",
  "transactions.total_income": "664338.96",
  "transactions.total_expense": "345540.75",
  "transactions.net_cashflow": "318798.21",
  "transactions.savings_rate": "66433895.47987281974250012373",
  "transactions.avg_transaction_amount": "95.1352249919067659",
  "transactions.avg_expense": "126.0177789934354486",
  "transactions.trailing_30d_expense": "345540.75",
  "transactions.cumulative_income": "664338.96",
  "transactions.ytd_expense": "345540.75",
  "transactions.qtd_expense": "345540.75",
  "transactions.mtd_expense": "345540.75"
}
```

---

#### User 6 — Ops Admin · `admin`

> **What this proves:** Output identical to Alan (analyst). `admin` and `analyst` share one policy block (`groups: ["analyst","admin"]` with `member_level: *`). Proves that `contextToGroups` in `cube.js` plus the `groups:` array lets multiple roles share a single policy entry.

```bash
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 6)" \
  --data-urlencode "query=$Q_MEASURES" | jq '.data[0]'
```

**Expected output:**

```json
{
  "transactions.count": "3089",
  "transactions.posted_count": "2907",
  "transactions.pending_count": "161",
  "transactions.failed_count": "21",
  "transactions.total_amount": "293872.71",
  "transactions.total_income": "664338.96",
  "transactions.total_expense": "345540.75",
  "transactions.net_cashflow": "318798.21",
  "transactions.savings_rate": "66433895.47987281974250012373",
  "transactions.avg_transaction_amount": "95.1352249919067659",
  "transactions.avg_expense": "126.0177789934354486",
  "transactions.trailing_30d_expense": "345540.75",
  "transactions.cumulative_income": "664338.96",
  "transactions.ytd_expense": "345540.75",
  "transactions.qtd_expense": "345540.75",
  "transactions.mtd_expense": "345540.75"
}
```

**Quick diff (measures only):**

| Field | customer (1, 3) | analyst / support / auditor / admin (2, 4, 5, 6) |
|-------|-----------------|---------------------------------------------------|
| `posted_count` | `33` | `2907` |
| `total_income` | `-1` | `664338.96` |
| `savings_rate` | `0` | large positive number |
| `total_amount` | ~140k / ~129k (own rows) | `293872.71` (global) |

---

**TEST 6 — `/meta` vs real values (auditor still sees dimension names)**

> **What this proves:** `/meta` is not a security boundary. `member_level` does shape `/meta` (whitelisted names appear), but masked members are still **listed** — masking only affects **values**, returned by `/load`. So always verify restrictions with a `/load` call, not by reading `/meta`.

`/meta` lists which members exist in the model. **Masking** changes values when you **load** data (see TEST 5b), not always which names appear in meta.

> Historical note: prior to the docker-compose fix that removed the `./model/cubes-js:/cube/conf/model/cubes` overlay, every cube was loaded twice (once from `model/cubes-js/`, once from the overlay). That silently disabled `access_policy` masking on some cubes (notably `transactions.description`). If you see duplicates again — `[.cubes[].name] | group_by(.) | map(length)` returning `[2,2,2,2,2]` — re-check `docker-compose.yml` for an accidental overlay mount.

```bash
# List users dimensions once (Ada, customer)
echo "========== meta · users · Ada (user 1) =========="
curl -s "$BASE/cubejs-api/v1/meta" -H "Authorization: $(python3 scripts/sign_jwt.py 1)" \
  | jq 'first(.cubes[] | select(.name=="users")) | [.dimensions[].name]'

# Margaret (auditor) — often the SAME names in meta; values differ when you query
echo "========== meta · users · Margaret (user 5) =========="
curl -s "$BASE/cubejs-api/v1/meta" -H "Authorization: $(python3 scripts/sign_jwt.py 5)" \
  | jq 'first(.cubes[] | select(.name=="users")) | [.dimensions[].name]'

# Compare actual values (auditor masks email + full_name + country)
echo "========== load · Margaret (user 5) =========="
curl -s -G "$BASE/cubejs-api/v1/load" \
  -H "Authorization: $(python3 scripts/sign_jwt.py 5)" \
  --data-urlencode 'query={"dimensions":["users.id","users.email","users.full_name","users.country"],"limit":1}' \
  | jq -r '.data[0] | "id=\(.["users.id"])  email=\(.["users.email"])  name=\(.["users.full_name"])  country=\(.["users.country"])"'
```

**Expected:**

| Step | Ada (1) | Margaret (5) |
|------|---------|----------------|
| `/meta` dimension names | `id`, `email`, `full_name`, `country`, `created_at` | usually the same list |
| `/load` values | masked email/country for customer policy | `email=a***@…`, `name=ANON-1`, `country=XX` |

Do not rely on `/meta` alone to prove auditor restrictions — use **TEST 5b** load output.

---

### Curl-to-mechanism cheat-sheet

Which test demonstrates which policy mechanism, at a glance:

| Mechanism                                     | Best curl to run                                                |
|-----------------------------------------------|-----------------------------------------------------------------|
| `member_level` allow (whitelisted member works)| "Try the new users" #3 (finance_viewer `posted_count`)         |
| `member_level` deny (cube entirely hidden)    | "Try the new users" #2 (marketing on `transactions`)            |
| `member_level` deny (specific member rejected)| "Try the new users" #4 (finance_viewer asking for a dimension)  |
| `member_masking` on a dimension (string)      | TEST 4 (`transactions.description` → `[redacted]`)              |
| `member_masking` on a dimension (PII)         | TEST 1 / 1b (email + country); TEST 3 (account name)            |
| `member_masking` on a measure (scalar)        | TEST 5 (`total_income → -1`, `savings_rate → 0`)                |
| `member_masking` stacked (3 fields at once)   | TEST 5b (auditor: email + full_name + country all masked)       |
| `row_level` via policy (own rows)             | TEST 2 (loop of 4 users → `33` for customers, `2907` for others)|
| `row_level` via `queryRewrite` (no policy path)| "Try the new users" #5 (regional_lead, US-only)                |
| `row_level` + `member_masking` stacked        | "Try the new users" #6/#7 (premium vs customer income)          |
| Group inheritance (`groups: [analyst, admin]`)| User 6 (admin) matching User 2 (analyst) byte-for-byte          |
| `/meta` is not a security boundary            | TEST 6 (names listed, values masked)                            |

If you want a single block that exercises the most ground fastest, run **TEST 2** (four JWTs, one query, one number each — the whole row-level story in four lines) followed by **TEST 5** (member_masking on measures).

---

### Makefile helpers

```bash
make as-user USER=1 Q='{"dimensions":["users.email"],"limit":2}'
make q ARGS='-a -u 1 "{\"measures\":[\"transactions.posted_count\"]}"'
make auth-users        # list users from identity.json
```

If `.data` is null: add `| jq '{data, error}'` — Cube must be up (`make ready`).

---

## What to edit

| Change | File |
|--------|------|
| Add user / change role | `cubes/identity.json` → `users[]` |
| Change what a role sees | `cubes/identity.json` → `accessPolicies` |
| Add dimension / measure | `cubes/<cube>.schema.json` |
| Curated BI view | `views/spending.yml` |

---

## Troubleshooting

**Troubleshooting Guide**

| Issue/Error Message                                           | Solution / Command                                                                              |
|--------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| Permission denied on `cubes/`                                | `make sync-identity-install`                                                                     |
| Converting circular structure to JSON                        | Use latest `cube.js` (no `extendContext`), and image `cubejs/cube:latest`                       |
| Cube 'posted_count' not found on `users.email`               | Restart Cube after fixing `cube.js`; do not add transactions filters to users-only queries       |
| syntax error at or near "{"                                  | `make sync-identity` (ensure correct SQL templates; JS uses `${CUBE}` in SQL)                   |
| invalid input syntax for type integer: "{ securityContext...}"| `make sync-identity` (make sure access_policy uses `securityContext.user_id`, not YAML strings)  |
| Cube 'posted_count' not found (pre-aggregations)             | `make sync-identity` (measures list should be `[posted_count]`, not `"posted_count"`)           |
| Empty `as-user.sh` output                                    | `docker compose logs cube` (wait until port 4000 is available)                                   |
| Query param is required                                      | `echo "[$Q_EMAIL]"` (run with `--data-urlencode 'query={...}'` or `bash scripts/as-user.sh 1 '...'` if empty) |
| `member_masking` not firing (e.g. `description` returns real value)| Check for duplicate cube loading: `curl -s $BASE/cubejs-api/v1/meta -H "Authorization: $(python3 scripts/sign_jwt.py 2)" \| jq '[.cubes[].name] \| group_by(.) \| map({n:.[0],c:length}) \| map(select(.c>1))'` — non-empty means an overlay mount in `docker-compose.yml` is loading cubes twice (remove the `./model/cubes-js:/cube/conf/model/cubes` line) |
| `Paths aren't allowed in the accessPolicy policy but 'X.Y' provided as a filter member` | A `row_level.filters[].member` in `identity.json` references a cross-cube path (e.g. `users.country` on `transactions`). Remove `row_level`/`conditions` from that policy block and rely on `queryRewrite` in `cube.js` for the same effect. |
