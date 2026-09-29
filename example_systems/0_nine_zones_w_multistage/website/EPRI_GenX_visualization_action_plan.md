# EPRI vs. GenX Results Website — Reporting Findings & Action Plan

_Last updated 2026-09-29._

Covers `website/tools/build_results_data.py` (the script that turns the EPRI
workbook and GenX result folders into `dist/data/results-data.js`) and the
result sets it visualizes. Every finding below was checked by rebuilding the
number independently from raw files (source data, `Results_EPRI.xlsb`, GenX
CSVs), not by reading the code alone. We do **not** have EPRI's model code, so
statements about how EPRI computed a number are inferences from its output
files; those are marked "to confirm with EPRI".

## Summary

| # | Finding | Kind | Effect on website | Status |
|---|---|---|---|---|
| 1 | Storage charge double-counted in weekly profile | Script bug | Profile chart | Fixed |
| 2 | Learning rates not applied to GenX investment costs | GenX input bug | GenX builds and costs | Fixed (sampled run only) |
| 3 | Storage Eff_Up/Eff_Down convention | GenX input alignment | None (same round trip) | Fixed |
| 4 | EPRI emissions weighted a second time | Script bug | EPRI emissions ~4× too high | Fixed; confirm with EPRI |
| 5 | EPRI costs are 5-year discounted totals, not annual | Reporting convention | EPRI costs 1.1–4.4× too high; trend reversed | Fixed; confirm with EPRI |
| 6 | GenX myopic `cFix` omits investment from earlier stages | Reporting convention | GenX costs too low in later years | Fixed |
| 7 | "Fixed O&M" cost category actually contains investment | Labelling | Misleading legend | Fixed |
| 8 | EPRI installed capacity uses a GenX run as its starting fleet | Fragile dependency | Correct today, could break silently | Fixed |
| 9 | Period weights hard-coded, and one stage's weeks used for all years | Script bug | 0.3% low (sampled); k-means weeks mislabelled 2030–2045 | Fixed |
| 10 | k-means GenX run predates fixes 2–3 | Stale data | k-means line not comparable | Needs re-run |
| 11 | Public site, download workbooks not updated | Stale publish | Public site shows old numbers | Automatic on push to `main` |

Items 4–9 were fixed in `build_results_data.py` on 2026-09-29 and checked
against independent rebuilds from the raw files (all checks pass; see "Step 4"
below). A full explanation of the cost differences is in
[COST_RECONCILIATION_GUIDE.md](COST_RECONCILIATION_GUIDE.md).

With these fixes, the two models agree closely in 2025
(total cost within 3.5%, emissions within 2.5%). The remaining differences in
later years look like real modeling differences, not reporting problems (see
"Remaining real differences" below).

## How the website is built

1. `tools/build_results_data.py --case-root .. --output dist/data/results-data.js`
   reads `Results_EPRI.xlsb`, `results_kmeans_myopic/`, `results_sampled_myopic/`,
   and source files under `inputs/` (`Demand.csv`, `Parameter.csv`,
   `Period_map.csv`).
2. `dist/index.html` / `compare.html` + `app.js` draw Chart.js charts from
   that dataset. No build step.
3. `tools/build_download_workbooks.py` builds the `.xlsx` downloads from the
   dataset (added by Nicole, replacing the Codex-only `.mjs` script).
