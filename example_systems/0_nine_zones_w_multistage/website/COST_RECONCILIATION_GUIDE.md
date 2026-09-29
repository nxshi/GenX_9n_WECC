# EPRI vs. GenX Cost Reconciliation Guide

_Written 2026-09-29. Reference for anyone comparing system costs between
`Results_EPRI.xlsb` and GenX `costs.csv` outputs._

## The short version

Two unrelated issues made the costs look wildly different. Neither is a
factor of 5, and neither has anything to do with representative-week
weighting.

| # | Model | What the raw number actually is | What we want (annual $ in that year) | Fix |
|---|---|---|---|---|
| A | EPRI | **Five years of costs, discounted to 2025**, reported in one row | One year of costs | Divide every cost column by the stage factor (4.387 in 2025 … 1.134 in 2045) |
| B | GenX (myopic) | One year of costs, but **investment only for capacity built in that stage** | Investment for all capacity built so far | Carry each stage's investment forward as a running total |

With both fixed, 2025 costs agree within 3.5% ($11.2B EPRI vs $10.8B GenX),
and 2045 totals are within 2% ($31.4B vs $31.9B, sampled-week GenX).

## A. EPRI: each row is a discounted five-year stage total

Each model year stands for a five-year period (2025 covers 2025–2029, and so
on). EPRI's objective function is the present value of all costs over the
horizon, so each `System Cost` row is that period's contribution to the
objective:

```
reported(year) = annual cost × [1 + 1/1.07 + 1/1.07² + 1/1.07³ + 1/1.07⁴] × 1/1.07^(year − 2025)
                               └──────── 5 years at 7% = 4.387 ────────┘   └─ discount to 2025 ─┘
```

| Year | 5-year stage (4.387) | × discount to 2025 | = Factor | Reported total | ÷ factor = annual |
|---|---:|---:|---:|---:|---:|
| 2025 | 4.387 | 1.000 | **4.387** | $49,180M | $11,210M |
| 2030 | 4.387 | 0.713 | **3.128** | $47,672M | $15,240M |
| 2035 | 4.387 | 0.508 | **2.230** | $44,819M | $20,096M |
| 2040 | 4.387 | 0.362 | **1.590** | $40,188M | $25,273M |
| 2045 | 4.387 | 0.258 | **1.134** | $35,613M | $31,412M |

### Why it isn't "×5"

Five years of costs would be ×5 if money were not discounted. At 7%, the
later years of each stage are worth less today, so five years sum to 4.387,
not 5. The later stages are also discounted back to 2025, which is why the
factor falls to 1.134 by 2045.

### Why it isn't the ×4 representative-week weight

The 2025 factor (4.39) happens to be close to the week weight (4.01). The two
are unrelated:

- **The week weight is the same in every year** (4.01 for sampled weeks).
  The cost factor falls every stage: 4.39 → 3.13 → 2.23 → 1.59 → 1.13. A
  weighting issue could not do that.
- **The cost factor applies identically to investment and fixed O&M.**
  Neither has anything to do with hours, so the week weight can't touch
  them. Investment is $/MW-yr × MW, and fixed O&M is $/kW-yr × kW.
- **The emissions issue is different.** EPRI's emissions were over-weighted
  by the website script (×4.01 applied twice). The EPRI costs were never
  weighted by the script; they were just used without converting to annual.

### What it looked like before the fix

Reading EPRI's rows as annual costs made EPRI look 4.4× GenX in 2025. It also
made EPRI's costs appear to fall over time ($49B → $36B) while GenX's rose.
Both were artifacts: the falling trend was just heavier discounting in later
years.

### How it was established

We don't have EPRI's model code, so the factor was reverse-engineered:

1. **Rebuild EPRI's fixed O&M from its own results.**
   - Fleet = existing units in `Generation.csv`, minus the per-unit
     `Retirement` sheet, plus the per-unit `Buildout` sheet.
   - Fixed O&M = fleet × `OMFixedCost` ($/kW-yr).
2. **Rebuild EPRI's investment.** New builds each stage ×
   `FixedInvestmentCost` × `LearningRates.csv` multiplier × `FixedChargeRate`
   (0.0806, the 7%/30-yr annuity), summed over everything built so far.
3. **Compare.** Reported ÷ rebuilt equals the factor above to three decimals,
   identically for both cost types.

The 7% rate and 5-year periods are stated in `DATA_DOCUMENTATION.md` and
`Parameter.csv`. The five rows sum to ~$217.5B, which is presumably EPRI's
objective value. **Still to confirm with EPRI.**

## B. GenX myopic: investment is only charged in the stage a plant is built

