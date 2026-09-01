# WECC 9-Node Test System: Data and Assumptions

Data description compiled by Sean Ericson.

Please reach out at sericson@epri.com with any questions.

## 1. Overview

This dataset is a stylized, aggregated representation of California and the neighboring Western Interconnection. It is intended to be a small test system for comparing long-term resource-planning and capacity-expansion tools.

The reference system contains:

- Nine nodes: six California subregions and three neighboring WECC regions;
- Four planning areas for resource-adequacy and policy constraints;
- Five planning years: 2025, 2030, 2035, 2040, and 2045;
- Hourly load and resource-availability profiles;
- 140 aggregated generation records spanning existing and candidate resources;
- 17 transmission lines; and
- Exogenous retirement and technology-cost trajectories.

This document describes the system, the data provided, and modeling assumptions and defaults.

The following modeling assumptions are made:

* A 7% discount rate is used.
* Model periods are five-year intervals.
* Load-shedding costs are $10,000/MWh.
* Investment and retirement decisions are continuous variables.
* DC power flow, unit commitment, ramp constraints, and minimum up/down times are excluded.
* Retirement schedules provide a lower bound on retirements, and additional retirements can be made to avoid ongoing fixed costs.


The following table describes each of the data files provided:

| File | Purpose | Delivered size |
|---|---|---:|
| NodeLocation.csv | Node-to-area mapping and coordinates | 9 nodes |
| Network.csv | Directed transfer limits and losses | 19 records |
| Generation.csv | Existing and candidate resource attributes | 140 units |
| Demand.csv | Hourly nodal load | 43,800 rows |
| AvailabilityFactor.csv | Hourly wind, solar, and hydro availability | 43,800 rows; 56 resource columns |
| AreaConstraints.csv | Area-level reserve, emissions, and renewable constraints | 20 rows |
| Retirements.csv | Cumulative retirement fractions by unit and year | 5 years; 23 units |
| LearningRates.csv | Investment-cost multipliers by technology and year | 5 years; 6 technologies |
| Parameter.csv | Model parameter specifications | 1 row |

## 2. Geography

The six California nodes share the `CAISO` planning area for area-level resource-adequacy, emissions, and renewable-energy constraints. `Central`, `North`, and `South` are each both a node and a planning area.

| Node | Area | Description |
|---|---|---|
| `IID` | `CAISO` | Imperial Irrigation District |
| `LADWP` | `CAISO` | Los Angeles Department of Water and Power |
| `NCNC` | `CAISO` | Northern California non-CAISO utilities, including SMUD, TID, and smaller utilities |
| `PGE` | `CAISO` | Pacific Gas and Electric |
| `SCE` | `CAISO` | Southern California Edison |
| `SDGE` | `CAISO` | San Diego Gas and Electric |
| `North` | `North` | Portland General Electric, Bonneville Power Administration, and PacifiCorp West |
| `Central` | `Central` | Nevada Power Company |
| `South` | `South` | Arizona Public Service, Salt River Project, and Western Area Power Administration - Lower Colorado |

`NodeLocation.csv` provides approximate regional centroids. The coordinates support mapping and distance calculations but do not directly affect dispatch.

<img src="Region%20Map.png" alt="WECC 9-node region map" width="600">

The `NodeLocation.csv` file provides the latitude-longitude centroids of each location, along with the mappings from nodes to areas.

The `AreaConstraints.csv` file specifies the reserve margins for each area and period. The system uses a 15% reserve margin: available capacity credits must be greater than 115% of peak load.

## 3. Temporal Structure

The delivered `Demand.csv`, `AvailabilityFactor.csv`, `Retirements.csv`, and `LearningRates.csv` files cover 2025 through 2045 in five-year increments. Demand and availability each contain 8,760 hourly records per modeled year, or 43,800 rows total. Leap days are excluded.

`LoadLevel` uses UTC-aware timestamps formatted as `MM-DD HH:MM:SS+00:00`. The year is stored separately in `Year`.

The model is configured to run 13 representative weeks at hourly time-steps. EPRI's internal model ran using a simple specification of modeling using the first week of each month as the representative week (peak load was calculated using the full 8760 profile for each year). Part of the model comparison is that models have different approaches for temporal aggregation, so each model can be configured based on its preferred aggregation approach.

## 4. Generation

Individual plants are aggregated into technology classes at each node. Natural-gas combined-cycle (`NGCC`) and peaking resources are split into efficiency classes where applicable; class 1 has a lower heat rate and is more efficient. Other existing resources have one aggregate record per node and technology.

