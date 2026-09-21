# GameZone refund analysis

An analysis of 21,828 order lines from GameZone, an online video game retailer, covering January 2019 to February 2021. The pipeline cleans the source Excel file, loads it into Neon Postgres as a star schema, and builds six views for a Power BI dashboard.

The headline number in this dataset is a 16% refund rate. That average turns out to hide most of what actually happened.

## The finding

In August 2020, the refund rate on GameZone's hardware products jumped from 15.9% to 36.2% in a single month and stayed there. Accessories were unaffected, holding between 2% and 3% throughout.

| Product | 2019 | 2020 | 2021 |
|---|---|---|---|
| Nintendo Switch | 6.2% | 23.4% | 39.7% |
| 27in 4K monitor | 8.1% | 24.9% | 36.8% |
| JBL headset | 3.3% | 3.0% | 2.5% |

Monthly, the change is a step rather than a slope. Refunds sat between 5.4% and 7.5% across all of 2019, drifted up to 13.5% by July 2020, then jumped to 29.9% in August and held between 26% and 29% for the next seven months. A discrete break that persists for seven months is usually a policy change, a supplier change, or a systems change, not a gradual shift in customer behaviour.

The cost was $1,189,741 against $6,132,755 in sales.

## What I ruled out

Four explanations that seemed plausible and did not survive the data.

**Product mix.** The Nintendo Switch held 48.4%, 47.2% and 47.3% of orders across the three years while its refund rate went from 6% to 40%. The mix barely moved.

**Discounting.** Deeper discounts correlate with *fewer* refunds, not more. Within hardware alone, so this is not a mix effect either:

| Price paid | Orders | Refund rate |
|---|---|---|
| Above list | 1,296 | 25.1% |
| At list | 7,123 | 21.5% |
| 1 to 10% off | 3,103 | 21.9% |
| 11 to 20% off | 3,158 | 15.0% |
| Over 20% off | 2,099 | 13.9% |

The customers returning things are the ones who paid full price or more.

**Shipping delays.** Refund rate by shipping lag is flat: 16.1% for orders shipped within 2 days, 16.2% at 3 to 5 days, 17.1% at 6 to 10 days, 12.3% at 11 to 30 days. No relationship.

**Customer churn.** Repeat purchase rate stayed flat at around 2% across 23 monthly cohorts. Whatever broke in August 2020 cost GameZone a lot of returned product, but it did not drive existing customers away.

I could not determine the cause from this data. There is no returns-reason field, no supplier or warehouse identifier, and no product revision number. Those are the first three things I would ask for.

## Data quality problems

Several of these changed the answer, so they are worth listing.

**Refund timestamps are corrupt in every row.** The median gap between purchase and refund is 760 days, the latest refund is dated 2026-03-14 against a final order of 2021-02-28, and no refund at all occurs within 30 days of purchase. The refunded flag is still usable, and produces coherent patterns that random corruption would not, but every refund metric here is cohorted on purchase date. Nothing keys on the refund timestamp.

**The export stops in February 2021.** March through October 2021 contain no orders whatsoever, and a single order dated 2021-11-14 for $14 sits alone after the gap. Read as annual totals this looks like an 86% revenue collapse. It is a truncated export. All analysis is restricted to January 2019 through February 2021, and the 46 partial-2018 rows are excluded and counted.

**Namibia disappears on a default CSV read.** The country code for Namibia is `NA`, which `pandas.read_csv` converts to null unless told otherwise. That null then merges into the Unknown bucket while keeping its EMEA region, producing two rows keyed `Unknown` and breaking the primary key on `dim_geo`. Both the cleaning script and the loader pass `keep_default_na=False`, and `build_star.sql` has an explicit check that fails the build if the `NA` row goes missing.

**79.7% of orders have no marketing attribution.** They are recorded as `direct`, relabelled `unattributed_direct` in the pipeline so nobody reads it as a real acquisition channel. Any claim about channel performance covers the remaining 20%.

**2,000 rows arrived with purchase and ship dates reversed.** They are swapped back and flagged in `dates_were_swapped`, so the correction is visible rather than silent.

**2,040 orders were charged above list price**, probably currency conversion on non-USD orders. They are flagged separately in `price_above_list` rather than being collapsed into the at-list group, which matters because they turn out to be the worst-performing tier for refunds.

## Two corrections to the analysis itself

Both of these produced believable charts before they were fixed.

The repeat purchase rate looked like 9.4%. But 68.5% of customers with more than one order placed every extra order on the same day as their first, which is one shopping session split across order IDs rather than a customer coming back. The metric also compared cohorts with unequal time to return, so a customer acquired in February 2021 had 27 days against a January 2019 customer's 730. Together these produced a chart showing loyalty spiking to 31% in January 2021 and collapsing to 0.2% the following month. Neither movement was real. The view now counts a purchase on a later date within a fixed 90 days, and drops cohorts without a full 90 days of runway. The corrected rate is 2.06% and flat.

The discount effect was measured across all products at once. Accessories refund at around 4% and hardware at around 21%, so any difference in how the two are discounted would show up as a fake discount effect. Banded within category, the effect survives, which is why the table above is worth trusting.

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

`data-cleaning.py` reads the two sheets of `gamezone-orders-data.xlsx`, joins country codes to regions, canonicalises product names and IDs, derives list price and discount percentage, resolves the date problems, and writes `gamezone-orders-cleaned.csv`. Seven assertions check the derived columns before it writes anything, including one that catches the window flag being computed at the wrong point in the script.

`load-neon.py` pushes the CSV to a `staging_orders` table. It parses the three timestamp columns so they land in Postgres as `TIMESTAMP` rather than text.

`build_star.sql` builds `dim_product`, `dim_geo` and `fact_order_lines` with primary and foreign keys, then runs four validation checks that raise an exception rather than letting a bad build through.

`build_views.sql` builds six views: the monthly refund trend by category, refund rate by product and year with each product's share of that year's orders, a monthly revenue summary, discount effectiveness banded within category, the 90-day cohort repeat rate, and a data quality summary.

The generated CSV is not committed. Run `data-cleaning.py` to produce it.

## Limitations

The cause of the August 2020 change cannot be determined from this data.

The 2019-01 cohort shows a 0.0% repeat rate. This is real: 18 of those customers did return, but the shortest gap was 94 days, just outside the 90-day window.

Revenue figures are order line totals. There is no quantity column, and I tested for a hidden one by checking whether above-list prices were integer multiples of the list price. None were, so each line is treated as one unit.

Refund timing cannot be analysed at all, only refund incidence.

The Power BI dashboard is not built yet.
