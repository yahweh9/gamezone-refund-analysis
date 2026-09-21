import pandas as pd

print("1. Loading raw data...")
orders = pd.read_excel('gamezone-orders-data.xlsx', sheet_name='orders',
                       keep_default_na=False, na_values=[''])
region = pd.read_excel('gamezone-orders-data.xlsx', sheet_name='region', keep_default_na=False)


print("2. Normalizing geographic dimensions & marketing channels...")
orders.loc[orders['COUNTRY_CODE'] == 'EU', 'COUNTRY_CODE'] = 'Rescue_EMEA'
orders.loc[orders['COUNTRY_CODE'] == 'AP', 'COUNTRY_CODE'] = 'Rescue_APAC'

region.loc[region['REGION'] == 'NA', 'REGION'] = 'North America'
region.loc[region['COUNTRY_CODE'] == 'IE', 'REGION'] = 'EMEA'
region.loc[region['COUNTRY_CODE'] == 'LB', 'REGION'] = 'EMEA'
region.loc[region['REGION'] == 'X.x', 'REGION'] = 'APAC'

lookup_additions = pd.DataFrame([
    {'COUNTRY_CODE': 'Unknown', 'REGION': 'Unknown'},
    {'COUNTRY_CODE': 'Rescue_EMEA', 'REGION': 'EMEA'},
    {'COUNTRY_CODE': 'Rescue_APAC', 'REGION': 'APAC'}
])
region = pd.concat([region, lookup_additions], ignore_index=True)

valid_countries = region['COUNTRY_CODE'].tolist()
orders.loc[~orders['COUNTRY_CODE'].isin(valid_countries), 'COUNTRY_CODE'] = 'Unknown'


print("3. Executing dimension join and deduplication...")
orders_with_region = pd.merge(orders, region, on='COUNTRY_CODE', how='left')
df_cleaned = orders_with_region.drop_duplicates().copy()
df_cleaned = df_cleaned.drop(columns=['Unnamed: 12', 'Unnamed: 13'], errors='ignore')

# Document direct as unattributed
df_cleaned['MARKETING_CHANNEL'] = df_cleaned['MARKETING_CHANNEL'].replace({'direct': 'unattributed_direct'})


print("4. Normalizing product entities and IDs...")
PRODUCT_NAME_CANON = {
    '27inches 4k gaming monitor': '27in 4K gaming monitor',
}
df_cleaned['PRODUCT_NAME'] = df_cleaned['PRODUCT_NAME'].replace(PRODUCT_NAME_CANON)

df_cleaned['PRODUCT_ID'] = df_cleaned['PRODUCT_ID'].astype(str)
id_mapping = df_cleaned.groupby('PRODUCT_NAME')['PRODUCT_ID'].apply(lambda x: x.mode()[0]) 
df_cleaned['PRODUCT_ID'] = df_cleaned['PRODUCT_NAME'].map(id_mapping)


print("5. Imputing missing/invalid pricing and deriving list prices...")
mouse_price = df_cleaned[df_cleaned['PRODUCT_NAME'] == 'Dell Gaming Mouse']['USD_PRICE'].mode()[0]
headset_price = df_cleaned[df_cleaned['PRODUCT_NAME'] == 'JBL Quantum 100 Gaming Headset']['USD_PRICE'].mode()[0]
monitor_price = df_cleaned[df_cleaned['PRODUCT_NAME'] == '27in 4K gaming monitor']['USD_PRICE'].mode()[0]

df_cleaned.loc[(df_cleaned['PRODUCT_NAME'] == 'Dell Gaming Mouse') & ((df_cleaned['USD_PRICE'].isnull()) | (df_cleaned['USD_PRICE'] == 0)), 'USD_PRICE'] = mouse_price
df_cleaned.loc[(df_cleaned['PRODUCT_NAME'] == 'JBL Quantum 100 Gaming Headset') & ((df_cleaned['USD_PRICE'].isnull()) | (df_cleaned['USD_PRICE'] == 0)), 'USD_PRICE'] = headset_price
df_cleaned.loc[(df_cleaned['PRODUCT_NAME'] == '27in 4K gaming monitor') & ((df_cleaned['USD_PRICE'].isnull()) | (df_cleaned['USD_PRICE'] == 0)), 'USD_PRICE'] = monitor_price

