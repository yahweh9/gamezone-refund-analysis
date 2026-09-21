CREATE OR REPLACE VIEW v_refund_trend_monthly AS
SELECT
      DATE_TRUNC('month', purchase_ts)::date AS purchase_month,
      COUNT(order_line_id) AS total_orders,

      COUNT(order_line_id) FILTER (WHERE is_refunded = TRUE) as refunded_orders,

      -- Not rounded: 2dp flattens every 2019 month (5.4%-7.5% actual) into
      -- 0.05/0.06/0.07. Keep full precision here, format in the BI layer.
      COUNT(order_line_id) FILTER (WHERE is_refunded = TRUE)::numeric
          / COUNT(order_line_id)::numeric AS refund_rate
FROM fact_order_lines
WHERE in_valid_window = TRUE
GROUP BY DATE_TRUNC('month', purchase_ts)::date;

SELECT * FROM v_refund_trend_monthly ORDER BY purchase_month;

CREATE OR REPLACE VIEW v_refund_by_product_year AS
SELECT
      EXTRACT(YEAR FROM f.purchase_ts) AS purchase_year,
      p.category,
      p.product_name,
      COUNT(f.order_line_id) AS total_orders,

      COUNT(f.order_line_id) FILTER (WHERE f.is_refunded = TRUE)::numeric
          / COUNT(f.order_line_id)::numeric AS refund_rate,

      -- share of the year's orders: this is what proves the product mix stayed
      -- stable, so the refund climb cannot be explained by mix shifting.
      COUNT(f.order_line_id)::numeric
          / SUM(COUNT(f.order_line_id)) OVER (PARTITION BY EXTRACT(YEAR FROM f.purchase_ts))
          AS share_of_year_orders
    
FROM fact_order_lines f
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.in_valid_window = TRUE
GROUP BY
      EXTRACT(YEAR FROM f.purchase_ts),
      p.category,
      p.product_name;
      
SELECT * FROM v_refund_by_product_year ORDER BY purchase_year;

-- 3. Revenue & KPI Summary
-- Grain: One row per month. Fuels the headline scorecard and revenue trend charts.
CREATE OR REPLACE VIEW v_revenue_summary AS
SELECT 
    DATE_TRUNC('month', f.purchase_ts)::date AS purchase_month,
    COUNT(f.order_line_id) AS total_orders,
    SUM(f.usd_price) AS gross_revenue,
    COALESCE(SUM(f.usd_price) FILTER (WHERE f.is_refunded = TRUE), 0) AS refunded_revenue,
    SUM(f.usd_price) - COALESCE(SUM(f.usd_price) FILTER (WHERE f.is_refunded = TRUE), 0) AS net_revenue,
    ROUND(AVG(f.usd_price), 2) AS average_order_value,
    SUM(p.list_price_usd - f.usd_price) AS total_discount_given
FROM fact_order_lines f
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.in_valid_window = TRUE
GROUP BY DATE_TRUNC('month', f.purchase_ts)::date;


-- 4. Discount Effectiveness
-- Grain: One row per category x discount tier.
--
-- Banded WITHIN category on purpose. Accessories refund at ~4% and hardware at
-- ~21%, so a blended tier table can show a discount "effect" that is really
-- just product mix. Controlled this way the effect survives: inside hardware
-- alone, refund rate falls monotonically from 21.5% at list to 13.9% above
-- 20% off. Deeper discounts do NOT drive refunds - they refund less.
--
-- 'Above list price' is split from 'At list price' because those 2,040 orders
-- (likely FX on non-USD purchases) refund at 25.1%, the WORST of any tier.
-- Merging them into one "no discount" bucket hides that entirely.
CREATE OR REPLACE VIEW v_discount_effectiveness AS
SELECT
    p.category,
    CASE
        WHEN f.price_above_list     THEN '0. Above list price'
        WHEN f.discount_pct <= 0    THEN '1. At list price'
        WHEN f.discount_pct <= 0.10 THEN '2. 1% to 10% discount'
        WHEN f.discount_pct <= 0.20 THEN '3. 11% to 20% discount'
        ELSE                             '4. Over 20% discount'
    END AS discount_tier,
    COUNT(f.order_line_id) AS total_orders,
    COUNT(f.order_line_id) FILTER (WHERE f.is_refunded = TRUE)::numeric
        / COUNT(f.order_line_id)::numeric AS refund_rate,
    SUM(f.usd_price) AS net_sales,
    SUM(p.list_price_usd - f.usd_price) AS discount_given