GenX's `costs.csv` for a myopic run is one year of costs for that stage, with
no discounting (myopic runs use `DF = 1`). The subtlety is in `cFix`
(`src/model/core/discharge/investment_discharge.jl:115`):

```
cFix = Inv_Cost_per_MWyr × MW built in THIS stage  +  Fixed_OM_Cost_per_MWyr × all MW
       └────── annualized investment payment ─────┘    └──────── fixed O&M ────────┘
```

In a myopic run, each stage is solved separately. Capacity built in 2030 is
handed to the 2035 stage as existing capacity. From then on GenX charges it
fixed O&M but no investment, so its annual loan payment disappears from the
reported costs.

EPRI (like a real utility) keeps paying for everything built so far.
`GenInvestment` in 2045 is the annual payment on all capacity built
2025–2045.

**Example, sampled-week GenX:**

| Stage | Investment on this stage's builds | Running total (what EPRI would report) |
|---|---:|---:|
| 2025 | $373M | $373M |
| 2030 | $2,071M | $2,444M |
| 2035 | $3,556M | $6,000M |
| 2040 | $3,536M | $9,535M |
| 2045 | $3,316M | $12,852M |

GenX's raw 2045 `cTotal` ($22.4B) therefore leaves out $9.5B/yr of payments
on 2025–2040 builds. With the running total it's $31.9B.

### How it was established

`Inv_Cost_per_MWyr × NewCap + Fixed_OM_Cost_per_MWyr × EndCap`, from the
stage's input files and `capacity.csv`, reproduces `cFix` exactly in every
stage.

### How the website computes it

- It takes each stage's investment as `cFix − fixed O&M`, using that run's own
  `cFix`. It doesn't recompute investment from the current input files, which
  can differ from what an older run used (the K-means run predates the
  learning-rate fix).
- It sums the stage investments as a running total.
- Adjusted total = `cTotal` − this stage's investment + running total.

## Side-by-side after both fixes (annual $M, 2025 dollars)

| Year | EPRI variable | GenX var + fuel | EPRI fixed O&M | GenX fixed O&M | EPRI invest. | GenX invest. (running) | EPRI total | GenX total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2025 | 6,497 | 6,337 | 4,139 | 4,115 | 574 | 373 | 11,210 | 10,828 |
| 2030 | 8,473 | 7,895 | 4,400 | 4,294 | 2,367 | 2,444 | 15,240 | 14,635 |
| 2035 | 7,764 | 9,588 | 4,739 | 4,433 | 7,592 | 6,000 | 20,096 | 20,023 |
| 2040 | 8,142 | 11,227 | 5,261 | 4,854 | 11,871 | 9,535 | 25,273 | 25,622 |
| 2045 | 7,945 | 13,779 | 6,000 | 5,283 | 17,466 | 12,852 | 31,412 | 31,919 |

_GenX totals include a small residual in `cTotal` ($2–6M/yr) that
`costs.csv` does not break out; the site shows it as "Other"._

**What's left is real:**

- GenX's variable + fuel cost roughly doubles by 2045 while EPRI's stays flat.
  GenX runs about 1.8× as much gas (304 vs 171 TWh NGCC).
- GenX's investment is lower because it builds less solar and storage.

The totals end up close with very different fleets, which is a modeling
question, not a reporting one.

## Checklist for future comparisons

- **EPRI `System Cost`:** divide by the stage factor before comparing any
  single year. Only the column sum (present value) is directly comparable to
  another model's present value.
- **GenX myopic `costs.csv`:** add investment from earlier stages before
  comparing a later year, or compare investment in the build year only.
- **GenX perfect-foresight (DDP, `Myopic: 0`) runs are different.** Costs are
  discounted and multiplied by `OPEXMULT`, and investment is converted to a
  truncated overnight cost (`configure_multi_stage_inputs.jl`,
  `dual_dynamic_programming.jl`). Re-derive the conversion before reusing
  this guide on a DDP run.
- **Category matching:**

  | Category | EPRI | GenX |
  |---|---|---|
  | Investment | `GenInvestment` | part of `cFix` |
  | Fixed O&M | `GenFixedOM` | part of `cFix` |
  | Variable O&M + fuel | `GenVariable` | `cVar` + `cFuel` + `cStart` |
  | Network expansion | `NetworkInvestment` | `cNetworkExp` |
  | Emissions | `Emissions` | `cCO2` |
  | Reliability / NSE | `Reliability` | `cNSE` |

- **Units:** EPRI `System Cost` is million $. GenX `costs.csv` is $. Both are
  2025 dollars (`Parameter.csv` `EconomicBaseYear`).
- **Weights are an emissions/generation question, not a cost question.**
  Neither model's cost table needs representative-week weighting; both
  already report full-year (or full-stage) totals.