4. `.github/workflows/results-website.yml` (added by Nicole) runs on every
   push to `main` that touches the case inputs, results, or website:
   - rebuilds the dataset and downloads;
   - commits them back to `main` as "Refresh model results website data";
   - publishes `dist/` to GitHub Pages (https://nxshi.github.io/GenX_9n_WECC/).

   Pull after pushing, since the workflow adds a commit.

Where each number comes from, and whether the raw values already include the
period weights:

| Metric | EPRI source | Already weighted? | GenX source | Already weighted? |
|---|---|---|---|---|
| Costs | `System Cost` sheet (million $) | Yes, and 5-year discounted (item 5) | `results_pN/costs.csv` | Yes (annual) |
| Buildout | `Buildout` sheet, lower (by-technology) table, cumulative GW | n/a | Running sum of `NewCap − RetCap` in `capacity.csv` | n/a |
| Installed capacity | Starting fleet + Buildout − Retirement | n/a | `EndCap` in `capacity.csv` | n/a |
| Generation | `Generation` sheet, GW per hour, 13 representative weeks | **No**: multiply by weight | `AnnualSum` row of `power.csv` | Yes |
| Emissions | `Emissions` sheet `vAreaEmission` (Mt) by area | **Yes** (item 4): do not reweight | `AnnualSum` row of `emissions.csv` | Yes |
| Weekly profile | `Generation` + `Storage` sheets; demand from `Demand.csv` | Not needed (single week shown) | `power.csv`, `charge.csv`, `power_balance.csv` | Not needed |

## Fixed already (verified against raw output files)

1. **Storage charge double-counted in the Weekly Generation Profile.**
   `charge.csv`'s trailing `Total` column was summed along with the resource
   columns. Now routed through `tech_group()`. Discharge/charge ratio now
   reads exactly 0.900.
2. **`LearningRates.csv` never applied to GenX investment costs.** Fixed in
   `resource_input_conversion.py`; e.g. `Central_Solar_Invest` now declines
   $123,297 → $62,265/MW-yr by 2045 (the 0.505 multiplier).
3. **Storage efficiency now matches EPRI's convention** (Eff_Up 0.90 /
   Eff_Down 1.00). Same round trip as before.

## Reporting problems found, not yet fixed

### 4. EPRI emissions are weighted a second time

**Conclusion: the raw sum of `vAreaEmission` (~61.7 Mt for 2025) is already
the annual total. Remove the extra weighting for EPRI emissions. Do not scale
GenX.** Strongly supported by the data below; to confirm with EPRI.

The Generation and Emissions sheets cover the same 10,920 hours (13 weeks ×
168 h × 5 years), and every hour matches between them. If both held
unweighted values for those hours, each hour's emissions would equal that
hour's fossil generation × the source CO₂ rate. They don't: emissions are
consistently ~4× larger.

**Source CO₂ rates** (`Generation.csv`: `CO2EmissionRate` × heat rate
`LinearTerm`) are standard physical values:

| Technology | tCO₂/MMBtu | Heat rate (MMBtu/MWh) | tCO₂/MWh |
|---|---:|---:|---:|
| NGCC | 0.053 | 6.9–7.8 | 0.366–0.413 |
| Peaker | 0.053 | 9.3–11.8 | 0.493–0.625 |
| Coal | 0.094 | 11.2 | 1.053 |
| NG-CCS | 0.00265 | 7.8 | 0.021 |

**Check 1: one hour (2025-01-01 00:00, verifiable in Excel).**
- Generation sheet: coal 1.26 GW → ≈ 1,330 t; NGCC 17.58 GW → ≈ 6,430–7,260 t.
  Physically possible total ≈ 7,800–8,600 t.
- Emissions sheet, same hour: 0.003615 + 0.013146 + 0.004393 + 0.010771 Mt =
  31,925 t, about 4× more.

**Check 2: the 13 weeks of 2025.**
- Generation sheet fossil output: coal 2,536 GWh, NGCC 33,417 GWh, peaker
  32 GWh. At source rates this gives 14.9–16.5 Mt.
- Emissions sheet over the same 13 weeks: 61.7 Mt.
- For 61.7 Mt to be only 13 weeks of emissions, those weeks would need ~145 TWh
  of fossil generation. That is more than EPRI's generation from all sources
  in those weeks (138 TWh).

**Check 3: fit across every hour.** Regressing each hour's emissions on that
hour's coal, NGCC and peaker output (all 10,920 hours, R² = 0.9995,
intercept ≈ 0):

| | Implied by Emissions sheet (t/MWh) | ÷ 4.011 | Source range |
|---|---:|---:|---:|
| NGCC | 1.575 | 0.393 | 0.366–0.413 |
| Peaker | 2.015 | 0.502 | 0.493–0.625 |
| Coal | 4.008 | 0.999 | 1.053 |

Every technology is scaled by the same factor, ~4.01, which is exactly the
hourly weight of a sampled week (8,760 ÷ 2,184). An hour-for-hour ×4 across
all fuels is what applying the period weight looks like.

**Alternative ruled out in practice:** EPRI using CO₂ rates ~4× the source.
That would mean natural gas at ~0.21 t/MMBtu, about four times what it
physically emits (0.053), so it is not a realistic explanation.

