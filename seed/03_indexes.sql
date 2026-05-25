-- ===========================================================================
-- Indexes for the fact and dimension tables. We create them AFTER the data
-- load (faster) and choose the ones that help Cube's typical query shapes:
-- group-by-time, joins on FKs, filters on status / type / category.
-- ===========================================================================

BEGIN;

CREATE INDEX idx_tx_transaction_date ON transactions (transaction_date);
CREATE INDEX idx_tx_user_id          ON transactions (user_id);
CREATE INDEX idx_tx_account_id       ON transactions (account_id);
CREATE INDEX idx_tx_category_id      ON transactions (category_id);
CREATE INDEX idx_tx_merchant_id      ON transactions (merchant_id);
CREATE INDEX idx_tx_status           ON transactions (status);

CREATE INDEX idx_accounts_user_id    ON accounts (user_id);
CREATE INDEX idx_categories_parent   ON categories (parent_id);

-- Refresh planner statistics so the query optimizer sees the freshly loaded rows
ANALYZE users;
ANALYZE categories;
ANALYZE merchants;
ANALYZE accounts;
ANALYZE transactions;

COMMIT;
