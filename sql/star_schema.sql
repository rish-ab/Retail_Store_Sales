-- =====================================================================
-- 02_star_schema.sql
-- Star schema built on retail.sales_clean (output of clean.sql)
--
-- Run:  docker exec -i resume_pg psql -U datasci -d retail_analytics < sql/02_star_schema.sql
--       (or from inside the container: \i /sql/02_star_schema.sql)
--
-- Design choices
--   * Natural keys (store_id, product_id, customer_id, transaction_id) are
--     used as primary keys. They are already unique and stable, so
--     surrogate keys would add joins without adding value here.
--   * dim_date uses an integer yyyymmdd key (Tableau / Power BI friendly).
--   * Low-cardinality descriptors (payment, shipping, channel, status,
--     promo, return reason) stay on the fact table as degenerate dimensions.
--   * The cleaning flags stay on the fact table so BI tools can filter on
--     them and the cleaning decisions remain visible.
-- =====================================================================

SET search_path TO retail;

-- Drop in dependency order (views first, then fact, then dims)
DROP VIEW  IF EXISTS v_monthly_kpis, v_category_performance, v_product_performance,
                     v_store_region_performance, v_discount_impact, v_customer_rfm,
                     v_return_cancel_rates, v_payment_mix, v_delivery_performance CASCADE;
DROP TABLE IF EXISTS fact_sales CASCADE;
DROP TABLE IF EXISTS dim_date, dim_product, dim_customer, dim_store CASCADE;


-- ---------------------------------------------------------------------
-- dim_date : one row per calendar day 2022-2025
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key      integer  PRIMARY KEY,          -- yyyymmdd
    full_date     date     NOT NULL UNIQUE,
    year          smallint NOT NULL,
    quarter       smallint NOT NULL,
    month         smallint NOT NULL,
    month_name    text     NOT NULL,
    year_month    text     NOT NULL,             -- '2024-03', sorts correctly
    month_start   date     NOT NULL,
    iso_week      smallint NOT NULL,
    day_of_month  smallint NOT NULL,
    weekday_num   smallint NOT NULL,             -- 1 = Monday ... 7 = Sunday
    weekday_name  text     NOT NULL,
    is_weekend    boolean  NOT NULL
);

INSERT INTO dim_date
SELECT
    to_char(d, 'YYYYMMDD')::int,
    d::date,
    EXTRACT(year    FROM d)::smallint,
    EXTRACT(quarter FROM d)::smallint,
    EXTRACT(month   FROM d)::smallint,
    trim(to_char(d, 'Month')),
    to_char(d, 'YYYY-MM'),
    date_trunc('month', d)::date,
    EXTRACT(week    FROM d)::smallint,
    EXTRACT(day     FROM d)::smallint,
    EXTRACT(isodow  FROM d)::smallint,
    trim(to_char(d, 'Day')),
    EXTRACT(isodow  FROM d) IN (6, 7)
FROM generate_series('2022-01-01'::date, '2025-12-31'::date, interval '1 day') AS g(d);


-- ---------------------------------------------------------------------
-- dim_store : one row per store_id
-- mode() guards against any leftover attribute variants per store
-- ---------------------------------------------------------------------
CREATE TABLE dim_store AS
SELECT
    store_id,
    mode() WITHIN GROUP (ORDER BY store_name) AS store_name,
    mode() WITHIN GROUP (ORDER BY country)    AS country,
    mode() WITHIN GROUP (ORDER BY region)     AS region,
    mode() WITHIN GROUP (ORDER BY initcap(city)) AS city
FROM sales_clean
GROUP BY store_id;

ALTER TABLE dim_store ADD PRIMARY KEY (store_id);


-- ---------------------------------------------------------------------
-- dim_product : one row per product_id
-- ---------------------------------------------------------------------
CREATE TABLE dim_product AS
SELECT
    product_id,
    mode() WITHIN GROUP (ORDER BY product_name)        AS product_name,
    mode() WITHIN GROUP (ORDER BY product_category)    AS product_category,
    mode() WITHIN GROUP (ORDER BY product_subcategory) AS product_subcategory
FROM sales_clean
GROUP BY product_id;

ALTER TABLE dim_product ADD PRIMARY KEY (product_id);


