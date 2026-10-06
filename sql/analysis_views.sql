-- =====================================================================
-- 03_analysis_views.sql
-- One view per business question. Dashboards just do SELECT * FROM view.
--
-- Revenue convention: "net" figures use is_net_revenue = true, i.e. only
-- cancelled orders are excluded. Returned orders still count in net
-- revenue here (clean.sql's rule); v_return_cancel_rates shows how much
-- revenue sits in returned orders so you can judge that separately.
--
-- Order convention: raw Order_ID is NOT used to count orders. 21% of
-- Order_ID values span more than one customer or date (6,512 of 18,000
-- transactions sit inside one of these), which understates order count
-- and inflates Average Order Value by ~22% ($561 vs. the true $459).
-- "An order" here means one (customer_id, date_key) combination instead.
-- Order_ID itself is still stored on fact_sales as raw source context,
-- just not used for counting.
-- =====================================================================

SET search_path TO retail;


-- ---------------------------------------------------------------------
-- 1. Monthly KPIs with MoM and YoY growth
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_kpis AS
WITH monthly AS (
    SELECT
        d.month_start,
        d.year,
        d.month,
        d.year_month,
        SUM(f.sales_amount)                          AS net_revenue,
        SUM(f.profit)                                AS net_profit,
        COUNT(DISTINCT (f.customer_id, f.date_key))  AS orders,
        SUM(f.quantity)                              AS units_sold,
        COUNT(DISTINCT f.customer_id)                AS active_customers
    FROM fact_sales f
    JOIN dim_date d USING (date_key)
    WHERE f.is_net_revenue
    GROUP BY d.month_start, d.year, d.month, d.year_month
)
SELECT
    month_start,
    year,
    month,
    year_month,
    ROUND(net_revenue, 2)                                          AS net_revenue,
    ROUND(net_profit, 2)                                           AS net_profit,
    ROUND(100 * net_profit / NULLIF(net_revenue, 0), 2)            AS profit_margin_pct,
    orders,
    units_sold,
    active_customers,
    ROUND(net_revenue / NULLIF(orders, 0), 2)                      AS avg_order_value,
    ROUND(100 * (net_revenue - LAG(net_revenue, 1)  OVER w)
              / NULLIF(LAG(net_revenue, 1)  OVER w, 0), 2)         AS revenue_mom_pct,
    ROUND(100 * (net_revenue - LAG(net_revenue, 12) OVER w)
              / NULLIF(LAG(net_revenue, 12) OVER w, 0), 2)         AS revenue_yoy_pct,
    ROUND(SUM(net_revenue) OVER (PARTITION BY year ORDER BY month_start), 2) AS revenue_ytd
FROM monthly
WINDOW w AS (ORDER BY month_start);


-- ---------------------------------------------------------------------
-- 2. Category / subcategory performance (profit-first)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_category_performance AS
SELECT
    p.product_category,
    p.product_subcategory,
    COUNT(*)                                                       AS transactions,
    SUM(f.quantity)                                                AS units_sold,
    ROUND(SUM(f.sales_amount), 2)                                  AS net_revenue,
    ROUND(SUM(f.profit), 2)                                        AS net_profit,
    ROUND(100 * SUM(f.profit) / NULLIF(SUM(f.sales_amount), 0), 2) AS profit_margin_pct,
    ROUND(100 * SUM(f.profit) / NULLIF(SUM(SUM(f.profit)) OVER (), 0), 2) AS share_of_total_profit_pct,
    RANK() OVER (ORDER BY SUM(f.profit) DESC)                      AS profit_rank
FROM fact_sales f
JOIN dim_product p USING (product_id)
WHERE f.is_net_revenue
GROUP BY p.product_category, p.product_subcategory;


-- ---------------------------------------------------------------------
-- 3. Product performance: top and bottom by profit
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_product_performance AS
SELECT
    p.product_id,
    p.product_name,
    p.product_category,
    p.product_subcategory,
    SUM(f.quantity)                                                AS units_sold,
    ROUND(SUM(f.sales_amount), 2)                                  AS net_revenue,
    ROUND(SUM(f.profit), 2)                                        AS net_profit,
    ROUND(100 * SUM(f.profit) / NULLIF(SUM(f.sales_amount), 0), 2) AS profit_margin_pct,
    ROUND(AVG(f.discount_percentage), 2)                           AS avg_discount_pct,
    ROUND(AVG(f.customer_rating), 2)                               AS avg_rating,
    RANK() OVER (ORDER BY SUM(f.profit) DESC)                      AS profit_rank_desc,
    RANK() OVER (ORDER BY SUM(f.profit) ASC)                       AS profit_rank_asc,
    RANK() OVER (PARTITION BY p.product_category ORDER BY SUM(f.profit) DESC) AS rank_in_category
FROM fact_sales f
JOIN dim_product p USING (product_id)
WHERE f.is_net_revenue
GROUP BY p.product_id, p.product_name, p.product_category, p.product_subcategory;


-- ---------------------------------------------------------------------
-- 4. Store and region performance (feeds the map page)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_store_region_performance AS
SELECT
    s.store_id,
    s.store_name,
    s.country,
    s.region,
    s.city,
    COUNT(DISTINCT (f.customer_id, f.date_key))                    AS orders,
    ROUND(SUM(f.sales_amount), 2)                                  AS net_revenue,
    ROUND(SUM(f.profit), 2)                                        AS net_profit,
    ROUND(100 * SUM(f.profit) / NULLIF(SUM(f.sales_amount), 0), 2) AS profit_margin_pct,
    ROUND(SUM(f.sales_amount) / NULLIF(COUNT(DISTINCT (f.customer_id, f.date_key)), 0), 2) AS avg_order_value,
    ROUND(AVG(f.delivery_days)::numeric, 2)                        AS avg_delivery_days,
    ROUND(AVG(f.customer_rating), 2)                               AS avg_rating,
    RANK() OVER (ORDER BY SUM(f.profit) DESC)                      AS profit_rank,
    RANK() OVER (PARTITION BY s.country ORDER BY SUM(f.profit) DESC) AS profit_rank_in_country
FROM fact_sales f
JOIN dim_store s USING (store_id)
WHERE f.is_net_revenue
GROUP BY s.store_id, s.store_name, s.country, s.region, s.city;


-- ---------------------------------------------------------------------
-- 5. Discount impact on volume and margin
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_discount_impact AS
SELECT
    f.discount_percentage,
    COUNT(*)                                                       AS transactions,
    SUM(f.quantity)                                                AS units_sold,
    ROUND(AVG(f.quantity), 2)                                      AS avg_units_per_txn,
    ROUND(SUM(f.sales_amount), 2)                                  AS net_revenue,
    ROUND(SUM(f.profit), 2)                                        AS net_profit,
    ROUND(100 * SUM(f.profit) / NULLIF(SUM(f.sales_amount), 0), 2) AS profit_margin_pct,
    ROUND(AVG(f.profit), 2)                                        AS avg_profit_per_txn,
    COUNT(*) FILTER (WHERE f.profit < 0)                           AS loss_making_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.profit < 0) / COUNT(*), 2) AS loss_making_pct
