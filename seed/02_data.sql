-- ===========================================================================
-- Sample data. Uses generate_series + random() so re-seeding produces a fresh
-- but realistic-looking dataset every time. ~24 months of history.
-- ===========================================================================

BEGIN;

-- 1.  Users ---------------------------------------------------------------
INSERT INTO users (email, full_name, country, created_at) VALUES
  ('ada@example.com',     'Ada Lovelace',      'GB', now() - INTERVAL '730 days'),
  ('alan@example.com',    'Alan Turing',       'GB', now() - INTERVAL '700 days'),
  ('grace@example.com',   'Grace Hopper',      'US', now() - INTERVAL '650 days'),
  ('linus@example.com',   'Linus Torvalds',    'FI', now() - INTERVAL '600 days'),
  ('margaret@example.com','Margaret Hamilton', 'US', now() - INTERVAL '500 days'),
  ('ops@example.com',     'Ops Admin',         'US', now() - INTERVAL '480 days'),
  ('priya@example.com',   'Priya Sharma',      'IN', now() - INTERVAL '400 days'),
  ('james@example.com',   'James Lee',         'US', now() - INTERVAL '380 days'),
  ('carlos@example.com',  'Carlos Mendez',     'US', now() - INTERVAL '360 days'),
  ('zoe@example.com',     'Zoe Martin',        'GB', now() - INTERVAL '340 days');

-- 2.  Categories with hierarchy ------------------------------------------
-- Income
INSERT INTO categories (name, type) VALUES
  ('Income',         'income'),       -- 1
  ('Transfer',       'transfer');     -- 2

-- Top-level expense parents
INSERT INTO categories (name, type) VALUES
  ('Food & Dining',  'expense'),      -- 3
  ('Transport',      'expense'),      -- 4
  ('Housing',        'expense'),      -- 5
  ('Entertainment',  'expense'),      -- 6
  ('Health',         'expense'),      -- 7
  ('Shopping',       'expense'),      -- 8
  ('Utilities',      'expense'),      -- 9
  ('Travel',         'expense');      -- 10

-- Income sub-categories
INSERT INTO categories (name, parent_id, type) VALUES
  ('Salary',         1, 'income'),
  ('Dividends',      1, 'income'),
  ('Side Hustle',    1, 'income'),
  ('Refund',         1, 'income');

-- Expense sub-categories
INSERT INTO categories (name, parent_id, type) VALUES
  ('Groceries',      3, 'expense'),
  ('Restaurants',    3, 'expense'),
  ('Coffee',         3, 'expense'),
  ('Rideshare',      4, 'expense'),
  ('Fuel',           4, 'expense'),
  ('Public Transit', 4, 'expense'),
  ('Rent',           5, 'expense'),
  ('Mortgage',       5, 'expense'),
  ('Streaming',      6, 'expense'),
  ('Concerts',       6, 'expense'),
  ('Pharmacy',       7, 'expense'),
  ('Gym',            7, 'expense'),
  ('Electronics',    8, 'expense'),
  ('Clothing',       8, 'expense'),
  ('Electricity',    9, 'expense'),
  ('Internet',       9, 'expense'),
  ('Mobile',         9, 'expense'),
  ('Flights',        10,'expense'),
  ('Hotels',         10,'expense');

-- 3.  Merchants ----------------------------------------------------------
INSERT INTO merchants (name, default_category_id) VALUES
  ('Whole Foods',         15),   -- Groceries
  ('Trader Joe''s',       15),
  ('Costco',              15),
  ('Chipotle',            16),   -- Restaurants
  ('Sweetgreen',          16),
  ('Local Bistro',        16),
  ('Blue Bottle',         17),   -- Coffee
  ('Starbucks',           17),
  ('Uber',                18),   -- Rideshare
  ('Lyft',                18),
  ('Shell',               19),   -- Fuel
  ('Chevron',             19),
  ('Metro Transit',       20),
  ('LandlordCo',          21),   -- Rent
  ('Big Bank Mortgage',   22),
  ('Netflix',             23),
  ('Spotify',             23),
  ('Disney+',             23),
  ('LiveNation',          24),   -- Concerts
  ('CVS',                 25),   -- Pharmacy
  ('PlanetFitness',       26),
  ('Apple Store',         27),   -- Electronics
  ('Best Buy',            27),
  ('Uniqlo',              28),   -- Clothing
  ('Levi''s',             28),
  ('PG&E',                29),   -- Electricity
  ('Comcast',             30),   -- Internet
  ('Verizon',             31),   -- Mobile
  ('Delta',               32),   -- Flights
  ('United',              32),
  ('Marriott',            33),   -- Hotels
  ('Airbnb',              33),
  ('TechCorp Payroll',    11),   -- Salary
  ('Brokerage',           12);   -- Dividends

