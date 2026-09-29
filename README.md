# RETAIL STORE SALES ANALYTICS & DATA WAREHOUSE PIPELINE
# Complete Project Documentation & Technical Specification

1. PROJECT OVERVIEW & EXECUTIVE SUMMARY
---------------------------------------------------------------------
This project delivers an end-to-end data engineering and analytics solution
that transforms 18,045 raw omnichannel retail transaction records into an
audited, reconciled Kimball Star Schema warehouse hosted in Dockerized PostgreSQL.

The warehouse is optimized for direct consumption by business intelligence
platforms, including Tableau Desktop, Microsoft Power BI, and open-source
alternatives (Metabase and Apache Superset).

Core Findings:
An evaluation of 4 consecutive years (2022–2025) revealed a structural flaw
in Q4 promotional strategy:
- October operates at healthy margins between 21.8% and 23.1% with minimal
  discounting (2.4%–3.1% average discount).
- November and December promotional campaigns (Black Friday / Cyber Week /
  Holiday Clearance) cause severe margin contraction down to 12.2%–13.8%.
- Over 23.7% to 33.6% of all orders in November and December receive markdowns
  of 20% or higher.
- Despite volume increases lifting top-line gross revenue, monthly net dollar
  profit during November and December falls significantly compared to October:
    * 2022: Net profit fell 44.9% ($49,953 in Oct vs $27,545/mo in Nov-Dec)
    * 2023: Net profit fell 18.8% ($38,303 in Oct vs $31,121/mo in Nov-Dec)
    * 2024: Net profit fell 27.9% ($37,971 in Oct vs $27,384/mo in Nov-Dec)
    * 2025: Net profit fell 36.5% ($48,209 in Oct vs $30,613/mo in Nov-Dec)


2. SIX CORE BUSINESS QUESTIONS ADDRESSED
---------------------------------------------------------------------
1. The Q4 Margin Dilemma:
   Do high-volume Black Friday and holiday promotions in November and December
   generate incremental net profit, or do they dilute healthy baseline margins
   established in October?

2. Channel & Geographic Profitability:
   Which physical store regions (e.g., Bavaria, England, Northeast, Ontario)
   and distribution channels (Online vs In-Store) yield the highest net profit
   and return on sales after factoring in local logistics and markdowns?

3. Customer Value & Lifecycle Segmentation:
   How does the customer base segment across Recency, Frequency, and Monetary
   (RFM) behavioral tiers, and what proportion of customers convert into loyal,
   high-margin repeat buyers versus one-time deal seekers?

4. Logistics Performance & Operational Friction:
   How do delivery lead times across fulfillment methods (Standard, Express,
   Next Day, In-Store Pickup) impact customer ratings, cancellation rates,
   and product return volumes?

5. Financial Integrity & Margin Audit:
   How much revenue leakage and accounting discrepancy existed in raw point-of-
   sale feeds due to erroneous formulas, negative quantities, unmapped discount
   tiers, and margin mismatches?

6. Inventory Turnover vs. Promotional Velocity:
   Does elevated discounting effectively clear surplus inventory, or are high
   markdown tiers being applied unnecessarily to low-stock, high-demand SKUs?


3. DATASET SPECIFICATIONS
---------------------------------------------------------------------
- Source File: Sales_transactions_2022_2025.csv (18,045 raw records)
- Reference Artifact: sales_data_dictionary.csv (36 schema fields)
- Benchmark Scope: Multinational omnichannel retail dataset capturing sales
  across 12 brick-and-mortar stores across US, UK, Germany, France, Canada,
  Australia, and digital e-commerce channels.
- Grain: One record per line-item transaction (Transaction_ID).


4. DATA QUALITY AUDIT & RECONCILIATION LOG
---------------------------------------------------------------------
Executing 01_clean.sql generated the following logged reconciliation actions:

Step            | Rule Description                                                | Rows Affected
----------------+-----------------------------------------------------------------+--------------
1. Dedup        | Exact duplicate Transaction_ID removed                          | 45
2. Reference    | Product_Name filled from Product_ID lookup                      | 144
2. Reference    | Customer_Name unrecoverable, set to Unknown Customer            | 6
2. Reference    | Customer_Gender unrecoverable, set to Unknown                   | 6
2. Reference    | Conflicting recorded ages resolved by range/frequency/recency   | 4
3. Geography    | Region normalized via Store_ID canonical lookup                 | 26
3. Text         | Payment_Method casing and spacing normalized                    | 190
4. Financial    | Quantity <= 0 recovered from Sales/Cost/Profit                  | 8
4. Financial    | Discount% outside valid tiers recovered                         | 3
4. Financial    | Sales_Amount recomputed from Qty x Price x (1-Disc%)            | 65
4. Financial    | Profit recomputed as Sales_Amount - Cost_Amount                 | 45
4. Financial    | Unresolved amount anomalies flagged for review                  | 3
5. Delivery     | Delivery_Days imputed (0 for Pickup, median for other methods)  | 162
6. Business rule| Cancelled orders retained but excluded from net revenue         | 893
6. Business rule| Return_Flag / Order_Status disagreement flagged for review      | 276

