SET search_path TO retail;

-- 1. Replace hard-coded audit numbers in Power BI
CREATE TABLE IF NOT EXISTS pipeline_stats (metric text PRIMARY KEY, metric_value numeric);
INSERT INTO pipeline_stats VALUES ('raw_rows_loaded', 18045)   -- or SELECT COUNT(*) FROM <your raw table>
ON CONFLICT (metric) DO UPDATE SET metric_value = EXCLUDED.metric_value;

-- 2. Promo-code performance (not analysed yet)
CREATE OR REPLACE VIEW v_promo_performance AS
SELECT COALESCE(NULLIF(TRIM(promotion_code), ''), 'No promo')       AS promotion_code,
       COUNT(*)                                                      AS transactions,
       ROUND(AVG(discount_percentage), 1)                            AS avg_discount_pct,
       ROUND(SUM(sales_amount), 2)                                   AS net_revenue,
       ROUND(SUM(profit), 2)                                         AS net_profit,
       ROUND(100 * SUM(profit) / NULLIF(SUM(sales_amount), 0), 2)    AS margin_pct
FROM fact_sales WHERE is_net_revenue GROUP BY 1;

-- 3. Discount depth by category
CREATE OR REPLACE VIEW v_discount_by_category AS
SELECT p.product_category, f.discount_percentage,
       COUNT(*) AS transactions,
       ROUND(100 * SUM(f.profit) / NULLIF(SUM(f.sales_amount), 0), 2) AS margin_pct
FROM fact_sales f JOIN dim_product p USING (product_id)
WHERE f.is_net_revenue GROUP BY 1, 2;

-- 4. One flat table for Tableau Public
CREATE OR REPLACE VIEW v_sales_flat AS
SELECT f.*, d.full_date, d.year, d.quarter, d.month, d.year_month,
       p.product_name, p.product_category, p.product_subcategory,
       s.store_name, s.country, s.region, s.city,
       c.customer_name, c.customer_gender, c.age_band
FROM fact_sales f
JOIN dim_date d USING (date_key) JOIN dim_product p USING (product_id)
JOIN dim_store s USING (store_id) JOIN dim_customer c USING (customer_id);