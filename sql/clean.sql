-- =====================================================================
-- 01_clean.sql
-- Retail Transaction Analytics — Staging, Cleaning & Reconciliation
--
-- Engine targeted : PostgreSQL 14+
-- Source file     : Sales_transactions_2022_2025.csv  (18,045 raw rows)
--
-- Every rule below was validated against the real file before writing
-- this script (row counts are cited in comments so you can confirm
-- your own run matches). Where a step is Postgres-specific, a one-line
-- MySQL / SQL Server note follows it.
--
-- Pipeline produced by this script:
--   stg_sales_raw        raw load, everything as TEXT
--   stg_dedup             duplicate Transaction_IDs removed
--   ref_store_region      canonical Store_ID -> Region lookup
--   ref_product           canonical Product_ID -> Name/Category lookup
--   customer_resolved     canonical Customer_ID -> Name/Gender/Age
--   stg_typed             raw text cast to real types + text cleaned
--   stg_financial         quantity/discount/amount/profit reconciled
--   ref_delivery_median   median delivery days per shipping method
--   sales_clean           FINAL cleaned fact table
--   data_quality_log      what was changed and how many rows it hit
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS retail;
SET search_path TO retail;

-- =====================================================================
-- SECTION 0 — STAGING LOAD
-- Load as TEXT first. Several numeric columns arrive as "28.0"-style
-- strings, and a stray bad value should not fail the whole load.
-- =====================================================================

DROP TABLE IF EXISTS stg_sales_raw;
CREATE TABLE stg_sales_raw (
    transaction_id        text,
    order_id              text,
    customer_id           text,
    customer_name         text,
    customer_age          text,
    customer_gender       text,
    customer_segment      text,
    order_date            text,
    order_time            text,
    sales_channel         text,
    store_id              text,
    store_name            text,
    country               text,
    region                text,
    city                  text,
    product_id            text,
    product_name          text,
    product_category      text,
    product_subcategory   text,
    quantity              text,
    unit_price            text,
    discount_percentage   text,
    sales_amount          text,
    cost_amount            text,
    profit                text,
    payment_method        text,
    order_status          text,
    shipping_method       text,
    delivery_days         text,
    return_flag           text,
    return_reason         text,
    sales_representative  text,
    promotion_code        text,
    customer_rating       text,
    inventory_level       text,
    order_year            text
);

-- Path below matches the docker-compose volume mount ./data:/data:ro,
-- so this runs as-is once the container is up (see docker-compose.yaml).
\copy retail.stg_sales_raw FROM '/data/Sales_transactions_2022_2025.csv' WITH (FORMAT csv, HEADER true);

-- MySQL:
--   LOAD DATA LOCAL INFILE 'Sales_transactions_2022_2025.csv' INTO TABLE retail.stg_sales_raw
--     FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;
-- SQL Server:
--   BULK INSERT retail.stg_sales_raw FROM 'Sales_transactions_2022_2025.csv'
--     WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='\n');

-- Sanity check: expect 18045
-- SELECT COUNT(*) FROM stg_sales_raw;


-- =====================================================================
-- SECTION 1 — DEDUPLICATION
-- 45 Transaction_IDs are exact duplicate rows (18,045 -> 18,000).
-- Transaction_ID is the intended grain of one fact row.
-- =====================================================================

DROP TABLE IF EXISTS stg_dedup;
CREATE TABLE stg_dedup AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY transaction_id) AS rn
    FROM stg_sales_raw
)
SELECT * FROM ranked WHERE rn = 1;

ALTER TABLE stg_dedup DROP COLUMN rn;

-- Sanity check: expect 18000
-- SELECT COUNT(*) FROM stg_dedup;


-- =====================================================================
-- SECTION 2 — REFERENCE / LOOKUP TABLES
-- =====================================================================

