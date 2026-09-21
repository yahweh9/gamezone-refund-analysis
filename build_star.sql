-- =============================================================================
-- build_star.sql - builds the star schema from staging_orders
--
-- Run AFTER load-neon.py. Re-runnable: drops and rebuilds everything.
-- Views live in build_views.sql and must be re-run after this file, because
-- the CASCADE below deletes them.
-- =============================================================================

-- 0. Clear existing tables (fact first: child before parent)
DROP TABLE IF EXISTS fact_order_lines CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_geo CASCADE;


-- 1. Product dimension
--    category is the axis the refund trend splits on (hardware tripled,
--    accessories stayed flat), so every product is listed explicitly.
--    A new or renamed product yields NULL and trips the check at the bottom,
--    rather than silently defaulting into the healthy-looking bucket.
CREATE TABLE dim_product AS
SELECT DISTINCT
    "PRODUCT_ID"   AS product_id,
    "PRODUCT_NAME" AS product_name,
    "LIST_PRICE"   AS list_price_usd,
    CASE "PRODUCT_NAME"
        WHEN '27in 4K gaming monitor'         THEN 'hardware'
        WHEN 'Nintendo Switch'                THEN 'hardware'
        WHEN 'Sony PlayStation 5 Bundle'      THEN 'hardware'
        WHEN 'Lenovo IdeaPad Gaming 3'        THEN 'hardware'
        WHEN 'Acer Nitro V Gaming Laptop'     THEN 'hardware'
        WHEN 'JBL Quantum 100 Gaming Headset' THEN 'accessory'
        WHEN 'Razer Pro Gaming Headset'       THEN 'accessory'
        WHEN 'Dell Gaming Mouse'              THEN 'accessory'
        ELSE NULL
    END AS category
FROM staging_orders;

ALTER TABLE dim_product ADD PRIMARY KEY (product_id);


-- 2. Geography dimension
--    No COALESCE: the loader reads the CSV with keep_default_na=False, so
--    country code 'NA' (Namibia) survives and there are no NULLs. A NULL here
--    means the loader regressed - let it fail loudly instead of relabelling it
--    'Unknown' and losing the country a second time.
--    is_unknown dropped: it only restated country_code = 'Unknown'.
CREATE TABLE dim_geo AS
SELECT DISTINCT
    "COUNTRY_CODE" AS country_code,
    "REGION"       AS region
FROM staging_orders;

ALTER TABLE dim_geo ADD PRIMARY KEY (country_code);


-- 3. Core fact table
CREATE TABLE fact_order_lines AS
SELECT
    "ORDER_LINE_ID"           AS order_line_id,
    "ORDER_ID"                AS order_id,
    "USER_ID"                 AS user_id,
    "PRODUCT_ID"              AS product_id,
    "COUNTRY_CODE"            AS country_code,

    "PURCHASE_TS"             AS purchase_ts,
    "SHIP_TS"                 AS ship_ts,
    -- date - date returns a plain integer of days. EXTRACT(DAY FROM interval)
    -- would return only the days component and drop any months.
    ("SHIP_TS"::date - "PURCHASE_TS"::date) AS ship_lag_days,

    -- WARNING: refund_ts is CORRUPT for every row (median lag 760 days, max
    -- 2026-03-14 against a last order of 2021-02-28). Kept only as evidence
    -- for v_data_quality. Never key a chart on it - cohort on purchase_ts.
    "REFUND_TS"               AS refund_ts,
    "IS_REFUNDED"             AS is_refunded,

    "USD_PRICE"               AS usd_price,
    "DISCOUNT_PCT"            AS discount_pct,    -- negative = paid above list
    "PRICE_ABOVE_LIST"        AS price_above_list,

    "PURCHASE_PLATFORM"       AS purchase_platform,
    "MARKETING_CHANNEL"       AS marketing_channel,
    "ACCOUNT_CREATION_METHOD" AS account_creation_method,

    -- data-quality flags
    "IN_VALID_WINDOW"         AS in_valid_window,      -- 2019-01-01..2021-02-28
    "DATES_WERE_SWAPPED"      AS dates_were_swapped,   -- ~2,000 rows rewritten
    "IS_DUPLICATE_ORDER_ID"   AS is_duplicate_order_id
FROM staging_orders;

ALTER TABLE fact_order_lines ADD PRIMARY KEY (order_line_id);

-- Columns the analysis cannot tolerate as NULL
ALTER TABLE fact_order_lines
    ALTER COLUMN country_code     SET NOT NULL,
    ALTER COLUMN product_id       SET NOT NULL,
    ALTER COLUMN purchase_ts      SET NOT NULL,
    ALTER COLUMN usd_price        SET NOT NULL,
    ALTER COLUMN is_refunded      SET NOT NULL,
    ALTER COLUMN in_valid_window  SET NOT NULL;


-- 4. Foreign keys
ALTER TABLE fact_order_lines
    ADD CONSTRAINT product_fk FOREIGN KEY (product_id)   REFERENCES dim_product (product_id),
    ADD CONSTRAINT country_fk FOREIGN KEY (country_code) REFERENCES dim_geo (country_code);


-- 5. Validation - mirrors the asserts in data-cleaning.py. Fails loudly.
DO $$
DECLARE
    v_fact bigint;
    v_stg  bigint;
    v_bad  bigint;
BEGIN
    SELECT COUNT(*) INTO v_fact FROM fact_order_lines;
    SELECT COUNT(*) INTO v_stg  FROM staging_orders;
    IF v_fact <> v_stg THEN
        RAISE EXCEPTION 'row count mismatch: fact % vs staging %', v_fact, v_stg;
    END IF;

    SELECT COUNT(*) INTO v_bad FROM dim_product WHERE category IS NULL;
    IF v_bad > 0 THEN
        RAISE EXCEPTION '% product(s) fell through the category CASE', v_bad;
    END IF;

    -- regression guard: Namibia was silently destroyed by a default CSV read
    SELECT COUNT(*) INTO v_bad FROM dim_geo WHERE country_code = 'NA';
    IF v_bad <> 1 THEN
        RAISE EXCEPTION 'country code NA (Namibia) missing - loader regressed';
    END IF;

    SELECT COUNT(*) INTO v_bad
      FROM fact_order_lines
     WHERE in_valid_window
       AND (purchase_ts < DATE '2019-01-01' OR purchase_ts >= DATE '2021-03-01');
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'in_valid_window leaked % out-of-window row(s)', v_bad;
    END IF;

    RAISE NOTICE 'star schema built and validated: % fact rows', v_fact;
END $$;


-- 6. Eyeball check
SELECT
    (SELECT COUNT(*) FROM dim_product)                               AS product_count,     -- expect 8
    (SELECT COUNT(*) FROM dim_geo)                                   AS geo_count,         -- expect 152
    (SELECT COUNT(*) FROM fact_order_lines)                          AS fact_count,        -- expect 21828
    (SELECT COUNT(*) FROM fact_order_lines WHERE in_valid_window)    AS in_window_count,   -- expect 21782
    (SELECT COUNT(*) FROM fact_order_lines WHERE price_above_list)   AS above_list_count,  -- expect 2040
    (SELECT COUNT(*) FROM fact_order_lines WHERE dates_were_swapped) AS swapped_count;     -- expect 2000
