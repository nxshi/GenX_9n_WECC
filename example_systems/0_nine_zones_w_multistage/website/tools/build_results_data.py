#!/usr/bin/env python3
"""Build the small public-results dataset used by the GenX results explorer.

The script reads only published model outputs. It does not change any source
workbook or GenX result. Run with --case-root for a replacement delivery.

Reporting conventions (see EPRI_GenX_visualization_action_plan.md and
COST_RECONCILIATION_GUIDE.md for the evidence behind each):

- Costs are shown as annual, undiscounted dollars for every model.
  EPRI's "System Cost" rows are five-year discounted stage totals, so each is
  divided by the stage PV factor. GenX myopic costs.csv only charges
  investment on capacity built in that stage, so earlier-stage investment is
  carried forward as a running total.
- Each run uses its own representative-period weights. Hourly rows are
  weighted by Sub_Weights / 168 (hours of the year represented by each
  modeled hour), never by a hard-coded 4.
- EPRI vAreaEmission values already include the period weight, so they are
  summed directly. EPRI Generation values are unweighted GW and are weighted.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import pandas as pd

YEARS = [2025, 2030, 2035, 2040, 2045]
HOURS_PER_YEAR = 8760
HOURS_PER_WEEK = 168
STAGE_LENGTH_YEARS = 5

TECH_ORDER = [
    "Biomass", "Geothermal", "Hydro", "Nuclear", "Coal", "NGCC", "Peaker",
    "NG-CCS", "Wind", "Solar", "Storage",
]

COST_ORDER = [
    "Investment", "Fixed O&M", "Variable O&M + fuel", "Network expansion",
    "Emissions", "Reliability / NSE", "Other",
]

COLORS = {
    "Biomass": "#7A9E5B", "Geothermal": "#800020", "Hydro": "#2F80ED",
    "Nuclear": "#E78AC3", "Coal": "#4B5563", "NGCC": "#4A2C20",
    "Peaker": "#9A6B3F", "NG-CCS": "#F28E2B", "Wind": "#59A14F",
    "Solar": "#F2C94C", "Storage": "#8B5CF6",
}

ZONE_NAMES = {
    "1": "Central", "2": "IID", "3": "LADWP", "4": "NCNC",
    "5": "North", "6": "PGE", "7": "SCE", "8": "SDGE", "9": "South",
}

EMISSIONS_REGION = {
    "Central": "Central", "IID": "CAISO", "LADWP": "CAISO",
    "NCNC": "CAISO", "North": "North", "PGE": "CAISO",
    "SCE": "CAISO", "SDGE": "CAISO", "South": "South",
}

# GenX fixed O&M columns and the capacity.csv column each one multiplies.
GENX_FIXED_OM_TERMS = {
    "fixed_om_cost_per_mwyr": "EndCap",
    "fixed_om_cost_per_mwhyr": "EndEnergyCap",
    "fixed_om_cost_charge_per_mwyr": "EndChargeCap",
}


def clean_number(value):
    if value is None or pd.isna(value):
        return None
    return round(float(value), 5)


def tech_group(name: str) -> str | None:
    name = str(name)
    lowered = name.lower()
    if "storage" in lowered:
        return "Storage"
    if "ng-ccs" in lowered or "ng_ccs" in lowered:
        return "NG-CCS"
    if "ngcc" in lowered or "ngcc" in lowered.replace("_", ""):
        return "NGCC"
    if "peaker" in lowered:
        return "Peaker"
    if "solar" in lowered:
        return "Solar"
    if "wind" in lowered:
        return "Wind"
    if "hydro" in lowered:
        return "Hydro"
    if "nuclear" in lowered:
        return "Nuclear"
    if "geothermal" in lowered:
        return "Geothermal"
    if "biomass" in lowered:
        return "Biomass"
    if "coal" in lowered:
        return "Coal"
    return None


def group_columns(frame: pd.DataFrame, row_index: int, scale: float = 1.0):
    grouped = defaultdict(float)
    row = frame.iloc[row_index]
    for column, value in row.iloc[1:].items():
        technology = tech_group(column)
        if technology and pd.notna(value):
            grouped[technology] += float(value) * scale
    return {tech: round(grouped.get(tech, 0.0), 5) for tech in TECH_ORDER}


def stage_pv_factor(year: int, rate: float, base_year: int) -> float:
    """Present value, at base_year, of one dollar per year over a model stage.

    EPRI's System Cost rows equal annual cost times this factor: the stage's
    five years discounted to the start of the stage, then to the base year.
    """
    stage = sum((1 + rate) ** -offset for offset in range(STAGE_LENGTH_YEARS))
    return stage * (1 + rate) ** -(year - base_year)


def representative_weeks(tdr_root: Path):
    """Representative weeks and their weights for one GenX TDR run.

    weight is the number of calendar weeks each representative week stands
    for; hour_weight is the hours of the year each modeled hour stands for
    (Sub_Weights / 168), which is what hourly values must be multiplied by to
    build annual totals.
    """
    mapping = pd.read_csv(tdr_root / "Period_map.csv")
    mapping.columns = [str(column).strip() for column in mapping.columns]
    needed = {"Period_Index", "Rep_Period", "Rep_Period_Index"}
    if not needed.issubset(mapping.columns):
        raise ValueError(f"Unexpected period map columns in {tdr_root / 'Period_map.csv'}")
    summary = (
        mapping.groupby("Rep_Period_Index", sort=True)
        .agg(rep_period=("Rep_Period", "first"), weight=("Period_Index", "size"))
        .reset_index()
    )
    sub_weights = pd.read_csv(tdr_root / "Demand_data.csv")["Sub_Weights"].dropna().to_numpy()
    if len(sub_weights) != len(summary):
        raise ValueError(f"{tdr_root}: {len(sub_weights)} Sub_Weights for {len(summary)} representative periods")
    weeks_modeled = int(summary["weight"].sum())
    weeks = []
    for row, sub_weight in zip(summary.itertuples(index=False), sub_weights):
        expected = row.weight * HOURS_PER_YEAR / weeks_modeled
        if abs(sub_weight - expected) > 1e-3:
            raise ValueError(f"{tdr_root}: Sub_Weights {sub_weight} disagrees with Period_map count {row.weight}")
        weeks.append({
            "index": int(row.Rep_Period_Index),
            "label": f"Representative week {int(row.rep_period)}",
            "source_week": int(row.rep_period),
            "weight": int(row.weight),
            "hour_weight": round(float(sub_weight) / HOURS_PER_WEEK, 6),
        })
    return weeks


def epri_weeks(generation: pd.DataFrame):
    """EPRI's representative weeks, read from its own Generation timestamps.

    EPRI weights are not published; each modeled hour is assumed to stand for
    an equal share of the year (8760 / modeled hours).
    """
    stamps = generation["DateTime"].astype(str)
    lengths = {year: int((stamps.str[:4] == str(year)).sum()) for year in YEARS}
    if len(set(lengths.values())) != 1:
        raise ValueError(f"EPRI Generation rows differ by year: {lengths}")
    hours = lengths[YEARS[0]]
    count, remainder = divmod(hours, HOURS_PER_WEEK)
    if remainder:
        raise ValueError(f"EPRI Generation has {hours} rows per year, not whole weeks")
    first_year = stamps[stamps.str[:4] == str(YEARS[0])].reset_index(drop=True)
    weeks = []
    for position in range(count):
        start = pd.Timestamp(first_year.iloc[position * HOURS_PER_WEEK])
        source_week = (start.dayofyear - 1) // 7 + 1
        weeks.append({
            "index": position + 1,
            "label": f"Representative week {source_week}",
            "source_week": source_week,
            "weight": round(52 / count, 5),
            "hour_weight": round(HOURS_PER_YEAR / hours, 6),
        })
    return weeks


def series_rows(frame: pd.DataFrame):
    labels = frame.iloc[:, 0].astype(str)
    start = next((idx for idx, value in labels.items() if value.startswith("t")), None)
    if start is None:
        raise ValueError("Could not find time-series rows beginning with t")
    return frame.iloc[start:].reset_index(drop=True)


def genx_profile(power_path: Path, charge_path: Path, balance_path: Path, weeks):
    power = series_rows(pd.read_csv(power_path))
    charge = series_rows(pd.read_csv(charge_path))
    balance = series_rows(pd.read_csv(balance_path))
    demand_columns = [column for column in balance.columns if column == "Demand" or column.startswith("Demand.")]
    profiles = []
    for week_position, week in enumerate(weeks):
        start, stop = week_position * HOURS_PER_WEEK, (week_position + 1) * HOURS_PER_WEEK
        power_week = power.iloc[start:stop]
        charge_week = charge.iloc[start:stop]
        balance_week = balance.iloc[start:stop]
        points = []
        for hour in range(len(power_week)):
            generation = group_columns(power_week, hour, scale=0.001)
            # charge.csv, like power.csv, carries a trailing "Total" column that GenX
            # writes for its own bookkeeping (not a resource). group_columns() drops it
            # naturally because tech_group("Total") is None; a plain iloc[hour, 1:].sum()
            # here does not, and was double-counting charge (previously ~2x true value,
            # since Total == sum of the resource columns). Route through the same
            # tech_group() filter so both sides are handled consistently.
            charge_row = charge_week.iloc[hour]
            storage_charge = sum(
                float(value)
                for column, value in charge_row.iloc[1:].items()
                if tech_group(column) == "Storage" and pd.notna(value)
            ) * 0.001
            generation["Storage"] = clean_number(generation.get("Storage", 0) - storage_charge)
            points.append({
                "hour": hour + 1,
                "generation": generation,
                "demand": clean_number(abs(balance_week.iloc[hour][demand_columns].sum()) * 0.001),
            })
        profiles.append({"week": week["index"], "points": points})
    return profiles


def genx_fixed_om_rates(resource_root: Path) -> pd.DataFrame:
    """Fixed O&M rates by resource from one stage's GenX resource files."""
    frames = []
    for path in sorted(resource_root.glob("*.csv")):
        frame = pd.read_csv(path)
        frame.columns = [str(column).strip().lower() for column in frame.columns]
        columns = [column for column in GENX_FIXED_OM_TERMS if column in frame.columns]
        if "resource" in frame.columns and columns:
            frames.append(frame[["resource", *columns]])
    if not frames:
        raise ValueError(f"No fixed O&M columns found under {resource_root}")
    rates = pd.concat(frames, ignore_index=True)
    if rates["resource"].duplicated().any():
        raise ValueError(f"Duplicate resources under {resource_root}")
    return rates.set_index("resource").reindex(columns=list(GENX_FIXED_OM_TERMS)).fillna(0.0)