**Cross-checks.**
- GenX, built from the same fleet data, reports 60.3 Mt for 2025 (full-year
  `AnnualSum`).
- EPRI generation scaled to a full year (~144 TWh fossil) × source rates gives
  60–66 Mt.

**Why ~60 Mt and not WECC's historical ~250 Mt.** The test system is
"California and the neighboring Western Interconnection": six California
areas, the Pacific Northwest (PGE/BPA/PacifiCorp West), Nevada Power and
Arizona (APS/SRP/WAPA-LC). It excludes most of WECC's coal regions and has
only 1.26 GW of coal. Even running every fossil unit at full output for all
8,760 hours would emit only 232 Mt (coal 11.6 + NGCC 139.4 + peakers 80.9).
The website's 247 Mt matched the WECC benchmark by coincidence. Whether ~60 Mt
is realistic for this footprint is a data-scope question for EPRI, not a
reporting issue.

**Question for EPRI (Sean Ericson, sericson@epri.com):**
> In `Results_EPRI.xlsb`, are the `vAreaEmission` values on the Emissions tab
> already multiplied by the representative-period weight (~4.01 = 8760/2184)?
> The Generation tab values appear to be unweighted hourly GW. Summing
> `vAreaEmission` gives ~61.7 Mt for 2025. Is that the annual total?

**Fix:** in `epri_scenario()`, sum `vAreaEmission` directly (no
`* week["weight"]`). The emissions total and the by-area breakdown share this
loop, so both are fixed.

### 5. EPRI costs are 5-year discounted totals, not annual costs

Each EPRI `System Cost` row = annual cost × 4.387 × 1.07^−(year−2025).

- 4.387 is the value today of 5 years of payments at 7% (1 + 1/1.07 + … +
  1/1.07⁴). The 7% rate and 5-year periods are stated in
  `DATA_DOCUMENTATION.md` and `Parameter.csv`.
- 1.07^−(year−2025) discounts each period back to 2025.

How this was found: EPRI's fixed O&M and investment costs were rebuilt from
its own results (existing fleet from `Generation.csv` − per-unit
`Retirement` + per-unit `Buildout`; × `OMFixedCost`; new builds ×
`FixedInvestmentCost` × learning rate × `FixedChargeRate`). The ratio of
reported to rebuilt matches the factor to three decimals, identically for
both cost types:

| Year | Reported ÷ rebuilt | Factor |
|---|---:|---:|
| 2025 | 4.39 | 4.387 |
| 2030 | 3.13 | 3.128 |
| 2035 | 2.23 | 2.230 |
| 2040 | 1.59 | 1.590 |
| 2045 | 1.13 | 1.134 |

The five rows sum to about $217.5B, presumably EPRI's objective (total
discounted system cost). This also confirms EPRI's `GenInvestment` is a
running total: each year it includes the annual payments on everything built
so far.

Consequences: the apparent "EPRI costs 2–4× GenX" gap and the "EPRI costs
fall while GenX costs rise" trend (both open questions in earlier versions of
this plan) are reporting artifacts. Converted to annual dollars, both models'
costs rise.

**Fix:** divide EPRI cost columns by the factor for that year. _To confirm
with EPRI: the factor was reverse-engineered and fits exactly, but EPRI
hasn't documented it._

### 6. GenX myopic `cFix` omits investment on capacity built in earlier stages

`cFix` (`src/model/core/discharge/investment_discharge.jl:115`) is:

```
cFix = Inv_Cost_per_MWyr × capacity built THIS stage + Fixed_OM_Cost_per_MWyr × all capacity
```

In a myopic run, capacity built in one stage becomes existing capacity in the
next stage. From then on it pays only fixed O&M, and its investment payments
disappear from the reported costs. Rebuilt from inputs × `capacity.csv`, this
matches `cFix` exactly in every stage (e.g. 2045: $3,316M investment + $5,283M
fixed O&M = $8,599M = `cFix`).

GenX's reported investment by stage is $373M, $2,071M, $3,556M, $3,536M,
$3,316M. The running total is $12,852M by 2045. That makes GenX's 2045 cost
≈ $31.9B instead of $22.4B, close to EPRI's annual-equivalent $31.4B.

