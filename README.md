# GameZone refund analysis

GameZone's refund rate is 16%. That average hides a business where hardware refunds tripled in a single month and never came back down.

This is an end to end analysis of 21,828 order lines covering January 2019 to February 2021: a pandas cleaning pipeline, a star schema in Neon Postgres, six analytical views, and a Power BI dashboard.

**Stack:** Python (pandas) · PostgreSQL (Neon) · Power BI · Git

![Dashboard page 1](docs/dashboard-page1.png)

## The finding

In August 2020, the refund rate on GameZone's hardware jumped from 15.9% to 36.2% in a single month and stayed there. Accessories were unaffected, holding between 2% and 3% throughout.

| Product | 2019 | 2020 | 2021 |
|---|---|---|---|
| Nintendo Switch | 6.2% | 23.4% | 39.7% |
| 27in 4K monitor | 8.1% | 24.9% | 36.8% |
| Sony PlayStation 5 Bundle | 17.9% | 18.6% | 13.5% |
| JBL headset | 3.3% | 3.0% | 2.5% |

The change is a step rather than a slope. Refunds sat between 5.4% and 7.5% across all of 2019, drifted up to 13.5% by July 2020, then jumped to 29.9% in August and held between 26% and 29% for the next seven months. A discrete break that persists for seven months is usually a policy change, a supplier change, or a systems change, rather than a gradual shift in customer behaviour.

Two products carry almost all of it. The PlayStation 5 bundle stayed flat over the same period and accessories never moved, so an investigation would start with the Switch and the monitor rather than with hardware as a category.

The cost was $1,189,741 against $6,132,755 in sales.

## What I ruled out

Four explanations that seemed plausible and did not survive the data.

**Product mix.** The Nintendo Switch held 48.4%, 47.2% and 47.3% of orders across the three years while its refund rate went from 6% to 40%. The mix barely moved.

**Discounting.** Deeper discounts correlate with *fewer* refunds. Measured within hardware alone, so this is not a mix effect either:

| Price paid | Orders | Refund rate |
|---|---|---|
| Above list | 1,296 | 25.1% |
| At list | 7,123 | 21.5% |
| 1 to 10% off | 3,103 | 21.9% |
| 11 to 20% off | 3,158 | 15.0% |
| Over 20% off | 2,099 | 13.9% |

The customers returning things are the ones who paid full price or more.

**Shipping delays.** Refund rate by shipping lag is flat: 16.1% within 2 days, 16.2% at 3 to 5 days, 17.1% at 6 to 10 days, 12.3% at 11 to 30 days.

**Customer churn.** Repeat purchase rate stayed flat at around 2% across 23 monthly cohorts. Whatever broke in August 2020 cost GameZone a lot of returned product, but it did not drive existing customers away.

![Dashboard page 2](docs/dashboard-page2.png)

I could not determine the cause from this data. There is no returns reason field, so a broken unit, a wrong description and a change of mind all look identical. Three fields would settle it: returns reason codes, a supplier or warehouse identifier, and a product revision or batch number.

## Problems found in the data

Several of these changed the answer.

**Refund timestamps are corrupt in every row.** The median gap between purchase and refund is 760 days, the latest refund is dated 2026-03-14 against a final order of 2021-02-28, and no refund at all occurs within 30 days of purchase. The refunded flag is still usable and produces coherent patterns that random corruption would not, so every refund metric here is cohorted on purchase date instead. Nothing keys on the refund timestamp.

**The export stops in February 2021.** March through October 2021 contain no orders at all, and a single order dated 2021-11-14 for $14 sits alone after the gap. Read as annual totals this looks like an 86% revenue collapse. It is a truncated export. Analysis is restricted to January 2019 through February 2021, and the 46 partial-2018 rows are excluded and counted.

**Namibia disappears on a default CSV read.** Namibia's country code is `NA`, which `pandas.read_csv` converts to null unless told otherwise. That null merges into the Unknown bucket while keeping its EMEA region, producing two rows keyed `Unknown` and breaking the primary key on `dim_geo`. Both Python scripts pass `keep_default_na=False`, and `build_star.sql` fails the build if the `NA` row goes missing.

**79.7% of orders have no marketing attribution.** They are recorded as `direct`, relabelled `unattributed_direct` so nobody reads it as a real acquisition channel. Any claim about channel performance covers the remaining 20%.

**2,000 rows arrived with purchase and ship dates reversed.** Swapped back and flagged in `dates_were_swapped`, so the correction is visible rather than silent.