-- ---------------------------------------------------------------------
-- dim_customer : one row per customer_id
-- Name / gender / age were already resolved in clean.sql (one value per
-- customer). Segment can legitimately change over time (New -> Returning),
-- so the most recent segment is used.
-- ---------------------------------------------------------------------
CREATE TABLE dim_customer AS
SELECT DISTINCT ON (customer_id)
    customer_id,
    customer_name,
    customer_gender,
    customer_age,
    CASE
        WHEN customer_age IS NULL   THEN 'Unknown'
        WHEN customer_age < 25      THEN '18-24'
        WHEN customer_age < 35      THEN '25-34'
        WHEN customer_age < 45      THEN '35-44'
        WHEN customer_age < 55      THEN '45-54'
        WHEN customer_age < 65      THEN '55-64'
        ELSE '65+'
    END AS age_band,
    customer_segment AS latest_segment
FROM sales_clean
ORDER BY customer_id, order_date DESC, order_time DESC;

ALTER TABLE dim_customer ADD PRIMARY KEY (customer_id);


-- ---------------------------------------------------------------------
-- fact_sales : one row per transaction (grain = transaction_id)
-- ---------------------------------------------------------------------
CREATE TABLE fact_sales (
    transaction_id          text PRIMARY KEY,
    order_id                text NOT NULL,

    -- foreign keys
    date_key                integer NOT NULL REFERENCES dim_date(date_key),
    customer_id             text    NOT NULL REFERENCES dim_customer(customer_id),
    product_id              text    NOT NULL REFERENCES dim_product(product_id),
    store_id                text    NOT NULL REFERENCES dim_store(store_id),

    order_time              time,

    -- measures
    quantity                numeric,
    unit_price              numeric(12,2),
    discount_percentage     numeric,
    sales_amount            numeric,
    cost_amount             numeric(12,2),
    profit                  numeric,
    delivery_days           double precision,
    customer_rating         numeric,
    inventory_level         integer,

    -- degenerate dimensions
    sales_channel           text,
    payment_method          text,
    order_status            text,
    shipping_method         text,
    return_flag             text,
    return_reason           text,
    sales_representative    text,
    promotion_code          text,

    -- data-quality / business-rule flags from clean.sql
    is_unresolved_amount    boolean NOT NULL,
    is_cancelled            boolean NOT NULL,
    is_returned             boolean NOT NULL,
    status_return_mismatch  boolean NOT NULL,
    is_net_revenue          boolean NOT NULL
);

INSERT INTO fact_sales
SELECT
    transaction_id,
    order_id,
    to_char(order_date, 'YYYYMMDD')::int,
    customer_id,
    product_id,
    store_id,
    order_time,
    quantity,
    unit_price,
    discount_percentage,
    sales_amount,
    cost_amount,
    profit,
    delivery_days,
    customer_rating,
    inventory_level,
    sales_channel,
    payment_method,
    order_status,
    shipping_method,
    return_flag,
    return_reason,
    sales_representative,
    promotion_code,
    is_unresolved_amount,
    is_cancelled,
    is_returned,
    status_return_mismatch,
    is_net_revenue
FROM sales_clean;

CREATE INDEX ix_fact_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_customer ON fact_sales (customer_id);
CREATE INDEX ix_fact_product  ON fact_sales (product_id);
CREATE INDEX ix_fact_store    ON fact_sales (store_id);
CREATE INDEX ix_fact_order    ON fact_sales (order_id);

ANALYZE;


-- ---------------------------------------------------------------------
-- Reconciliation checks (all should pass; save output for the README)
-- ---------------------------------------------------------------------
SELECT 'row count matches sales_clean' AS check_name,
       (SELECT COUNT(*) FROM sales_clean) = (SELECT COUNT(*) FROM fact_sales) AS passed
UNION ALL
SELECT 'net revenue matches sales_clean',
       (SELECT SUM(sales_amount) FROM sales_clean WHERE is_net_revenue)
     = (SELECT SUM(sales_amount) FROM fact_sales  WHERE is_net_revenue)
UNION ALL
SELECT 'no orphan dates',
       NOT EXISTS (SELECT 1 FROM fact_sales f LEFT JOIN dim_date d USING (date_key) WHERE d.date_key IS NULL)
UNION ALL
SELECT 'cancelled rows = 893',
       (SELECT COUNT(*) FROM fact_sales WHERE is_cancelled) = 893
UNION ALL
SELECT 'status/return mismatches = 276',
       (SELECT COUNT(*) FROM fact_sales WHERE status_return_mismatch) = 276;
