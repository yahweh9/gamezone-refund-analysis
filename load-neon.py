import pandas as pd
from sqlalchemy import create_engine
import os
import dotenv

# Load environment variables from .env file
dotenv.load_dotenv()

# 1. Load your finalized CSV file
df = pd.read_csv('gamezone-orders-cleaned.csv',
                 keep_default_na=False, na_values=[''],
                 parse_dates=['PURCHASE_TS', 'SHIP_TS', 'REFUND_TS'])

# 2. Connect to Neon (connection string lives in .env, which is gitignored)
NEON_CONN_STR = os.getenv('NEON_CONN_STR')
if not NEON_CONN_STR:
    raise SystemExit('NEON_CONN_STR not found - check your .env file')
engine = create_engine(NEON_CONN_STR)

# 3. Push to a staging table
print("Pushing data to Neon staging table...")
df.to_sql('staging_orders', engine, if_exists='replace', index=False, chunksize=5000)
print("Success: Data loaded to Neon.")