Validation Results:
- Deduped source rows: 18,000 | Cleaned fact rows: 18,000 (0 dropped rows)
- Missing core fields (customer_name, region, product_category, etc.): 0
- Net financial impact on corrected rows: +$912.00 across 65 recomputed records.


5. DATA WAREHOUSE ARCHITECTURE (STAR SCHEMA)
---------------------------------------------------------------------
The warehouse separates conformed dimensional attributes from transactional
numeric measures across 4 dimension tables and 1 fact table:

1. retail.dim_date
   - Primary Key: date_key (integer, YYYYMMDD)
   - Attributes: full_date, year, quarter, month, month_name, year_month,
     month_start, iso_week, day_of_month, weekday_num, weekday_name, is_weekend

2. retail.dim_store[ : 5]
   - Primary Key: store_id (e.g., NYC-01, LON-01, PAR-01)[ : 5, 6]
   - Attributes: store_name, city, region, country[ : 5]

3. retail.dim_product[ : 5]
   - Primary Key: product_id[cite: 5]
   - Attributes: product_name, product_category, product_subcategory[cite: 5]

4. retail.dim_customer[cite: 5]
   - Primary Key: customer_id[cite: 5]
   - Attributes: customer_name, customer_gender, customer_age, age_band,
     latest_segment[cite: 5]

5. retail.fact_sales[cite: 5]
   - Primary Key: transaction_id[cite: 5]
   - Foreign Keys: date_key, store_id, product_id, customer_id[cite: 5]
   - Degenerate Dimensions: order_id, sales_channel, payment_method, order_status,
     shipping_method, return_flag, return_reason, promotion_code, sales_rep[cite: 5]
   - Audit / Filter Flags: is_net_revenue, is_cancelled, is_returned,
     status_return_mismatch, is_unresolved_amount[cite: 5]
   - Measures: quantity, unit_price, discount_percentage, sales_amount,
     cost_amount, profit, delivery_days, customer_rating, inventory_level[cite: 5]


6. ANALYTICAL REPORTING VIEWS (BI CONSUMPTION LAYER)
---------------------------------------------------------------------
Defined in 03_analysis_views.sql for instant querying[cite: 4]:
- v_monthly_kpis: Net Revenue, Net Profit, Profit Margin %, AOV, MoM %, YoY %[cite: 4]
- v_category_performance: Category/subcategory profit share and rankings[cite: 4]
- v_product_performance: Top and bottom performing SKUs by margin and volume[cite: 4]
- v_store_region_performance: Store-level metrics feeding geospatial maps[cite: 4]
- v_discount_impact: Markdown elasticity and loss-making transaction ratios[cite: 4]
- v_customer_rfm: Recency, frequency, monetary scores (Champions, Loyal, At Risk)[cite: 4]
- v_return_cancel_rates: Friction analysis isolating return and cancellation rates[cite: 4]
- v_payment_mix: Share of transactions and revenue by payment processor[cite: 4]
- v_delivery_performance: Delivery duration correlation with customer satisfaction[cite: 4]


7. STRATEGIC RECOMMENDATIONS FOR LEADERSHIP
---------------------------------------------------------------------
1. Restrict Blanket Promotional Markdowns:
   Cap site-wide holiday sales at 10%–15%. Restrict 20%+ discount tiers to slow-
   moving inventory rather than core revenue drivers.

2. Shift to Minimum Basket Size Thresholds (AOV Expansion):
   Replace straight product price slashing with basket incentives (e.g., "$25
   off orders over $200") to protect unit margins while increasing volume.

3. Differentiate Promotions via RFM Customer Tiers:
   Offer VIP bundling, early product access, or loyalty rewards to "Champions"
   and "Loyal" segments rather than cash discounts[cite: 4]. Direct deeper markdowns
   strictly to "At Risk" or "Lost" segments to reactivate inactive accounts[cite: 4].

4. Implement Pre-Campaign Margin Guardrails:
   Establish automated validation at the checkout/POS level to flag or reject
   promotional code combinations that drive transaction margins below 16%.


8. LOCAL DEPLOYMENT & QUICKSTART GUIDE
---------------------------------------------------------------------
Prerequisites:
- Docker Engine 24+ and Docker Compose v2+
- Git

Execution Steps:
1. Clone the repository:
   git clone https://github.com/<your-username>/Retail_Store_Sales.git
   cd Retail_Store_Sales

2. Configure environment credentials (.env):
   PG_USER=datasci
   PG_PASSWORD=analytics_password
   PG_DB=retail_analytics

3. Launch PostgreSQL Container[cite: 1]:
   docker compose up -d

4. Run Database Pipeline[cite: 1, 5, 6]:
   docker exec -it resume_pg psql -U datasci -d retail_analytics -f /sql/01_clean.sql
   docker exec -it resume_pg psql -U datasci -d retail_analytics -f /sql/02_star_schema.sql
   docker exec -it resume_pg psql -U datasci -d retail_analytics -f /sql/03_analysis_views.sql

5. Connect BI Tools (Tableau / Power BI / Metabase):
   Host: localhost
   Port: 5432
   Database: retail_analytics
   Username: datasci
   Schema: retail
   Select views prefixed with v_* for immediate reporting[cite: 4].