-- 4.  Accounts (3 per user, mix of types) --------------------------------
INSERT INTO accounts (user_id, name, type, currency, opened_at)
SELECT
  u.id,
  acct.name,
  acct.type,
  acct.currency,
  u.created_at + INTERVAL '1 day'
FROM users u
CROSS JOIN (VALUES
  ('Primary Checking',  'checking',    'USD'),
  ('Rainy Day Savings', 'savings',     'USD'),
  ('Travel Rewards',    'credit_card', 'USD')
) AS acct(name, type, currency);

-- 5.  Transactions -------------------------------------------------------
-- ~2,400 transactions spread evenly across ~24 months of history.
-- Each user gets recurring salary + assorted spending.
WITH days AS (
  SELECT generate_series(
    (now() - INTERVAL '24 months')::date,
    now()::date,
    INTERVAL '1 day'
  )::timestamptz AS d
),
salary_tx AS (
  -- Monthly salary on the 1st for every user
  SELECT
    u.id                        AS user_id,
    (SELECT id FROM accounts a WHERE a.user_id = u.id AND a.type = 'checking') AS account_id,
    (SELECT id FROM merchants WHERE name = 'TechCorp Payroll') AS merchant_id,
    11                          AS category_id,  -- Salary
    (3500 + random() * 4000)::numeric(12,2)     AS amount,
    'Monthly salary'            AS description,
    'posted'                    AS status,
    date_trunc('month', d.d) + INTERVAL '1 day' AS transaction_date
  FROM users u
  CROSS JOIN days d
  WHERE EXTRACT(DAY FROM d.d) = 1
),
random_expenses AS (
  -- 2-5 expenses per day from a rotating pool of users
  SELECT
    u.id AS user_id,
    (SELECT id FROM accounts a
       WHERE a.user_id = u.id
       ORDER BY random()
       LIMIT 1) AS account_id,
    m.id AS merchant_id,
    m.default_category_id AS category_id,
    -- Expense amounts vary by category type
    (CASE
       WHEN m.default_category_id IN (21, 22) THEN -(800  + random() * 1500)  -- Rent/Mortgage
       WHEN m.default_category_id IN (32, 33) THEN -(150  + random() * 700)   -- Flights/Hotels
       WHEN m.default_category_id IN (27)     THEN -(40   + random() * 600)   -- Electronics
       WHEN m.default_category_id IN (15)     THEN -(20   + random() * 80)    -- Groceries
       WHEN m.default_category_id IN (17)     THEN -(3    + random() * 8)     -- Coffee
       WHEN m.default_category_id IN (23)     THEN -(8    + random() * 15)    -- Streaming
       WHEN m.default_category_id IN (29, 30, 31) THEN -(30 + random() * 80)  -- Utilities
       ELSE -(5 + random() * 60)
     END)::numeric(12,2) AS amount,
    m.name || ' purchase' AS description,
    CASE WHEN random() < 0.05 THEN 'pending'
         WHEN random() < 0.01 THEN 'failed'
         ELSE 'posted'
    END AS status,
    d.d + (random() * INTERVAL '20 hours') AS transaction_date
  FROM days d
  CROSS JOIN LATERAL (
    SELECT id FROM users ORDER BY random() LIMIT 1
  ) u
  CROSS JOIN LATERAL (
    SELECT id, name, default_category_id
    FROM merchants
    WHERE default_category_id NOT IN (11, 12)   -- exclude payroll/dividends
    ORDER BY random()
    LIMIT (2 + (random() * 3)::int)
  ) m
)
INSERT INTO transactions
  (user_id, account_id, merchant_id, category_id, amount, description, status, transaction_date)
SELECT * FROM salary_tx
UNION ALL
SELECT * FROM random_expenses;

-- Quarterly dividend income, a smaller recurring credit
INSERT INTO transactions
  (user_id, account_id, merchant_id, category_id, amount, description, status, transaction_date)
SELECT
  u.id,
  (SELECT id FROM accounts a WHERE a.user_id = u.id AND a.type = 'savings'),
  (SELECT id FROM merchants WHERE name = 'Brokerage'),
  12,
  (50 + random() * 250)::numeric(12,2),
  'Quarterly dividend',
  'posted',
  date_trunc('quarter', d.d) + INTERVAL '5 days'
FROM users u
CROSS JOIN generate_series(
  (now() - INTERVAL '24 months')::date,
  now()::date,
  INTERVAL '3 months'
) AS d(d);

COMMIT;
