-- validation_checks.sql
SET search_path TO retail;

-- 1. Check Row Preservation (Raw deduped vs Clean fact)
SELECT 
    (SELECT COUNT(*) FROM stg_dedup) AS deduped_count,
    (SELECT COUNT(*) FROM sales_clean) AS clean_count,
    (SELECT COUNT(*) FROM stg_dedup) - (SELECT COUNT(*) FROM sales_clean) AS dropped_rows;

-- 2. Check for unexpected NULLs across dimensional and key fields
SELECT 
    COUNT(*) FILTER (WHERE transaction_id IS NULL) AS null_tx_id,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS null_cust_id,
    COUNT(*) FILTER (WHERE product_id IS NULL) AS null_prod_id,
    COUNT(*) FILTER (WHERE store_id IS NULL) AS null_store_id,
    COUNT(*) FILTER (WHERE order_date IS NULL) AS null_dates,
    COUNT(*) FILTER (WHERE delivery_days IS NULL) AS null_delivery_days,
    COUNT(*) FILTER (WHERE sales_amount IS NULL OR profit IS NULL) AS null_financials
FROM sales_clean;

-- 3. Confirm Financial Bounds & Logic
SELECT 
    COUNT(*) FILTER (WHERE quantity <= 0) AS invalid_quantity_remaining,
    COUNT(*) FILTER (WHERE discount_percentage NOT IN (0,5,10,15,20,25,30)) AS invalid_discounts_remaining,
    COUNT(*) FILTER (WHERE ABS(sales_amount - (cost_amount + profit)) > 0.05 AND NOT is_unresolved_amount) AS broken_pnl_reconciliations
FROM sales_clean;