FROM fact_sales f
WHERE f.is_net_revenue
GROUP BY f.discount_percentage;


-- ---------------------------------------------------------------------
-- 6. Customer RFM segmentation
-- Recency is measured against the last order date in the data, not today,
-- so the result does not drift when you re-run it later.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_rfm AS
WITH base AS (
    SELECT
        f.customer_id,
        MAX(d.full_date)                             AS last_order_date,
        COUNT(DISTINCT (f.customer_id, f.date_key))  AS frequency,
        SUM(f.sales_amount)                          AS monetary
    FROM fact_sales f
    JOIN dim_date d USING (date_key)
    WHERE f.is_net_revenue
    GROUP BY f.customer_id
),
scored AS (
    SELECT
        b.*,
        (SELECT MAX(full_date) FROM dim_date d2
           JOIN fact_sales f2 USING (date_key))       AS data_end_date
    FROM base b
),
ranked AS (
    SELECT
        s.*,
        (data_end_date - last_order_date)                                AS recency_days,
        NTILE(5) OVER (ORDER BY (data_end_date - last_order_date) DESC)  AS r_score,
        NTILE(5) OVER (ORDER BY frequency)                               AS f_score,
        NTILE(5) OVER (ORDER BY monetary)                                AS m_score
    FROM scored s
)
SELECT
    r.customer_id,
    c.customer_name,
    c.customer_gender,
    c.age_band,
    c.latest_segment,
    r.last_order_date,
    r.recency_days,
    r.frequency,
    ROUND(r.monetary, 2)                                    AS monetary,
    ROUND(r.monetary / NULLIF(r.frequency, 0), 2)           AS avg_order_value,
    r.r_score, r.f_score, r.m_score,
    CASE
        WHEN r.r_score >= 4 AND r.f_score >= 4 AND r.m_score >= 4 THEN 'Champions'
        WHEN r.r_score >= 3 AND r.f_score >= 3                    THEN 'Loyal'
        WHEN r.r_score >= 4 AND r.f_score <= 2                    THEN 'New / Promising'
        WHEN r.r_score <= 2 AND r.f_score >= 4                    THEN 'At Risk'
        WHEN r.r_score <= 2 AND r.f_score <= 2                    THEN 'Lost'
        ELSE 'Needs Attention'
    END AS rfm_segment