**Fix:** in `genx_scenario()`, carry each stage's new-build investment cost
(`NewCap` × that stage's `Inv_Cost_per_MWyr`) into every later stage, and
report it as its own category. On the site, GenX's total will then differ
from its raw `cTotal`; note this on the page.

### 7. Cost category labels

"Fixed O&M" currently holds EPRI `GenInvestment + GenFixedOM + GenRetirement`
and GenX `cFix` (which includes investment). **Fix:** split into "Investment"
and "Fixed O&M" for both models. GenX's fixed O&M = Σ
`Fixed_OM_Cost_per_MWyr` × `EndCap`. Add a "Retirement" category only if it
is ever non-zero (currently $0 in EPRI).

### 8. EPRI installed capacity uses a GenX run as its starting fleet

EPRI's workbook reports only additions (`Buildout`) and removals
(`Retirement`), not the starting fleet. The script borrows it from
`results_sampled_myopic/results_p1/capacity.csv` `StartCap`. It matches the
source today (e.g. hydro 36.40 GW, NGCC 40.65 GW, solar 35.73 GW, storage
19.89 GW, total 176.6 GW), but EPRI's chart would change silently if that run
changed. **Fix:** sum `MaximumPower` of all non-`_Invest` units in the source
`Generation.csv` by technology.

### 9. Period weights: never hard-code ×4

Every representative-period run has its own weights, and they are not always 4.

| Run | Representative weeks (source week numbers) | Weeks represented by each |
|---|---|---|
| GenX sampled (`TDR_results`) | 1, 5, 9, 13, 17, 21, 25, 29, 33, 37, 41, 45, 49 (same every year) | 4 each |
| GenX k-means (`TDR_results_kmeans`), 2025 | 2, 14, 16, 17, 19, 26, 32, 35, 40, 42, 43, 47, 50 | 1, 2, 4, 1, 2, 7, 10, 1, 3, 2, 1, 12, 6 |
| GenX k-means, 2045 | 6, 11, 12, 15, 16, 19, 34, 35, 40, 42, 46, 48, 52 | 2, 4, 2, 1, 5, 5, 14, 1, 1, 4, 2, 10, 1 |
| EPRI | Timestamps match the sampled weeks (Jan 1, Jan 29, Feb 26, …) | Presumed 4 each; to confirm |

**K-means clusters each model year separately**
(`inputs_pN/TDR_results_kmeans/`), so its weeks and weights change every
year. The old script used the 2025 map for every year. That mislabelled the
2030–2045 profile weeks, and any weighted sum would be off by up to 4% (2040).
Each stage's own map reproduces GenX's `AnnualSum` exactly.

- **The exact hourly weight is `Sub_Weights / 168`** (from that run's
  `Demand_data.csv`), not the whole-week count. GenX stretches 52 weeks
  (8,736 h) to cover 8,760 h. So a sampled week's hourly weight is 4.011, and
  a k-means week representing 12 weeks has 12.033.
- **The script currently uses the integer count** (`representative_weeks()`
  → `weight = number of weeks mapped`). For EPRI generation that is 4, not
  4.011, so annual generation reads ~0.3% low.
- **k-means weights are uneven** (1 to 12 weeks). Any annual total rebuilt
  from k-means hourly rows must weight each week by its own `Sub_Weights`. A
  flat ×4 would be badly wrong: the week representing 12 weeks would be
  undercounted by 3×, and the ones representing 1 week overcounted by 4×.
- **Where this matters:**
  - GenX annual totals: use GenX's own `AnnualSum` rows, which already apply
    the correct weights for either run. Do not reweight them.
  - EPRI generation: weight by EPRI's own period weights (currently the
    sampled weights). Never apply k-means weights to EPRI data.
  - Any new metric rebuilt from hourly rows (storage charge, flows,
    curtailment, NSE) or any verification check: use that run's own
    `Sub_Weights`.
  - Weekly profile chart: shows one week, no weighting. k-means and EPRI
    weeks are different calendar weeks, so the week selector must label the
    source week number (it already does).

**Fix (done):**
- `representative_weeks()` reads `Sub_Weights` from each stage's
  `Demand_data.csv` and stores `hour_weight = Sub_Weights / 168`.
- Each year row in the dataset carries its own `weeks`, and the week selector
  on the site updates when the year changes.
- EPRI's weeks and weights are read from its own Generation timestamps
  (`epri_weeks()`, 8760 / 2184 = 4.011 per hour), not borrowed from a GenX
  run.

