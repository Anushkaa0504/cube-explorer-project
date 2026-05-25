-- ===========================================================================
-- Personal-finance schema for the Cube Explorer project.
--
-- Tables
--   users         People who own accounts. One row per user.
--   accounts      Bank / credit / investment accounts. Many per user.
--   categories    Hierarchical expense/income taxonomy.
--   merchants     Counter-parties of transactions.
--   transactions  The fact table. One row per money movement.
--
-- Conventions
--   * `amount` is signed: negative = money leaving (expense), positive = income.
--   * Every transaction has a `user_id` for row-level security demos.
--   * All timestamps are TIMESTAMPTZ (Cube expects timezone-aware values).
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id          SERIAL       PRIMARY KEY,
    email       TEXT         UNIQUE NOT NULL,
    full_name   TEXT         NOT NULL,
    country     TEXT         NOT NULL DEFAULT 'US',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
CREATE TABLE categories (
    id          SERIAL       PRIMARY KEY,
    name        TEXT         NOT NULL,
    parent_id   INTEGER      REFERENCES categories(id),
    type        TEXT         NOT NULL CHECK (type IN ('expense', 'income', 'transfer')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
CREATE TABLE merchants (
    id                   SERIAL       PRIMARY KEY,
    name                 TEXT         NOT NULL,
    default_category_id  INTEGER      REFERENCES categories(id),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
CREATE TABLE accounts (
    id           SERIAL       PRIMARY KEY,
    user_id      INTEGER      NOT NULL REFERENCES users(id),
    name         TEXT         NOT NULL,
    type         TEXT         NOT NULL CHECK (type IN ('checking', 'savings', 'credit_card', 'investment')),
    currency     TEXT         NOT NULL DEFAULT 'USD',
    opened_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
CREATE TABLE transactions (
    id                SERIAL       PRIMARY KEY,
    user_id           INTEGER      NOT NULL REFERENCES users(id),
    account_id        INTEGER      NOT NULL REFERENCES accounts(id),
    merchant_id       INTEGER      REFERENCES merchants(id),
    category_id       INTEGER      NOT NULL REFERENCES categories(id),
    amount            NUMERIC(12, 2) NOT NULL,
    description       TEXT,
    status            TEXT         NOT NULL DEFAULT 'posted'
                                     CHECK (status IN ('posted', 'pending', 'failed')),
    transaction_date  TIMESTAMPTZ  NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMIT;