-- 2a. Canonical Region per store. Store_ID -> Country/City is already
-- 1:1 in the source; Region has real spelling/abbreviation variants
-- (not just casing) for 3 of the 12 stores:
--   COL-01: "NRW" vs "North Rhine-Westphalia"
--   NYC-01: "North East" vs "Northeast"
--   VAN-01: "British columbia" vs "British Columbia"
-- The canonical value chosen below matches the naming style used by
-- every other region in the file (full names, no abbreviations).
DROP TABLE IF EXISTS ref_store_region;
CREATE TABLE ref_store_region (store_id text, region_clean text);
INSERT INTO ref_store_region (store_id, region_clean) VALUES
    ('AUS-01', 'South'),
    ('CHI-01', 'Midwest'),
    ('COL-01', 'North Rhine-Westphalia'),
    ('LA-01',  'West'),
    ('LON-01', 'England'),
    ('MAN-01', 'England'),
    ('MUC-01', 'Bavaria'),
    ('NYC-01', 'Northeast'),
    ('PAR-01', 'Île-de-France'),
    ('SYD-01', 'New South Wales'),
    ('TOR-01', 'Ontario'),
    ('VAN-01', 'British Columbia');

-- 2b. Canonical Product_Name / Category / Subcategory per Product_ID.
-- Category and subcategory are already 1:1 with Product_ID once you
-- ignore case (e.g. "FURNITURE" vs "Furniture"); Product_Name is 1:1
-- and is null on 144 rows, recoverable from any other row of the
-- same product. DISTINCT ON is Postgres-specific — in MySQL/SQL
-- Server, replace with a ROW_NUMBER() + WHERE rn = 1 pattern.
DROP TABLE IF EXISTS ref_product;
CREATE TABLE ref_product AS
SELECT DISTINCT ON (product_id)
    product_id,
    product_name                                   AS product_name_clean,
    INITCAP(TRIM(product_category))                AS product_category_clean,
    INITCAP(TRIM(product_subcategory))              AS product_subcategory_clean
FROM stg_dedup
WHERE product_name IS NOT NULL
ORDER BY product_id;

-- Sanity check: expect 28 products, all with a non-null name
-- SELECT COUNT(*) FROM ref_product;

-- 2c. Canonical Customer_Name / Gender / Age per Customer_ID.
-- Name and gender are consistent per customer wherever recorded, so a
-- simple non-null aggregate recovers the value for rows where it is
-- missing. 6 customers (1 row each, 108 null rows in total minus the
-- 102 recoverable from siblings) have no name/gender anywhere and are
-- labelled 'Unknown'.
-- Age: 4 customers carry two different ages across their rows,
-- including two out-of-range values (age 4 and age 112, alongside a
-- valid age for the same customer). The rule below prefers an
-- in-range age (18–100) over an out-of-range one, then the most
-- frequently recorded value, then the most recent order as a final
-- tiebreaker.
DROP TABLE IF EXISTS customer_name_gender;
CREATE TABLE customer_name_gender AS
SELECT
    customer_id,
    COALESCE(MAX(customer_name), 'Unknown Customer') AS customer_name_clean,
    COALESCE(
        MAX(
            CASE
                WHEN UPPER(TRIM(customer_gender)) = 'MALE' THEN 'Male'
                WHEN UPPER(TRIM(customer_gender)) = 'FEMALE' THEN 'Female'
                WHEN UPPER(TRIM(customer_gender)) IN ('NON BINARY', 'NON-BINARY') THEN 'Non-Binary'
            END
        ), 'Unknown') AS customer_gender_clean
FROM stg_dedup
GROUP BY customer_id;

DROP TABLE IF EXISTS customer_age_candidates;
CREATE TABLE customer_age_candidates AS
SELECT
    customer_id,
    CAST(customer_age AS NUMERIC) AS age,
    CAST(order_date AS DATE) AS order_date,
    CASE WHEN CAST(customer_age AS NUMERIC) BETWEEN 18 AND 100 THEN 1 ELSE 0 END AS is_valid_range,
    COUNT(*) OVER (PARTITION BY customer_id, customer_age) AS freq
FROM stg_dedup
WHERE customer_age IS NOT NULL;

DROP TABLE IF EXISTS customer_age_resolved;
CREATE TABLE customer_age_resolved AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY is_valid_range DESC, freq DESC, order_date DESC
           ) AS rn
    FROM customer_age_candidates
)
SELECT customer_id, age AS age_clean
FROM ranked
WHERE rn = 1;

DROP TABLE IF EXISTS customer_resolved;
CREATE TABLE customer_resolved AS
SELECT
    ng.customer_id,
    ng.customer_name_clean,
    ng.customer_gender_clean,
    ar.age_clean
FROM customer_name_gender ng
LEFT JOIN customer_age_resolved ar ON ar.customer_id = ng.customer_id;