## Corrected comparison (EPRI converted to annual; sampled-week GenX)

Annual, undiscounted, million 2025 $:

| Year | EPRI variable | GenX variable + fuel | EPRI fixed O&M | GenX fixed O&M | EPRI investment | GenX investment (running total) | EPRI total | GenX total (adjusted) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2025 | 6,497 | 6,337 | 4,139 | 4,115 | 574 | 373 | 11,210 | 10,828 |
| 2030 | 8,473 | 7,895 | 4,400 | 4,294 | 2,367 | 2,444 | 15,240 | 14,635 |
| 2035 | 7,764 | 9,588 | 4,739 | 4,433 | 7,592 | 6,000 | 20,096 | 20,025 |
| 2040 | 8,142 | 11,227 | 5,261 | 4,854 | 11,871 | 9,536 | 25,273 | 25,623 |
| 2045 | 7,945 | 13,779 | 6,000 | 5,283 | 17,466 | 12,852 | 31,412 | 31,920 |

_GenX running-total investment is the simple sum of stage investment; the
script should recompute it exactly. "GenX total (adjusted)" = `cTotal` − this
stage's investment + running-total investment._

CO₂ emissions (Mt, annual): EPRI 61.7 (2025) → 69.0 (2045); GenX 60.3 → 125.9.

## Remaining real differences (not reporting artifacts)

- **Variable cost and emissions diverge after 2030.** GenX variable + fuel
  cost roughly doubles ($6.3B → $13.8B) and emissions double (60 → 126 Mt),
  while EPRI stays flat (~$8B, 62 → 69 Mt). In 2045 GenX runs 304 TWh of NGCC
  vs EPRI's 171 TWh.
- **Less solar/storage buildout in GenX** (2045: GenX ~101 GW solar / 35 GW
  storage vs EPRI ~159 / 84 GW). Probably the same underlying cause as the
  point above.
- Candidate explanations, not yet separated from each other:
  - Myopic GenX vs EPRI's perfect foresight.
  - Capacity credit for new solar/wind under the reserve margin (new solar
    ≈ 0.05 vs new gas ≈ 0.97).
  - Representative-week choice (k-means vs sampled).
- Totals end up similar (~$31–32B in 2045) with very different fleets, which
  is itself worth investigating.

## Other issues

- **k-means run is stale** (predates fixes 2–3). Re-run it, or drop it from
  the site until it is re-run.
- **Model names are hard-coded** in `main()` of the builder, the download
  links in `index.html` / `compare.html`, and `FILE_NAMES` in
  `build_download_workbooks.py`; the README mentions only the first.
- **Side-by-side weekly profiles (compare page) pair models by week index.**
  The same index can be a different calendar week in each model, since
  K-means picks its own weeks every year. Each panel's subtitle now names its
  calendar week and flags when the two differ.
- **README commands are Mac/Linux-only** (`python3`, `source .venv/bin/activate`).
  On Windows: `python tools/build_results_data.py --case-root .. --output dist/data/results-data.js`.
