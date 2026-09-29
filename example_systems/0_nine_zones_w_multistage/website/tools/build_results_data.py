#!/usr/bin/env python3
"""Build the small public-results dataset used by the GenX results explorer.

The script reads only published model outputs. It does not change any source
workbook or GenX result. Run with --case-root for a replacement delivery.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import pandas as pd

YEARS = [2025, 2030, 2035, 2040, 2045]

TECH_ORDER = [
    "Biomass", "Geothermal", "Hydro", "Nuclear", "Coal", "NGCC", "Peaker",
    "NG-CCS", "Wind", "Solar", "Storage",
]

COST_ORDER = [
    "Fixed O&M", "Variable O&M", "Network expansion",
    "Emissions", "Reliability / NSE",
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


def representative_weeks(period_map_path: Path):
    mapping = pd.read_csv(period_map_path)
    mapping.columns = [str(column).strip() for column in mapping.columns]
    needed = {"Period_Index", "Rep_Period", "Rep_Period_Index"}
    if not needed.issubset(mapping.columns):
        raise ValueError(f"Unexpected period map columns in {period_map_path}")
    summary = (
        mapping.groupby("Rep_Period_Index", sort=True)
        .agg(rep_period=("Rep_Period", "first"), weight=("Period_Index", "size"))
        .reset_index()
    )
    weeks = [
        {
            "index": int(row.Rep_Period_Index),
            "label": f"Representative week {int(row.rep_period)}",
            "source_week": int(row.rep_period),
            "weight": int(row.weight),
        }
        for row in summary.itertuples(index=False)
    ]
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
        start, stop = week_position * 168, (week_position + 1) * 168
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


def genx_scenario(case_root: Path, directory: str, scenario_id: str, label: str, weeks):
    scenario_root = case_root / directory
    multistage_costs = pd.read_csv(scenario_root / "costs_multi_stage.csv")
    multistage_costs_by_name = multistage_costs.set_index("Costs")
    years = []
    cumulative_build = defaultdict(float)
    cumulative_retirement = defaultdict(float)
    for stage, year in enumerate(YEARS, start=1):
        stage_root = scenario_root / f"results_p{stage}"
        cost_column = f"TotalCosts_p{stage}"
        if cost_column not in multistage_costs_by_name.columns:
            raise ValueError(
                f"Missing {cost_column} in {scenario_root / 'costs_multi_stage.csv'}"
            )
        costs_by_name = multistage_costs_by_name[cost_column].to_dict()
        cost_total = pd.to_numeric(
            multistage_costs_by_name[cost_column], errors="coerce"
        ).fillna(0).sum()
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
        power = pd.read_csv(stage_root / "power.csv")
        annual_power_row = power.index[power.iloc[:, 0].astype(str) == "AnnualSum"]
        if len(annual_power_row) == 0:
            raise ValueError(f"No AnnualSum in {stage_root / 'power.csv'}")
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
            "cost_breakdown": {
                "Fixed O&M": clean_number(costs_by_name.get("cFix", 0) / 1e6),
                "Variable O&M": clean_number(sum(
                    costs_by_name.get(name, 0) for name in ("cVar", "cFuel", "cStart")
                ) / 1e6),
                "Network expansion": clean_number(costs_by_name.get("cNetworkExp", 0) / 1e6),
                "Emissions": clean_number(costs_by_name.get("cCO2", 0) / 1e6),
                "Reliability / NSE": clean_number(costs_by_name.get("cNSE", 0) / 1e6),
                "Other / residual": clean_number((
                    cost_total
                    - costs_by_name.get("cFix", 0)
                    - sum(costs_by_name.get(name, 0) for name in ("cVar", "cFuel", "cStart"))
                    - costs_by_name.get("cNetworkExp", 0)
                    - costs_by_name.get("cCO2", 0)
                    - costs_by_name.get("cNSE", 0)
                ) / 1e6),
            },
            "installed_capacity": {tech: round(installed_capacity.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "capacity_mix": {tech: round(cumulative_build.get(tech, 0.0) - cumulative_retirement.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "generation_mix": annual_generation,
            "emissions_total": clean_number(annual_emissions["Total"] / 1e6),
            "emissions_breakdown": zone_breakdown,
            "profiles": genx_profile(
                stage_root / "power.csv", stage_root / "charge.csv",
                stage_root / "power_balance.csv", weeks,
            ),
        })
    return {
        "id": scenario_id,
        "label": label,
        "source": "GenX model outputs",
        "profile_note": "Representative-week dispatch and demand from GenX outputs.",
        "capacity_note": "Cumulative net buildout (GW): additions minus retirements, grouped by technology.",
        "emissions_note": "Annual CO₂ emissions (million tonnes), aggregated to CAISO, Central, North, and South.",
        "weeks": weeks,
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
            frame = year_frame.iloc[position * 168:(position + 1) * 168]
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
                    "hour": hour - position * 168 + 1,
                    "generation": {key: round(value, 5) for key, value in generation_row.items()},
                    "demand": round(float(demand_mw) / 1000.0, 5),
                })
            profiles.append({"week": week["index"], "points": points})
        profiles_by_year[year] = profiles
    return profiles_by_year


def epri_scenario(case_root: Path, weeks):
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
    demand = pd.read_csv(case_root / "inputs" / "WECC-9n test system" / "data" / "Demand.csv")
    profiles = epri_profiles(generation, storage_charge, demand, weeks)
    baseline_capacity = defaultdict(float)
    baseline = pd.read_csv(case_root / "results_sampled_myopic" / "results_p1" / "capacity.csv")
    for row in baseline.itertuples(index=False):
        technology = tech_group(row.Resource)
        if technology:
            baseline_capacity[technology] += float(row.StartCap) / 1000.0
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
        year_generation = generation[generation["DateTime"].astype(str).str[:4] == str(year)].reset_index(drop=True)
        generation_mix = defaultdict(float)
        for position, _ in enumerate(weeks):
            week_frame = year_generation.iloc[position * 168:(position + 1) * 168]
            for column in week_frame.columns[1:]:
                technology = tech_group(column)
                if technology:
                    # The EPRI workbook provides 13 sampled weeks. Each sampled week
                    # represents four calendar weeks, so annualize the summed hourly
                    # generation before converting GWh to TWh.
                    generation_mix[technology] += week_frame[column].fillna(0).sum() * 4 / 1000.0
        year_emissions = emissions[emissions["Year"] == year]
        emissions_breakdown = {}
        for area, area_frame in year_emissions.groupby("Area"):
            annual_sum = 0.0
            for position, _ in enumerate(weeks):
                week_frame = area_frame.iloc[position * 168:(position + 1) * 168]
                annual_sum += week_frame["vAreaEmission"].fillna(0).sum()
            emissions_breakdown[str(area)] = clean_number(annual_sum)
        years.append({
            "year": year,
            "cost_total": clean_number(cost_row["Total"]),
            "cost_breakdown": {
                "Fixed O&M": clean_number(
                    cost_row["GenInvestment"] + cost_row["GenFixedOM"] + cost_row["GenRetirement"]
                ),
                "Variable O&M": clean_number(cost_row["GenVariable"]),
                "Network expansion": clean_number(cost_row["NetworkInvestment"]),
                "Emissions": clean_number(cost_row["Emissions"]),
                "Reliability / NSE": clean_number(cost_row["Reliability"]),
                "Other / residual": clean_number(
                    cost_row["Total"]
                    - cost_row["GenInvestment"] - cost_row["GenFixedOM"]
                    - cost_row["GenRetirement"] - cost_row["GenVariable"]
                    - cost_row["NetworkInvestment"] - cost_row["Emissions"]
                    - cost_row["Reliability"]
                ),
            },
            "installed_capacity": installed_capacity,
            "capacity_mix": {tech: round(capacity_mix.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "generation_mix": {tech: round(generation_mix.get(tech, 0.0), 5) for tech in TECH_ORDER},
            "emissions_total": clean_number(sum(value or 0 for value in emissions_breakdown.values())),
            "emissions_breakdown": emissions_breakdown,
            "profiles": profiles[year],
        })
    return {
        "id": "epri",
        "label": "EPRI",
        "source": "EPRI delivered Results_EPRI.xlsb",
        "profile_note": "Generation is from the EPRI workbook. Demand is matched from Demand.csv by timestamp.",
        "capacity_note": "Cumulative net buildout (GW): additions minus retirements. Installed capacity uses the common starting fleet plus this net change.",
        "emissions_note": "Annual emissions (million tonnes) summed directly from the EPRI representative-week area emissions with no additional week weighting.",
        "weeks": weeks,
        "years": years,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    case_root = args.case_root
    parameters = pd.read_csv(case_root / "inputs" / "WECC-9n test system" / "data" / "Parameter.csv")
    dollar_year = int(parameters.iloc[0]["EconomicBaseYear"])
    input_root = case_root / "inputs" / "inputs_p1"
    sampled_weeks = representative_weeks(input_root / "TDR_results" / "Period_map.csv")
    kmeans_weeks = representative_weeks(input_root / "TDR_results_kmeans" / "Period_map.csv")
    sampled_scenario = genx_scenario(
        case_root, "results_sampled_myopic", "sampled_myopic", "GenX (sampled weeks; myopic)", sampled_weeks
    )
    epri = epri_scenario(case_root, sampled_weeks)
    data = {
        "title": "WECC capacity-expansion results",
        "years": YEARS,
        "dollar_year": dollar_year,
        "cost_unit": f"million {dollar_year} USD",
        "cost_components": COST_ORDER,
        "technologies": TECH_ORDER,
        "technology_colors": COLORS,
        "chart_notes": {
            "cost": (
                "Fixed O&M includes EPRI generation investment, fixed O&M, and retirement costs. "
                "Variable O&M combines GenX variable O&M, fuel, and startup costs."
            ),
            "buildout": "Cumulative net buildout equals additions minus retirements.",
            "generation": (
                "GenX annual generation is converted from MWh to TWh. EPRI annual generation "
                "is annualized by multiplying the 13 sampled-week total by four."
            ),
            "emissions": (
                "GenX emissions for IID, LADWP, NCNC, PGE, SCE, and SDGE are aggregated into CAISO "
                "to match the four EPRI reporting regions."
            ),
        },
        "scenarios": [
            epri,
            genx_scenario(case_root, "results_kmeans_myopic", "kmeans_myopic", "GenX (K-means; myopic)", kmeans_weeks),
            sampled_scenario,
        ],
        "method_notes": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("window.RESULTS_DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