Candidate resources use `_Invest` in the unit name. Solar and wind candidates may also use `_LowerQuality_Invest`; their availability factors are 25% below the corresponding higher-quality profiles. Candidate values are build limits rather than required investments. All investment and operation decisions are assumed to be continuous variables, with no commitment or ramping constraints implemented.

Expected forced outage rates have been applied to derate capacity (and increase capacity costs) so EFOR does not need to be reapplied.

### 4.2 Existing capacity

The 81 records without `_Invest` provide 176,620 MW of initial nameplate capacity.

| Technology | Existing capacity (MW) |
|---|---:|
| Biomass | 1,420 |
| Coal | 1,260 |
| Geothermal | 1,770 |
| Hydro | 36,400 |
| NGCC | 40,650 |
| Nuclear | 7,260 |
| Peaker | 16,430 |
| Solar | 35,730 |
| Storage (discharge power) | 19,890 |
| Wind | 15,810 |
| **Total** | **176,620** |

`Retirements.csv` supplies cumulative retirement fractions for 23 existing units. A value of `0` retains all initial capacity and `1` retires the full aggregate by that year; intermediate values retire the specified fraction.

The schedules incorporate known retirements between 2025 and 2045. Existing storage follows an approximate cumulative retirement path of 10% by 2035, 20% by 2040, and 30% by 2045, with small regional differences caused by aggregation.

### 4.3 Investments

The 59 candidate records define upper bounds on buildable capacity.

| Technology | Records | Aggregate `MaximumPower` (MW) | Base CAPEX ($/kW) |
|---|---:|---:|---:|
| NGCC | 9 | 56,830 | 1,600 |
| NG-CCS | 6 | 74,630 | 3,300; Central: 7,850 |
| Peaker | 9 | 56,630 | 1,410 |
| Solar | 18 | 257,900 | 1,530 |
| Storage | 9 | 220,400 | 1,630 |
| Wind | 10 | 125,180 | 1,650 |

Candidate storage has four-hour energy capacity (`MaximumStorage = 4 x MaximumPower`), round-trip efficiency of 0.90.

The following investment-cost assumptions apply:

* A 30-year financial life is used.
* A 7% discount rate is used.
* Investment costs in a given year equal base costs multiplied by the learning-rate factor.

`0.080586404` is the fixed charge rate to annualize investment costs for a 30-year financial life at a 7% discount rate.


`LearningRates.csv` provides exogenous multipliers on base investment costs. Multipliers are uniform across nodes.

| Year | NGCC | NG-CCS | Peaker | Solar | Storage | Wind |
|---|---:|---:|---:|---:|---:|---:|
| 2025 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| 2030 | 0.955 | 0.903 | 0.963 | 0.800 | 0.838 | 0.897 |
| 2035 | 0.909 | 0.805 | 0.926 | 0.600 | 0.774 | 0.851 |
| 2040 | 0.875 | 0.761 | 0.889 | 0.553 | 0.709 | 0.804 |
| 2045 | 0.841 | 0.718 | 0.852 | 0.505 | 0.644 | 0.757 |

### 4.4 Capacity Credits

Generators are modeled as receiving a fixed capacity credit. The sum of installed capacity multiplied by capacity credit must exceed the reserve margin for each area and year. Solar and wind investments have lower capacity credits than existing technologies.


### 4.5 Generation Schema

The following columns can be ignored in the generation schema for this test system:
`MustRun`, `BinaryInvestment`, `BinaryRetirement`, `BinaryCommitment`, `InitialYear`,
`MinimumPower`, `MaximumCharge`, `EFOR`, `RampUp`, `RampDown`, `UpTime`, `DownTime`,
`StartUpCost`, `ShutDownCost`, `FixedRetirementCost`, `InvestmentLo`, `NoRetirement`.

The remaining columns are described below.

| Columns | Units | Description |
|---|---|---|
| `Unit`, `Node`, `Technology` | - | Unique resource name, connection node, and technology class |
| `MaximumStorage` | MWh | Storage energy capacity |
| `Efficiency` | p.u. | Storage round-trip efficiency |
| `FuelCost` | $/MMBtu | Fuel price |
| `LinearTerm`, `ConstantTerm` | MMBtu/MWh; MMBtu/h | Linear heat-rate parameters |
| `OMVariableCost` | $/MWh | Variable operation and maintenance cost |
| `OMFixedCost` | $/kW-year | Fixed operation and maintenance cost |
| `CO2EmissionRate` | tCO2/MMBtu | Fuel carbon intensity |
| `CapacityCredit` | p.u. | Contribution to the capacity requirement |
| `FixedInvestmentCost` | $/kW | Overnight investment costs |
| `FixedChargeRate` | p.u. | Annualization factor for investment cost |