-- =====================================================================
-- SECTION 3 — TYPE CASTING + TEXT NORMALIZATION
-- Casing/spacing variants that INITCAP(TRIM()) safely resolves:
--   Order_Status:     completed/COMPLETED/Completed -> Completed, etc.
--   Product_Category: handled via ref_product instead (see Section 2b)
--   City:             ' New York ' / 'LOS ANGELES' / 'munich' -> proper case
-- Payment_Method needs explicit mapping because "DebitCard" has no
-- space and can't be fixed by INITCAP alone.
-- =====================================================================

DROP TABLE IF EXISTS stg_typed;
CREATE TABLE stg_typed AS
SELECT
    d.transaction_id,
    d.order_id,
    d.customer_id,
    cr.customer_name_clean,
    cr.customer_gender_clean,
    INITCAP(TRIM(d.customer_segment))              AS customer_segment,   -- see note below
    cr.age_clean                                   AS customer_age,
    CAST(d.order_date AS DATE)                     AS order_date,
    CAST(d.order_time AS TIME)                     AS order_time,
    CAST(d.order_year AS INTEGER)                  AS order_year,
    INITCAP(TRIM(d.sales_channel))                 AS sales_channel,
    d.store_id,
    d.store_name,                                                       -- already 1:1 per store, no cleaning needed
    d.country,                                                          -- already clean
    sr.region_clean                                AS region,
    INITCAP(TRIM(d.city))                          AS city,
    d.product_id,
    rp.product_name_clean                          AS product_name,
    rp.product_category_clean                      AS product_category,
    rp.product_subcategory_clean                   AS product_subcategory,
    CAST(d.quantity AS INTEGER)                    AS quantity_raw,
    CAST(d.unit_price AS NUMERIC(12,2))            AS unit_price,
    CAST(d.discount_percentage AS NUMERIC(6,2))    AS discount_pct_raw,
    CAST(d.sales_amount AS NUMERIC(12,2))          AS sales_amount_raw,
    CAST(d.cost_amount AS NUMERIC(12,2))           AS cost_amount,
    CAST(d.profit AS NUMERIC(12,2))                AS profit_raw,
    CASE
        WHEN UPPER(TRIM(d.payment_method)) = 'APPLE PAY' THEN 'Apple Pay'
        WHEN UPPER(TRIM(d.payment_method)) = 'BANK TRANSFER' THEN 'Bank Transfer'
        WHEN UPPER(TRIM(d.payment_method)) = 'CASH' THEN 'Cash'
        WHEN UPPER(TRIM(d.payment_method)) = 'CREDIT CARD' THEN 'Credit Card'
        WHEN UPPER(REPLACE(TRIM(d.payment_method), ' ', '')) = 'DEBITCARD' THEN 'Debit Card'
        WHEN UPPER(TRIM(d.payment_method)) = 'PAYPAL' THEN 'PayPal'
        WHEN d.payment_method IS NULL THEN 'Unknown'
        ELSE INITCAP(TRIM(d.payment_method))
    END                                             AS payment_method,
    INITCAP(TRIM(d.order_status))                  AS order_status,
    INITCAP(TRIM(d.shipping_method))               AS shipping_method,
    CAST(d.delivery_days AS NUMERIC)               AS delivery_days_raw,
    INITCAP(TRIM(d.return_flag))                   AS return_flag,
    INITCAP(TRIM(d.return_reason))                 AS return_reason,
    d.sales_representative,                                             -- already clean, no variants
    d.promotion_code,
    CAST(d.customer_rating AS NUMERIC)             AS customer_rating,
    CAST(CAST(d.inventory_level AS NUMERIC) AS INTEGER) AS inventory_level
FROM stg_dedup d
LEFT JOIN ref_store_region sr ON sr.store_id = d.store_id
LEFT JOIN ref_product rp      ON rp.product_id = d.product_id
LEFT JOIN customer_resolved cr ON cr.customer_id = d.customer_id;

-- NOTE on customer_segment: the source mixes two ideas in one column —
-- lifecycle ('New Customer' / 'Returning Customer') and account type
-- ('Consumer' / 'Corporate' / 'Premium' / 'Small Business'). 527
-- customers appear as both 'New Customer' and 'Returning Customer' on
-- different rows, which just reflects lifecycle changing over time —
-- it is not a data error. Don't use this column's lifecycle values as
-- a fixed customer attribute; derive current lifecycle downstream in
-- 02_model.sql from actual order history (e.g. 1st order vs. later
-- orders) instead of trusting the label on any single row.