# Derive list_price (mode) and discount_pct
list_prices = df_cleaned.groupby('PRODUCT_NAME')['USD_PRICE'].apply(lambda x: x.mode()[0])
df_cleaned['LIST_PRICE'] = df_cleaned['PRODUCT_NAME'].map(list_prices)
# Not clipped: a negative DISCOUNT_PCT means the order paid ABOVE list (likely FX on
# non-USD orders). Clipping would merge those 2,040 rows into the at-list population.
df_cleaned['DISCOUNT_PCT'] = ((df_cleaned['LIST_PRICE'] - df_cleaned['USD_PRICE']) / df_cleaned['LIST_PRICE']).round(4)
df_cleaned['PRICE_ABOVE_LIST'] = df_cleaned['USD_PRICE'] > df_cleaned['LIST_PRICE']


print("6. Resolving chronological anomalies and flagging refunds...")
df_cleaned['PURCHASE_TS'] = df_cleaned['PURCHASE_TS'].astype(str).str.replace('13:62:', '13:59:')
df_cleaned['PURCHASE_TS'] = pd.to_datetime(df_cleaned['PURCHASE_TS'], errors='coerce', format='mixed')
df_cleaned['SHIP_TS'] = pd.to_datetime(df_cleaned['SHIP_TS'])

# Quarantine REFUND_TS
# REFUND_TS timestamps are corrupt for EVERY row (median lag 760d, max 2026-03-14),
# so the flag lives in the schema docs + v_data_quality, not in a per-row column.
# The boolean below is trustworthy; the timestamp is not. Never key a chart on REFUND_TS.
df_cleaned['IS_REFUNDED'] = df_cleaned['REFUND_TS'].notna()

# Explicitly flag and swap dates for the time-traveling packages
df_cleaned['DATES_WERE_SWAPPED'] = df_cleaned['SHIP_TS'] < df_cleaned['PURCHASE_TS']
temp_purchase = df_cleaned.loc[df_cleaned['DATES_WERE_SWAPPED'], 'SHIP_TS']
df_cleaned.loc[df_cleaned['DATES_WERE_SWAPPED'], 'SHIP_TS'] = df_cleaned.loc[df_cleaned['DATES_WERE_SWAPPED'], 'PURCHASE_TS']
df_cleaned.loc[df_cleaned['DATES_WERE_SWAPPED'], 'PURCHASE_TS'] = temp_purchase

# MUST run after the swap above, which rewrites PURCHASE_TS on ~2,000 rows.
# Computing it earlier mislabels 46 pre-2019 orders as in-window.
start_date = pd.to_datetime('2019-01-01')
end_date = pd.to_datetime('2021-02-28 23:59:59')
df_cleaned['IN_VALID_WINDOW'] = df_cleaned['PURCHASE_TS'].between(start_date, end_date)


print("7. Enforcing grain and removing unparseable data...")
df_cleaned = df_cleaned.dropna(subset=['PURCHASE_TS']).copy()

df_cleaned['ORDER_LINE_ID'] = range(1, len(df_cleaned) + 1)
df_cleaned['IS_DUPLICATE_ORDER_ID'] = df_cleaned.duplicated(subset=['ORDER_ID'], keep=False)


print("\nPipeline Execution Complete. Final Schema Info:")
print(df_cleaned.info())

print("8. Validating derived fields...")
assert df_cleaned['LIST_PRICE'].gt(0).all(), 'LIST_PRICE must be positive'
assert df_cleaned.loc[df_cleaned['USD_PRICE'] == df_cleaned['LIST_PRICE'], 'DISCOUNT_PCT'].eq(0).all(), 'at-list orders must have zero discount'
assert df_cleaned.loc[df_cleaned['PRICE_ABOVE_LIST'], 'DISCOUNT_PCT'].lt(0).all(), 'above-list orders must have negative discount'
assert not df_cleaned.loc[df_cleaned['IN_VALID_WINDOW'], 'PURCHASE_TS'].lt(start_date).any(), 'window flag leaked a pre-2019 row'
assert not df_cleaned.loc[df_cleaned['IN_VALID_WINDOW'], 'PURCHASE_TS'].gt(end_date).any(), 'window flag leaked a post-window row'
assert (df_cleaned['SHIP_TS'] - df_cleaned['PURCHASE_TS']).dropna().ge(pd.Timedelta(0)).all(), 'ship before purchase survived the swap'
assert df_cleaned['ORDER_LINE_ID'].is_unique, 'ORDER_LINE_ID must be unique'
print(f"   all checks passed | {len(df_cleaned):,} rows | {df_cleaned['IN_VALID_WINDOW'].sum():,} in valid window")

output_filename = 'gamezone-orders-cleaned.csv'
df_cleaned.to_csv(output_filename, index=False, date_format='%Y-%m-%d %H:%M:%S')
print(f"\nSuccess: Cleaned fact table generated at '{output_filename}'")