FROM fact_order_lines f
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.in_valid_window = TRUE
GROUP BY 1, 2;


-- 5. Cohort Repeat Rate (90-day window)
-- Grain: One row per user acquisition month.
--
-- Two corrections vs a naive repeat rate, both of which change the answer:
--
--   (a) A repeat is a purchase on a LATER DATE, not merely a second order_id.
--       68.5% of users with >1 order placed every extra order on the SAME DAY
--       as their first - that is one session split across orders, not a
--       returning customer. Counting them inflates the rate from ~2% to 9.4%.
--
--   (b) Repeat is measured within a fixed 90 days of first purchase, and
--       cohorts without a full 90 days before the data ends (2021-02-28) are
--       excluded. Otherwise recent cohorts look worse purely because they had
--       less time: the naive view showed Jan-2021 at 31% and Feb-2021 at 0.2%,
--       and neither movement was loyalty.
--
-- Note: 2019-01 legitimately reads 0.0%. That cohort has 18 returning users but
-- the shortest gap is 94 days, just outside the window. Real, not a bug.
CREATE OR REPLACE VIEW v_cohort_repeat_rate AS
WITH user_first AS (
    SELECT
        user_id,
        MIN(purchase_ts::date) AS first_purchase_date
    FROM fact_order_lines
    WHERE in_valid_window = TRUE
    GROUP BY user_id
),
user_repeat AS (
    SELECT
        u.user_id,
        DATE_TRUNC('month', u.first_purchase_date)::date AS cohort_month,
        COUNT(DISTINCT f.purchase_ts::date) FILTER (
            WHERE f.purchase_ts::date - u.first_purchase_date BETWEEN 1 AND 90
        ) AS repeat_dates_90d
    FROM user_first u
    JOIN fact_order_lines f
      ON f.user_id = u.user_id
     AND f.in_valid_window = TRUE
    GROUP BY u.user_id, u.first_purchase_date
)
SELECT
    cohort_month,
    COUNT(*) AS total_users_acquired,
    COUNT(*) FILTER (WHERE repeat_dates_90d > 0) AS repeat_users_90d,
    COUNT(*) FILTER (WHERE repeat_dates_90d > 0)::numeric
        / COUNT(*)::numeric AS repeat_rate_90d
FROM user_repeat
WHERE cohort_month <= DATE '2020-11-01'
GROUP BY cohort_month;


-- 6. Data Quality Differentiator
-- Grain: A single overarching row summarizing the pipeline's catch metrics.
CREATE OR REPLACE VIEW v_data_quality AS
SELECT 
    COUNT(order_line_id) AS total_rows_processed,
    COUNT(order_line_id) FILTER (WHERE NOT in_valid_window) AS out_of_window_rows_filtered,
    COUNT(order_line_id) FILTER (WHERE dates_were_swapped = TRUE) AS time_traveling_packages_fixed,
    COUNT(order_line_id) FILTER (WHERE is_duplicate_order_id = TRUE) AS duplicate_order_ids_flagged,
    ROUND(
        COUNT(order_line_id) FILTER (WHERE marketing_channel = 'unattributed_direct')::numeric 
        / COUNT(order_line_id)::numeric, 
        4
    ) AS unattributed_traffic_pct
FROM fact_order_lines;