- **EPRI's representative weeks.** The documentation says EPRI used "the first
  week of each month", but the workbook timestamps start Jan 1, Jan 29,
  Feb 26, … (every 4 weeks, matching GenX's sampled weeks). Each EPRI week also
  starts one hour later than the one before, so hourly profiles may be offset
  by a few hours between models.
- **EPRI generation vs demand in 2045.** EPRI generation scaled to a full year
  is ~1,050 TWh vs 839 TWh demand. Storage cycling and losses explain some of
  the gap; recheck once the weights fix (item 9) lands.

## Next steps

**Step 1: Send questions to EPRI (Sean Ericson) and Nicole.** _Not yet sent._
- Is `vAreaEmission` already weighted (item 4)?
- Is `System Cost` = annual cost × 5-year PV factor × discount to 2025 (item 5)?
- Which representative weeks, and what weights, did EPRI use (item 9)? In
  particular, is each hour weighted by 4 (52 weeks) or 8760/2184 = 4.011
  (full year)? The site uses 4.011 to match GenX; the difference is 0.27%.
- Is the ~60 Mt footprint (California + neighbours, 1.26 GW coal) the
  intended scope?

**Step 2: Fix the builder script.** _Done 2026-09-29_ (`tools/build_results_data.py`).
1. Weights (item 9): `hour_weight = Sub_Weights / 168`, per stage and per run.
   EPRI weeks and weights come from its own timestamps.
2. EPRI emissions (item 4): `vAreaEmission` summed without weighting (total
   and by-area).
3. EPRI costs (item 5): each year divided by `stage_pv_factor()`, which is
   built from `Parameter.csv` (7%, base 2025). The original value is kept as
   `cost_reported`.
4. GenX investment (item 6): stage investment = `cFix` − fixed O&M (fixed O&M
   = input rates × `EndCap` / `EndEnergyCap` / `EndChargeCap`), carried forward
   as a running total. The run's own `cFix` is used, so an older run (k-means)
   isn't mixed with current input costs. Original `cTotal` is kept as
   `cost_reported`.
5. Cost categories (item 7): Investment, Fixed O&M, Variable O&M + fuel,
   Network expansion, Emissions, Reliability / NSE, Other. "Other" is GenX's
   small unlisted residual in `cTotal` ($2–6M/yr); EPRI's is $0.
6. Starting fleet (item 8): `source_starting_fleet()` reads the source
   `Generation.csv` (176.62 GW).

**Step 3: Decide how costs are displayed.** _Done:_ annual, undiscounted $ for
both models. A "discounted to 2025" toggle was not added; it can be added
later from `cost_reported` and the same factors.

**Step 4: Rebuild and verify.** _Done; all checks pass._ Every value below
was recomputed independently from raw files and compared with the site
dataset:
- EPRI fixed O&M and investment, rebuilt bottom-up, match the site in all
  five years. Site cost × factor = EPRI's reported Total exactly.
- Sampled GenX investment (`Inv_Cost_per_MWyr` × `NewCap`, running total)
  matches: $373M → $12,852M.
- K-means investment from its own `cFix` differs from current inputs, as
  expected: that run predates the learning-rate fix.
- Emissions:
  - EPRI = raw `vAreaEmission` sum (61.7 Mt in 2025). Every year falls within
    the range implied by annual fossil generation × source CO₂ rates.
  - GenX = `AnnualSum` for both runs.
- Weights: hourly GenX output × per-stage `hour_weight` reproduces GenX's own
  `AnnualSum` exactly for all 5 stages of both runs. A flat ×4 would be off by
  2–5% for k-means.
- Installed capacity: 2025 starting fleet = 176.62 GW for EPRI and GenX.
- EPRI generation = raw GW × 8760/2184.
- Site loads with no console errors, and charts render.

**Step 5: Update page text.** _Done._
- Cost chart subtitle and axis say "annual (undiscounted)" and "$M/yr".
- Chart notes explain the EPRI conversion and the GenX investment
  adjustment.
- A "Notes" section (7 items) now appears on both pages: cost basis, GenX
  investment, cost categories, representative-week weights, EPRI emissions,
  test-system scope, and the stale k-means caveat.
- The download-workbook script labels costs as annual, and adds an "As
  reported by the model" column.

**Step 6: Re-run the k-means GenX case** with current inputs (after fixes
2–3), or remove it from the site until then.

**Step 7: Commit and publish.** _Merged with Nicole's 14 commits on branch
`reporting-fixes`; ready to push._
- Merge resolution:
  - Our `build_results_data.py` kept. Nicole's version had the same emissions
    fix, a flat ×4 for generation, and GenX costs from `costs_multi_stage.csv`
    (equal to `cTotal` for myopic runs); ours covers all of these.
  - Her `.mjs` → `.py` download builder kept, with our changes ported in:
    per-year weeks, annual-cost labels, "as reported" column.
  - `app.js`: all her new compare charts kept, plus our per-year weeks,
    `$M/yr` labels, and calendar-week subtitles on the side-by-side profiles.
- Data and downloads rebuilt locally; verification passes; both pages checked
  in a browser.
- Pushing to `main` triggers the GitHub Pages workflow, which republishes the
  site and rebuilds the downloads automatically.

**Step 8: Return to the modeling questions.** Why does GenX run more gas and
build less solar/storage? Isolate the causes one at a time:
- Run GenX with perfect foresight (DDP).
- Compare capacity credits for new solar/wind.
- Compare the sampled vs k-means runs.