def genx_fixed_om(capacity: pd.DataFrame, rates: pd.DataFrame) -> float:
    """Annual fixed O&M ($) for a stage: rate x end-of-stage capacity."""
    resources = capacity[capacity["Resource"].isin(rates.index)].set_index("Resource")
    missing = set(capacity["Resource"]) - set(rates.index) - {"Total"}
    if missing:
        raise ValueError(f"Resources in capacity.csv with no input costs: {sorted(missing)[:5]}")
    total = 0.0
    for rate_column, capacity_column in GENX_FIXED_OM_TERMS.items():
        if capacity_column in resources.columns:
            total += float((rates.loc[resources.index, rate_column] * resources[capacity_column].fillna(0)).sum())
    return total


def genx_scenario(case_root: Path, directory: str, scenario_id: str, label: str, tdr_folder: str):
    scenario_root = case_root / directory
    # Time-domain reduction runs separately for each stage, so representative
    # weeks and weights can differ by stage (they do for K-means).
    stage_weeks = [
        representative_weeks(case_root / "inputs" / f"inputs_p{stage}" / tdr_folder)
        for stage in range(1, len(YEARS) + 1)
    ]
    years = []
    cumulative_build = defaultdict(float)
    cumulative_retirement = defaultdict(float)
    cumulative_investment = 0.0
    for stage, year in enumerate(YEARS, start=1):
        stage_root = scenario_root / f"results_p{stage}"
        costs = pd.read_csv(stage_root / "costs.csv")
        costs_by_name = dict(zip(costs["Costs"], costs["Total"]))
        capacity = pd.read_csv(stage_root / "capacity.csv")
        for row in capacity.itertuples(index=False):
            technology = tech_group(row.Resource)
            if technology:
                cumulative_build[technology] += float(row.NewCap) / 1000.0
                cumulative_retirement[technology] += float(row.RetCap) / 1000.0
        installed_capacity = defaultdict(float)
        for row in capacity.itertuples(index=False):
            technology = tech_group(row.Resource)
            if technology:
                installed_capacity[technology] += float(row.EndCap) / 1000.0

        # GenX cFix = investment on capacity built THIS stage + fixed O&M on all
        # capacity. In a myopic run, earlier builds become "existing" capacity in
        # later stages and their investment payments drop out of costs.csv. Split
        # cFix using the run's own totals, then carry investment forward so each
        # year shows the payments on everything built so far (as EPRI reports).
        fixed_om = genx_fixed_om(capacity, genx_fixed_om_rates(case_root / "inputs" / f"inputs_p{stage}" / "resources"))
        stage_investment = costs_by_name.get("cFix", 0) - fixed_om
        if stage_investment < -1e3:
            raise ValueError(f"{stage_root}: fixed O&M {fixed_om:,.0f} exceeds cFix; input costs do not match this run")
        cumulative_investment += max(stage_investment, 0.0)
        variable = sum(costs_by_name.get(name, 0) for name in ("cVar", "cFuel", "cStart"))
        cost_total = costs_by_name.get("cTotal", 0) - stage_investment + cumulative_investment
        breakdown = {
            "Investment": cumulative_investment,
            "Fixed O&M": fixed_om,
            "Variable O&M + fuel": variable,
            "Network expansion": costs_by_name.get("cNetworkExp", 0),
            "Emissions": costs_by_name.get("cCO2", 0),
            "Reliability / NSE": costs_by_name.get("cNSE", 0),
        }
        breakdown["Other"] = cost_total - sum(breakdown.values())

        power = pd.read_csv(stage_root / "power.csv")
        annual_power_row = power.index[power.iloc[:, 0].astype(str) == "AnnualSum"]
        if len(annual_power_row) == 0:
            raise ValueError(f"No AnnualSum in {stage_root / 'power.csv'}")
        # AnnualSum already applies the run's own period weights.
        annual_generation = group_columns(power, annual_power_row[0], scale=1e-6)
        emissions = pd.read_csv(stage_root / "emissions.csv")
        annual_emissions_row = emissions.index[emissions.iloc[:, 0].astype(str) == "AnnualSum"]
        annual_emissions = emissions.iloc[annual_emissions_row[0]]
        zone_emissions = {region: 0.0 for region in ("CAISO", "Central", "North", "South")}
        for column in emissions.columns[1:-1]:
            zone = ZONE_NAMES.get(str(column), f"Zone {column}")
            region = EMISSIONS_REGION.get(zone, zone)
            zone_emissions[region] = zone_emissions.get(region, 0.0) + annual_emissions[column] / 1e6
        zone_breakdown = {region: clean_number(value) for region, value in zone_emissions.items()}
        years.append({
            "year": year,
            "cost_total": clean_number(cost_total / 1e6),
            "cost_reported": clean_number(costs_by_name.get("cTotal", 0) / 1e6),
            "cost_breakdown": {key: clean_number(value / 1e6) for key, value in breakdown.items()},
            "installed_capacity": {tech: round(installed_capacity.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "capacity_mix": {tech: round(cumulative_build.get(tech, 0.0) - cumulative_retirement.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "generation_mix": annual_generation,
            "emissions_total": clean_number(annual_emissions["Total"] / 1e6),
            "emissions_breakdown": zone_breakdown,
            "weeks": stage_weeks[stage - 1],
            "profiles": genx_profile(
                stage_root / "power.csv", stage_root / "charge.csv",
                stage_root / "power_balance.csv", stage_weeks[stage - 1],
            ),
        })
    return {
        "id": scenario_id,
        "label": label,
        "source": "GenX model outputs",
        "profile_note": "Representative-week dispatch and demand from GenX outputs.",
        "capacity_note": "Cumulative net buildout (GW): additions minus retirements, grouped by technology.",
        "emissions_note": "Annual CO₂ emissions (million tonnes) from GenX AnnualSum, aggregated to CAISO, Central, North, and South.",
        "cost_note": (
            "Annual costs from costs.csv. Investment is the running total of annualized "
            "payments on all capacity built to date; costs.csv (cTotal) only includes "
            "capacity built in that stage."
        ),
        "weeks": stage_weeks[0],
        "years": years,
    }


def table_from_row_header(frame: pd.DataFrame, occurrence: int = 0):
    header_rows = [index for index, value in frame.iloc[:, 0].items() if str(value) == "Year"]
    header = header_rows[occurrence]
    data_end = header + 1
    while data_end < len(frame) and pd.notna(frame.iloc[data_end, 0]):
        data_end += 1
    table = frame.iloc[header:data_end].copy()
    table.columns = table.iloc[0]
    return table.iloc[1:].reset_index(drop=True)


def epri_profiles(generation: pd.DataFrame, storage_charge: pd.DataFrame, demand: pd.DataFrame, weeks):
    charge_by_time = storage_charge.groupby(["Year", "LoadLevel"])["vESSCharge"].sum().to_dict()
    demand_zones = [column for column in demand.columns if column not in {"Year", "LoadLevel"}]
    demand = demand.copy()
    demand["Demand_MW"] = demand[demand_zones].apply(pd.to_numeric, errors="coerce").sum(axis=1)
    demand_by_time = demand.set_index(["Year", "LoadLevel"])["Demand_MW"].to_dict()
    profiles_by_year = {}
    for year in YEARS:
        year_frame = generation[generation["DateTime"].astype(str).str[:4] == str(year)].reset_index(drop=True)
        profiles = []
        for position, week in enumerate(weeks):
            frame = year_frame.iloc[position * HOURS_PER_WEEK:(position + 1) * HOURS_PER_WEEK]
            points = []
            for hour, row in frame.iterrows():
                generation_row = {tech: 0.0 for tech in TECH_ORDER}
                for column, value in row.items():
                    technology = tech_group(column)
                    if technology and pd.notna(value):
                        generation_row[technology] += float(value)
                load_level = str(row["DateTime"])[5:]
                generation_row["Storage"] -= float(charge_by_time.get((year, load_level), 0.0))
                demand_mw = demand_by_time.get((year, load_level))
                if demand_mw is None:
                    raise ValueError(f"No Demand.csv match for EPRI timestamp {year}-{load_level}")
                points.append({
                    "hour": hour - position * HOURS_PER_WEEK + 1,
                    "generation": {key: round(value, 5) for key, value in generation_row.items()},
                    "demand": round(float(demand_mw) / 1000.0, 5),
                })
            profiles.append({"week": week["index"], "points": points})
        profiles_by_year[year] = profiles
    return profiles_by_year


def source_starting_fleet(source_root: Path):
    """Existing (non-candidate) nameplate capacity by technology, in GW."""
    units = pd.read_csv(source_root / "Generation.csv")
    existing = units[~units["Unit"].astype(str).str.endswith("_Invest")]
    fleet = defaultdict(float)
    for row in existing.itertuples(index=False):
        technology = tech_group(row.Unit)
        if technology is None:
            raise ValueError(f"Unrecognized technology for existing unit {row.Unit}")
        fleet[technology] += float(row.MaximumPower) / 1000.0
    return fleet


def epri_scenario(case_root: Path, source_root: Path, discount_rate: float, base_year: int):
    workbook = case_root / "Results_EPRI.xlsb"
    costs = pd.read_excel(workbook, sheet_name="System Cost", header=2, engine="pyxlsb")
    buildout_raw = pd.read_excel(workbook, sheet_name="Buildout", header=None, engine="pyxlsb")
    buildout = table_from_row_header(buildout_raw, occurrence=1)
    retirement_raw = pd.read_excel(workbook, sheet_name="Retirement", header=None, engine="pyxlsb")
    retirement = table_from_row_header(retirement_raw, occurrence=1)
    generation = pd.read_excel(workbook, sheet_name="Generation", header=2, engine="pyxlsb")
    storage_raw = pd.read_excel(workbook, sheet_name="Storage", header=None, engine="pyxlsb")
    storage_charge = storage_raw.iloc[3:, 7:11].copy()
    storage_charge.columns = ["Year", "LoadLevel", "Unit", "vESSCharge"]
    storage_charge["Year"] = pd.to_numeric(storage_charge["Year"], errors="coerce")
    storage_charge["vESSCharge"] = pd.to_numeric(storage_charge["vESSCharge"], errors="coerce").fillna(0)
    storage_charge = storage_charge.dropna(subset=["Year", "LoadLevel"])
    storage_charge["Year"] = storage_charge["Year"].astype(int)
    storage_charge["LoadLevel"] = storage_charge["LoadLevel"].astype(str)
    emissions = pd.read_excel(workbook, sheet_name="Emissions", header=2, engine="pyxlsb")
    demand = pd.read_csv(source_root / "Demand.csv")
    weeks = epri_weeks(generation)
    profiles = epri_profiles(generation, storage_charge, demand, weeks)
    baseline_capacity = source_starting_fleet(source_root)
    years = []
    for year in YEARS:
        cost_row = costs[costs["Year"] == year].iloc[0]
        build_row = buildout[buildout["Year"] == year].iloc[0]
        retirement_row = retirement[retirement["Year"] == year].iloc[0]
        capacity_mix = {tech: 0.0 for tech in TECH_ORDER}
        for column, value in build_row.items():
            technology = tech_group(column)
            if technology and pd.notna(value):
                capacity_mix[technology] += float(value)
        for column, value in retirement_row.items():
            technology = tech_group(column)
            if technology and pd.notna(value):
                capacity_mix[technology] -= float(value)
        installed_capacity = {
            tech: round(baseline_capacity.get(tech, 0.0) + capacity_mix.get(tech, 0.0), 5)
            for tech in TECH_ORDER
        }
        # Generation values are unweighted hourly GW: weight each hour by the
        # hours of the year it represents to get annual TWh.
        year_generation = generation[generation["DateTime"].astype(str).str[:4] == str(year)].reset_index(drop=True)
        generation_mix = defaultdict(float)
        for position, week in enumerate(weeks):
            week_frame = year_generation.iloc[position * HOURS_PER_WEEK:(position + 1) * HOURS_PER_WEEK]
            for column in week_frame.columns[1:]:
                technology = tech_group(column)
                if technology:
                    generation_mix[technology] += week_frame[column].fillna(0).sum() * week["hour_weight"] / 1000.0
        # vAreaEmission already includes the period weight (each hourly value is
        # ~4x the CO2 that hour's generation emits), so it is summed directly.
        year_emissions = emissions[emissions["Year"] == year]
        emissions_breakdown = {
            str(area): clean_number(area_frame["vAreaEmission"].fillna(0).sum())
            for area, area_frame in year_emissions.groupby("Area")
        }
        # System Cost rows are five-year discounted stage totals: convert to annual.
        factor = stage_pv_factor(year, discount_rate, base_year)
        annual = {column: float(cost_row[column]) / factor for column in costs.columns if column != "Year"}
        breakdown = {
            "Investment": annual["GenInvestment"],
            "Fixed O&M": annual["GenFixedOM"],
            "Variable O&M + fuel": annual["GenVariable"],
            "Network expansion": annual["NetworkInvestment"],
            "Emissions": annual["Emissions"],
            "Reliability / NSE": annual["Reliability"],
        }
        breakdown["Other"] = annual["Total"] - sum(breakdown.values())
        years.append({
            "year": year,
            "cost_total": clean_number(annual["Total"]),
            "cost_reported": clean_number(cost_row["Total"]),
            "cost_breakdown": {key: clean_number(value) for key, value in breakdown.items()},
            "installed_capacity": installed_capacity,
            "capacity_mix": {tech: round(capacity_mix.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "generation_mix": {tech: round(generation_mix.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "emissions_total": clean_number(sum(value or 0 for value in emissions_breakdown.values())),
            "emissions_breakdown": emissions_breakdown,
            "weeks": weeks,
            "profiles": profiles[year],
        })
    return {
        "id": "epri",
        "label": "EPRI",
        "source": "EPRI delivered Results_EPRI.xlsb",
        "profile_note": "Generation is from the EPRI workbook. Demand is matched from Demand.csv by timestamp.",
        "capacity_note": "Cumulative net buildout (GW): additions minus retirements. Installed capacity adds this net change to the starting fleet in the source Generation.csv.",
        "emissions_note": "Annual emissions (million tonnes): sum of vAreaEmission, which already includes the representative-period weight.",
        "cost_note": (
            "Annual costs: each System Cost row divided by the five-year stage present-value "
            "factor (7%, discounted to 2025)."
        ),
        "weeks": weeks,
        "years": years,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    case_root = args.case_root
    source_root = case_root / "inputs" / "WECC-9n test system" / "data"
    parameters = pd.read_csv(source_root / "Parameter.csv")
    dollar_year = int(parameters.iloc[0]["EconomicBaseYear"])
    discount_rate = float(parameters.iloc[0]["AnnualDiscountRate"])
    scenarios = [
        epri_scenario(case_root, source_root, discount_rate, dollar_year),
        genx_scenario(case_root, "results_kmeans_myopic", "kmeans_myopic", "GenX (K-means; myopic)", "TDR_results_kmeans"),
        genx_scenario(case_root, "results_sampled_myopic", "sampled_myopic", "GenX (sampled weeks; myopic)", "TDR_results"),
    ]
    cost_components = [
        key for key in COST_ORDER
        if key != "Other" or any(abs(row["cost_breakdown"].get(key) or 0) > 0.5 for item in scenarios for row in item["years"])
    ]
    data = {
        "title": "WECC capacity-expansion results",
        "years": YEARS,
        "dollar_year": dollar_year,
        "cost_unit": f"million {dollar_year} USD per year",
        "cost_basis": "annual, undiscounted",
        "cost_components": cost_components,
        "technologies": TECH_ORDER,
        "technology_colors": COLORS,
        "chart_notes": {
            "cost": (
                f"Annual, undiscounted costs in {dollar_year} dollars for every model. EPRI's workbook "
                "reports each year as a five-year stage total discounted to 2025; those values are "
                "divided by that factor. GenX myopic runs only charge investment in the year capacity "
                "is built; Investment here carries those payments forward so every year includes "
                "all capacity built to date, as EPRI's does."
            ),
            "buildout": "Cumulative net buildout equals additions minus retirements.",
            "installed_capacity": (
                "Starting fleet from the source Generation.csv (176.6 GW) plus each model's "
                "additions minus retirements."
            ),
            "generation": (
                "Annual generation in TWh. Representative-period hours are weighted by the hours of "
                "the year each one represents (each run uses its own weights)."
            ),
            "emissions": (
                "Annual CO₂ emissions. GenX zones IID, LADWP, NCNC, PGE, SCE, and SDGE are aggregated "
                "into CAISO to match EPRI's four reporting areas."
            ),
        },
        "scenarios": scenarios,
        "method_notes": [
            f"All costs are annual and undiscounted, in {dollar_year} dollars. EPRI's System Cost sheet "
            "reports five-year stage totals discounted at 7% to 2025 (factor 4.387 in 2025, 1.134 in "
            "2045); the site divides by that factor. The original values are kept in the dataset as "
            "cost_reported.",
            "GenX myopic costs.csv only includes investment on capacity built in that stage. The site "
            "carries each stage's investment forward, so GenX totals are higher than GenX's reported "
            "cTotal from 2030 onward.",
            "Investment is annualized capital cost (7%, 30 years). Fixed O&M covers all installed "
            "capacity. Variable O&M + fuel combines variable O&M, fuel, and start-up costs.",
            "Each model result is built from 13 representative weeks. Annual totals weight each week "
            "by the part of the year it represents: 4 weeks each for the sampled-week runs and EPRI; "
            "1 to 14 weeks for K-means, which picks different weeks in each model year.",
            "EPRI emissions are the sum of vAreaEmission, which already includes the representative-"
            "period weight. EPRI generation is hourly GW and is weighted to annual TWh.",
            "The test system covers California and neighbouring WECC regions with 1.3 GW of coal, so "
            "annual emissions (~60 Mt in 2025) are well below WECC-wide totals.",
            "The K-means GenX result predates the learning-rate and storage-efficiency input fixes "
            "and is not yet directly comparable.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("window.RESULTS_DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    sys.exit(main())