-- =====================================================================
-- SECTION 4 — FINANCIAL RECONCILIATION
-- Business rule: Sales_Amount should equal Quantity x Unit_Price x
-- (1 - Discount% / 100), and Profit should equal Sales_Amount -
-- Cost_Amount. Where a row breaks one of these rules, Cost_Amount and
-- Profit are used as the arbiter, since they reconcile with each
-- other correctly in every affected row.
--
-- Validated counts (rerun against the source file, will match on a
-- fresh load):
--   8  rows have Quantity <= 0            -> quantity recovered
--   3  rows have a Discount% outside the {0,5,10,15,20,25,30} tiers
--                                          -> nearest tier recovered
--   68 rows have Sales_Amount != Qty x Price x (1-Disc%) beyond a
--      $0.10 / 0.2% tolerance after the two fixes above
--   65 of those 68 reconcile with Cost_Amount + Profit and are
--      recomputed from the formula
--   3  of those 68 do NOT reconcile with anything (Sales_Amount,
--      Cost_Amount and Profit are internally consistent with each
--      other, but all three disagree with Quantity x Price x Disc%
--      by a magnitude, e.g. exactly ~10x). These are flagged
--      is_unresolved_amount = TRUE and keep their reported
--      Sales_Amount rather than the formula result — trust the
--      reported transaction value when it's the one no other field
--      contradicts. Affected: T02013939, T02015860, T02017824.
--   45 rows have Sales_Amount and the formula agreeing, but
--      Profit != Sales_Amount - Cost_Amount -> Profit recomputed
-- =====================================================================

DROP TABLE IF EXISTS stg_financial;
CREATE TABLE stg_financial AS
WITH flagged AS (
    SELECT *,
        (quantity_raw <= 0)                                   AS is_bad_qty,
        (discount_pct_raw NOT IN (0,5,10,15,20,25,30))         AS is_bad_disc,
        (ABS(sales_amount_raw - cost_amount - profit_raw) <= 0.05) AS profit_confirms_sales
    FROM stg_typed
),
qty_fixed AS (
    SELECT *,
        CASE
            WHEN is_bad_qty AND profit_confirms_sales
                 AND unit_price > 0 AND discount_pct_raw < 100
            THEN ROUND(sales_amount_raw / (unit_price * (1 - discount_pct_raw / 100.0)))
            ELSE quantity_raw
        END AS quantity_clean
    FROM flagged
),
tiers (tier) AS (VALUES (0),(5),(10),(15),(20),(25),(30)),
disc_candidates AS (
    SELECT
        q.transaction_id,
        t.tier,
        ROW_NUMBER() OVER (
            PARTITION BY q.transaction_id
            ORDER BY ABS(t.tier - (1 - q.sales_amount_raw / (q.quantity_clean * q.unit_price)) * 100)
        ) AS rk
    FROM qty_fixed q
    CROSS JOIN tiers t
    WHERE q.is_bad_disc AND q.profit_confirms_sales AND q.quantity_clean > 0
),
disc_fixed AS (
    SELECT q.*,
        CASE
            WHEN q.is_bad_disc AND q.profit_confirms_sales THEN
                (SELECT dc.tier FROM disc_candidates dc
                 WHERE dc.transaction_id = q.transaction_id AND dc.rk = 1)
            ELSE q.discount_pct_raw
        END AS discount_pct_clean
    FROM qty_fixed q
),
recalced AS (
    SELECT *,
        ROUND(quantity_clean * unit_price * (1 - discount_pct_clean / 100.0), 2) AS calc_amount
    FROM disc_fixed
),
sales_resolved AS (
    SELECT *,
        CASE
            WHEN ABS(sales_amount_raw - calc_amount) > GREATEST(0.10, 0.002 * ABS(calc_amount))
                 AND ABS(calc_amount - cost_amount - profit_raw) <= 0.05
            THEN calc_amount
            ELSE sales_amount_raw
        END AS sales_amount_clean,
        (ABS(sales_amount_raw - calc_amount) > GREATEST(0.10, 0.002 * ABS(calc_amount))
         AND ABS(calc_amount - cost_amount - profit_raw) > 0.05) AS is_unresolved_amount
    FROM recalced
)
SELECT
    *,
    CASE
        WHEN ABS(sales_amount_clean - cost_amount - profit_raw) > 0.05 AND NOT is_unresolved_amount
        THEN ROUND(sales_amount_clean - cost_amount, 2)
        ELSE profit_raw
    END AS profit_clean