**2,040 orders were charged above list price**, probably currency conversion on non-USD orders. Flagged separately in `price_above_list` rather than collapsed into the at-list group, which matters because they turn out to be the worst tier for refunds.

## Two corrections to the analysis itself

Both produced believable charts before they were fixed.

**The repeat rate was counting order splitting as loyalty.** It looked like 9.4%. But 68.5% of customers with more than one order placed every extra order on the same day as their first, which is one shopping session split across order IDs. The metric also compared cohorts with unequal time to return, so a customer acquired in February 2021 had 27 days against a January 2019 customer's 730. Together these produced a chart showing loyalty spiking to 31% in January 2021 and collapsing to 0.2% the following month. Neither movement was real. The view now counts a purchase on a later date within a fixed 90 days and drops cohorts without a full 90 days of runway. The corrected rate is 2.06% and flat.

**The discount effect was measured across all products at once.** Accessories refund at around 4% and hardware at around 21%, so any difference in how the two are discounted would surface as a fake discount effect. Banded within category, the effect survives, which is why the table above is worth trusting.

## How it's built

```
gamezone-orders-data.xlsx
        │
        ▼  data-cleaning.py         clean, derive, flag, 7 assertions
gamezone-orders-cleaned.csv
        │
        ▼  load-neon.py             staging_orders, real TIMESTAMP columns
        │
        ▼  build_star.sql           3 tables, PK/FK, 4 validation checks
        │
        ▼  build_views.sql          6 analytical views
        │
        ▼  game-zone-analysis.pbix  Power BI, Import mode
```

**Why a star schema and not one wide table.** Power BI's engine is built for star schemas, and keeping `dim_product` separate is what lets a single `category` change propagate to every visual. Three tables for 21,828 rows is the smallest shape that still gives the dashboard proper cross-filtering.

**Why the analysis lives in SQL views and not in DAX.** Anything computable once per row belongs in SQL, and anything that has to respond to filter context is a DAX measure. The views also act as a reference implementation: each Power BI measure was checked against the view computing the same number, which is how the dashboard was validated rather than eyeballed.

**Validation at both ends.** `data-cleaning.py` carries seven assertions over the derived columns, including one that fails if the date window flag is computed before the rows it depends on are corrected. `build_star.sql` raises an exception on a row count mismatch, a product falling through the category mapping, a date window leak, or Namibia going missing. A bad build stops rather than producing a plausible dashboard.

**Why the `.pbit` is committed alongside the `.pbix`.** A `.pbix` stores its model as a compressed binary, so the DAX is unreadable on GitHub. The template keeps `DataModelSchema` as JSON with every measure definition visible, at 20KB against the report's 1MB.

**Decisions kept visible rather than silent.** Rows are never dropped quietly. Out-of-window orders, reversed dates, duplicate order IDs, above-list prices and corrupt refund timestamps are all flagged in the fact table and surfaced in `v_data_quality`, which is the one view that deliberately does not filter to the valid window, because its job is to count what the other five exclude.

## Running it

Requires Python with pandas, SQLAlchemy and psycopg2, plus a Neon Postgres database.

Put your connection string in `.env`:

```
NEON_CONN_STR=postgresql://user:password@host/dbname
```

Then:

```bash
python data-cleaning.py
python load-neon.py
```

Then run `build_star.sql` and `build_views.sql` against the database, in that order. `build_star.sql` drops its tables with `CASCADE`, so it deletes the views every time it runs and they need rebuilding after it.

## Repository contents

| File | Purpose |
|---|---|
| `data-cleaning.py` | Joins, canonicalises, derives list price and discount, resolves date problems, 7 assertions |
| `load-neon.py` | Pushes the CSV to `staging_orders` with real timestamp columns |
| `build_star.sql` | `dim_product`, `dim_geo`, `fact_order_lines` with keys and validation |
| `build_views.sql` | Six analytical views |
| `game-zone-analysis.pbix` | The dashboard |
| `game-zone-analysis.pbit` | Same model with readable DAX |

The generated CSV is not committed. Run `data-cleaning.py` to produce it.

## Limitations

The cause of the August 2020 change cannot be determined from this data.

The 2019-01 cohort shows a 0.0% repeat rate. This is real: 18 of those customers did return, but the shortest gap was 94 days, just outside the 90-day window.

Revenue figures are order line totals. There is no quantity column. I tested for a hidden one by checking whether above-list prices were integer multiples of the list price, and none were, so each line is treated as one unit.

Refund timing cannot be analysed at all, only refund incidence.