FROM ranked r
JOIN dim_customer c USING (customer_id);


-- ---------------------------------------------------------------------
-- 7. Return and cancellation rates by category and region
-- Uses ALL rows (cancelled included) so the denominators are honest.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_return_cancel_rates AS
SELECT
    p.product_category,
    s.country,
    s.region,
    COUNT(*)                                                                AS transactions,
    COUNT(*) FILTER (WHERE f.is_cancelled)                                  AS cancelled_txns,
    COUNT(*) FILTER (WHERE f.is_returned)                                   AS returned_txns,
    COUNT(*) FILTER (WHERE f.status_return_mismatch)                        AS status_mismatch_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_cancelled) / COUNT(*), 2)     AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_returned)
                / NULLIF(COUNT(*) FILTER (WHERE NOT f.is_cancelled), 0), 2) AS return_rate_pct,
    ROUND(COALESCE(SUM(f.sales_amount) FILTER (WHERE f.is_returned AND NOT f.is_cancelled), 0), 2)
                                                                            AS returned_revenue
FROM fact_sales f
JOIN dim_product p USING (product_id)
JOIN dim_store   s USING (store_id)
GROUP BY p.product_category, s.country, s.region;


-- ---------------------------------------------------------------------
-- 8. Payment method mix
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payment_mix AS
SELECT
    f.payment_method,
    f.sales_channel,
    COUNT(*)                                                       AS transactions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)             AS pct_of_transactions,
    ROUND(SUM(f.sales_amount), 2)                                  AS net_revenue,
    ROUND(SUM(f.sales_amount) / NULLIF(COUNT(*), 0), 2)            AS avg_transaction_value
FROM fact_sales f
WHERE f.is_net_revenue
GROUP BY f.payment_method, f.sales_channel;


-- ---------------------------------------------------------------------
-- 9. Delivery speed vs. outcomes (returns, cancellations, ratings)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_delivery_performance AS
SELECT
    f.shipping_method,
    COUNT(*)                                                       AS transactions,
    ROUND(AVG(f.delivery_days)::numeric, 2)                        AS avg_delivery_days,
    ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY f.delivery_days))::numeric, 1) AS median_delivery_days,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_cancelled) / COUNT(*), 2) AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_returned AND NOT f.is_cancelled)
                / NULLIF(COUNT(*) FILTER (WHERE NOT f.is_cancelled), 0), 2) AS return_rate_pct,
    ROUND(AVG(f.customer_rating) FILTER (WHERE NOT f.is_cancelled), 2)      AS avg_rating
FROM fact_sales f
GROUP BY f.shipping_method;
