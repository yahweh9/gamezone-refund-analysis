-- 0. Clear existing tables
DROP TABLE IF EXISTS fact_order_lines CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_geo CASCADE;


-- 1. Create the Product Dimension
CREATE TABLE dim_product AS
SELECT DISTINCT
    "PRODUCT_ID" AS product_id,
    "PRODUCT_NAME" AS product_name,
    "LIST_PRICE" AS list_price_usd,
    CASE 
        WHEN "PRODUCT_NAME" IN ('27in 4K gaming monitor', 'Nintendo Switch', 'Sony PlayStation 5 Bundle', 'Lenovo IdeaPad Gaming 3', 'Acer Nitro V Gaming Laptop') THEN 'hardware'
        ELSE 'accessory'
    END AS category
FROM staging_orders;

ALTER TABLE dim_product ADD PRIMARY KEY (product_id);


-- 2. Create the Geography Dimension (FIXED WITH COALESCE)
CREATE TABLE dim_geo AS
SELECT DISTINCT
    COALESCE("COUNTRY_CODE", 'Unknown') AS country_code,
    "REGION" AS region,
    CASE
        WHEN COALESCE("COUNTRY_CODE", 'Unknown') = 'Unknown' THEN TRUE
        ELSE FALSE
    END AS is_unknown
FROM staging_orders;

ALTER TABLE dim_geo ADD PRIMARY KEY (country_code);


-- 3. Create the Core Fact Table (FIXED WITH COALESCE)
CREATE TABLE fact_order_lines AS
SELECT
    "ORDER_LINE_ID" AS order_line_id,
    "ORDER_ID" AS order_id,
    "USER_ID" AS user_id,
    "PRODUCT_ID" AS product_id,
    COALESCE("COUNTRY_CODE", 'Unknown') AS country_code,
    "PURCHASE_TS" AS purchase_ts,
    "SHIP_TS" AS ship_ts,
    EXTRACT(DAY FROM ("SHIP_TS"::timestamp - "PURCHASE_TS"::timestamp)) AS ship_lag_days,
    "USD_PRICE" AS usd_price,
    "DISCOUNT_PCT" AS discount_pct,
    "IS_REFUNDED" AS is_refunded,
    "PURCHASE_PLATFORM" AS purchase_platform,
    "MARKETING_CHANNEL" AS marketing_channel,
    "ACCOUNT_CREATION_METHOD" AS account_creation_method
FROM staging_orders;

ALTER TABLE fact_order_lines ADD PRIMARY KEY (order_line_id);


-- 4. Enforce Foreign Key Relationships
ALTER TABLE fact_order_lines
    ADD CONSTRAINT product_fk FOREIGN KEY (product_id) REFERENCES dim_product (product_id),
    ADD CONSTRAINT country_fk FOREIGN KEY (country_code) REFERENCES dim_geo (country_code);