FROM sales_resolved;

-- Sanity checks:
-- SELECT COUNT(*) FILTER (WHERE is_bad_qty) FROM stg_financial;             -- expect 8
-- SELECT COUNT(*) FILTER (WHERE is_bad_disc) FROM stg_financial;            -- expect 3
-- SELECT COUNT(*) FILTER (WHERE is_unresolved_amount) FROM stg_financial;   -- expect 3


-- =====================================================================
-- SECTION 5 — DELIVERY DAYS IMPUTATION
-- Pickup orders should always be 0 days (confirmed: every non-null
-- Pickup row in the source is exactly 0) -> fill the 67 nulls with 0.
-- The other shipping methods get their nulls filled with the median
-- for that method (13 Express, 8 Next Day, 74 Standard nulls).
-- PERCENTILE_CONT is Postgres/SQL Server syntax; MySQL 8 has no
-- built-in equivalent and needs a manual ORDER BY + row-count formula.
-- =====================================================================

DROP TABLE IF EXISTS ref_delivery_median;
CREATE TABLE ref_delivery_median AS
SELECT
    shipping_method,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days_raw) AS median_days
FROM stg_financial
WHERE delivery_days_raw IS NOT NULL
GROUP BY shipping_method;


-- =====================================================================
-- SECTION 6 — BUSINESS FLAGS
-- Order_Status and Return_Flag disagree on 276 rows (Return_Flag =
-- 'Yes' while Order_Status isn't 'Returned'). Rather than silently
-- overwrite one with the other, both signals are kept and a mismatch
-- flag is added for analyst visibility.
-- Cancelled orders (893 of them) still carry a positive Sales_Amount
-- in the source; they are kept in the fact table for completeness but
-- excluded from revenue via is_net_revenue.
-- =====================================================================

DROP TABLE IF EXISTS sales_clean;
CREATE TABLE sales_clean AS
SELECT
    f.transaction_id,
    f.order_id,
    f.customer_id,
    f.customer_name_clean                                          AS customer_name,
    f.customer_gender_clean                                        AS customer_gender,
    f.customer_segment,
    f.customer_age,
    f.order_date,
    f.order_time,
    f.order_year,
    f.sales_channel,
    f.store_id,
    f.store_name,
    f.country,
    f.region,
    f.city,
    f.product_id,
    f.product_name,
    f.product_category,
    f.product_subcategory,
    f.quantity_clean                                               AS quantity,
    f.unit_price,
    f.discount_pct_clean                                           AS discount_percentage,
    f.sales_amount_clean                                           AS sales_amount,
    f.cost_amount,
    f.profit_clean                                                 AS profit,
    f.payment_method,
    f.order_status,
    f.shipping_method,
    COALESCE(
        f.delivery_days_raw,
        CASE WHEN f.shipping_method = 'Pickup' THEN 0 ELSE rdm.median_days END
    )                                                               AS delivery_days,
    f.return_flag,
    f.return_reason,
    f.sales_representative,
    f.promotion_code,
    f.customer_rating,
    f.inventory_level,
    f.is_unresolved_amount,
    (f.order_status = 'Cancelled')                                 AS is_cancelled,
    (f.return_flag = 'Yes' OR f.order_status = 'Returned')         AS is_returned,
    (f.return_flag = 'Yes' AND f.order_status <> 'Returned')       AS status_return_mismatch,
    (f.order_status <> 'Cancelled')                                AS is_net_revenue
FROM stg_financial f
LEFT JOIN ref_delivery_median rdm ON rdm.shipping_method = f.shipping_method;

-- Sanity check: expect 18000
-- SELECT COUNT(*) FROM sales_clean;


-- =====================================================================
-- SECTION 7 — DATA QUALITY LOG
-- Documents what this script changed and how many rows each rule hit.
-- Counts are computed dynamically so they self-verify on every rerun.
-- =====================================================================

DROP TABLE IF EXISTS data_quality_log;
CREATE TABLE data_quality_log (
    step         text,
    rule         text,
    rows_affected integer,
    logged_at    timestamp DEFAULT now()
);

INSERT INTO data_quality_log (step, rule, rows_affected) VALUES
    ('1. Dedup',        'Exact duplicate Transaction_ID removed',
        (SELECT (SELECT COUNT(*) FROM stg_sales_raw) - (SELECT COUNT(*) FROM stg_dedup))),
    ('2. Reference',    'Product_Name filled from Product_ID lookup',
        (SELECT COUNT(*) FROM stg_dedup WHERE product_name IS NULL)),
    ('2. Reference',    'Customer_Name unrecoverable, set to Unknown Customer',
        (SELECT COUNT(*) FROM customer_name_gender WHERE customer_name_clean = 'Unknown Customer')),
    ('2. Reference',    'Customer_Gender unrecoverable, set to Unknown',
        (SELECT COUNT(*) FROM customer_name_gender WHERE customer_gender_clean = 'Unknown')),
    ('2. Reference',    'Customers with conflicting recorded ages, resolved by valid-range/frequency/recency',
        (SELECT COUNT(*) FROM (
            SELECT customer_id FROM customer_age_candidates
            GROUP BY customer_id HAVING COUNT(DISTINCT age) > 1
         ) t)),
    ('3. Geography',    'Region normalized via Store_ID canonical lookup (NRW / North East / British columbia variants)',
        (SELECT COUNT(*) FROM stg_dedup WHERE region IN ('NRW','North East','British columbia'))),
    ('3. Text',         'Payment_Method casing/spacing normalized',
        (SELECT COUNT(*) FROM stg_dedup WHERE payment_method IN ('credit card','paypal','DebitCard','Bank transfer')) ),
    ('4. Financial',    'Quantity <= 0 recovered from Sales/Cost/Profit',
        (SELECT COUNT(*) FILTER (WHERE is_bad_qty) FROM stg_financial)),
    ('4. Financial',    'Discount% outside valid tiers, recovered',
        (SELECT COUNT(*) FILTER (WHERE is_bad_disc) FROM stg_financial)),
    ('4. Financial',    'Sales_Amount recomputed from Qty x Price x (1-Disc%)',
        (SELECT COUNT(*) FROM stg_financial WHERE sales_amount_clean <> sales_amount_raw AND NOT is_unresolved_amount)),
    ('4. Financial',    'Profit recomputed as Sales_Amount - Cost_Amount',
        (SELECT COUNT(*) FROM stg_financial WHERE profit_clean <> profit_raw)),
    ('4. Financial',    'Unresolved amount anomalies, original Sales_Amount kept and flagged',
        (SELECT COUNT(*) FILTER (WHERE is_unresolved_amount) FROM stg_financial)),
    ('5. Delivery',     'Delivery_Days imputed (0 for Pickup, median for other methods)',
        (SELECT COUNT(*) FROM stg_financial WHERE delivery_days_raw IS NULL)),
    ('6. Business rule','Cancelled orders retained but excluded from net revenue',
        (SELECT COUNT(*) FROM sales_clean WHERE is_cancelled)),
    ('6. Business rule','Return_Flag / Order_Status disagreement flagged for review',
        (SELECT COUNT(*) FROM sales_clean WHERE status_return_mismatch));

-- Review the log:
-- SELECT * FROM data_quality_log ORDER BY step;


-- =====================================================================
-- SECTION 8 — FINAL VALIDATION
-- =====================================================================

-- Row count should match the deduped source exactly (no rows dropped)
SELECT
    (SELECT COUNT(*) FROM stg_dedup)  AS deduped_rows,
    (SELECT COUNT(*) FROM sales_clean) AS clean_rows;

-- No remaining nulls in fields that should always be populated
SELECT COUNT(*) AS rows_missing_core_fields
FROM sales_clean
WHERE customer_name IS NULL OR region IS NULL OR product_category IS NULL
   OR payment_method IS NULL OR order_status IS NULL;

-- Quick look at what changed financially (compare the SAME 65 rows on
-- both sides — summing the whole table on one side was the earlier bug)
SELECT COUNT(*) AS rows_changed,
       ROUND(SUM(sc.sales_amount) - SUM(sf.sales_amount_raw), 2) AS net_revenue_impact
FROM sales_clean sc
JOIN stg_financial sf ON sf.transaction_id = sc.transaction_id
WHERE sc.sales_amount <> sf.sales_amount_raw;