## 5. Demand

`Demand.csv` contains hourly, perfectly inelastic load in MW for every node and modeled year. Its index columns are `Year` and `LoadLevel`, followed by the nine node columns.

Load projections are based on CPUC data using the 2019 weather year, selected as an approximately average load year. The source projections begin in 2026, so they were scaled down to estimate 2025. Projections ended in 2045; the source notes describe extrapolating 2050 from average regional growth, but no 2050 demand rows are included in the delivered file.

| Year | Central | IID | LADWP | NCNC | North | PGE | SCE | SDGE | South |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2025 | 7,909 | 1,107 | 5,616 | 5,195 | 25,350 | 21,590 | 22,648 | 4,968 | 18,168 |
| 2030 | 8,452 | 1,127 | 5,712 | 5,478 | 27,497 | 23,443 | 23,579 | 5,411 | 21,180 |
| 2035 | 8,742 | 1,170 | 6,108 | 5,937 | 29,620 | 26,829 | 26,190 | 6,307 | 23,637 |
| 2040 | 9,171 | 1,227 | 8,044 | 6,488 | 32,037 | 30,575 | 29,118 | 7,073 | 26,446 |
| 2045 | 9,611 | 1,270 | 9,177 | 7,070 | 34,705 | 35,859 | 32,577 | 8,208 | 30,445 |

Values are nodal peak MW, rounded to the nearest MW.

## 6. Renewable and Hydro Availability

`AvailabilityFactor.csv` contains hourly capacity factors in p.u. for 56 resource columns:

- 9 existing solar profiles;
- 8 existing wind profiles;
- 6 existing hydro profiles;
- 9 candidate solar and 9 lower-quality solar profiles; and
- 8 candidate wind and 8 lower-quality wind profiles.

Wind and solar profiles are based on CPUC 2017-2022 weather data mapped sequentially to planning periods: 2017 maps to 2025, 2018 to 2030, and so on. The source notes map 2022 to an intended 2050 period; the delivered file stops at 2045. Hydro profiles use 2015 conditions, selected as a relatively dry water year. All profiles vary by location.

Hydro is represented as run-of-river, with hourly availability-limited generation.

## 7. Transmission Network

`Network.csv` represents a transport model with transfer limits and losses. No transmission investment is modeled for this case study.

The following columns in the network schema can be ignored:
`InitialYear`, `FinalYear`, `Length`, `Reactance`, `TTCBck`, `SecurityFactor`,
`FixedInvestmentCost`, `FixedChargeRate`, `BinaryInvestment`, `MaxExpansion`.

Transfer limits are based on CPUC 2024 regional transfer limits. Loss factors are approximately 0.5% per 100 miles.

| Column | Units | Description |
|---|---|---|
| `NodeFrom`, `NodeTo` | - | Directed interface endpoints |
| `LossFactor` | p.u. | Fractional transfer loss |
| `TTC` | MW | Forward total transfer capability |

## 12. Units and Conventions

| Quantity | Input units |
|---|---|
| Power, load, transfer capability | MW |
| Storage energy | MWh |
| Availability, efficiency, losses, retirement fractions | p.u. |
| Fuel price | $/MMBtu |
| Variable O&M | $/MWh |
| Fixed O&M | $/kW-year |
| Overnight investment cost | $/kW |
| Heat-rate slope | MMBtu/MWh |
| Emissions rate | tCO2/MMBtu |
| Time | UTC, hourly source records |

## 13. Data Sources

- [CPUC 2024-26 IRP system-reliability modeling datasets](https://www.cpuc.ca.gov/industries-and-topics/electrical-energy/electric-power-procurement/long-term-procurement-planning/2024-26-irp-cycle-events-and-materials/system-reliability-modeling-datasets-2024)
- [WECC 2024 Anchor Power Dataset](https://www.wecc.org/wecc-document/11081)
- [CPUC 2024 Baseline Generator List](https://files.cpuc.ca.gov/energy/modeling/2024_servm_updates/BaselineGeneratorList_v20240814.xlsx)
- [CPUC 2024 Region Transfer Limits and Hurdles](https://files.cpuc.ca.gov/energy/modeling/2024_servm_updates/RegionTransferLimitsAndHurdles_2024Jun.xlsx)