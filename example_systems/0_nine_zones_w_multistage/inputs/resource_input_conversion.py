#!/usr/bin/env python3
"""Populate GenX resource inputs from the WECC-9n Generation.csv delivery.

Companion to system_input_conversion.py: that script converts the four
`system` tables, this one converts Generation.csv (plus Retirements.csv and
AreaConstraints.csv) into the `resources` tables for each inputs_p1..
inputs_p5 stage:

- resources/Thermal.csv, Vre.csv, Storage.csv, Hydro.csv
- resources/Resource_multistage_data.csv
- resources/policy_assignments/Resource_capacity_reserve_margin.csv
- policies/Capacity_reserve_margin.csv

Thermal and Storage resources are NOT added to Generators_variability.csv.
GenX defaults any resource missing from that file to availability = 1.0 at
load time (src/load_inputs/load_generators_variability.jl: any RESOURCE_NAME
not already a column gets ensure_column!(gen_var, r, 1.0)), so dispatchable
resources need no entry there.

Two modeling choices below are PENDING sign-off from the project lead and are
marked as such inline:
  - Storage round-trip efficiency (a single value in the source) is split
    symmetrically via sqrt() into Eff_Up/Eff_Down.
  - Hydro is written as GenX's Hydro.csv resource type with
    Hydro_Energy_to_Power_Ratio = 0 (pure run-of-river, no reservoir), since
    the source provides no reservoir-size data for hydro.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path

from system_input_conversion import (
    STAGES,
    ZONE_MAP,
    FUEL_MAP,
    read_csv,
    write_csv_atomic,
    require,
)

NODE_AREA = {
    "Central": "Central", "IID": "CAISO", "LADWP": "CAISO", "NCNC": "CAISO",
    "North": "North", "PGE": "CAISO", "SCE": "CAISO", "SDGE": "CAISO", "South": "South",
}
REVERSE_FUEL_MAP = {node_tech: fuel for fuel, node_tech in FUEL_MAP.items()}

THERMAL_TECHS = {"NGCC", "Peaker", "NG-CCS", "Coal", "Nuclear", "Biomass", "Geothermal"}
VRE_TECHS = {"Solar", "Wind"}
STORAGE_TECHS = {"Storage"}
HYDRO_TECHS = {"Hydro"}

# Data documentation section 4.3: 7% discount rate, 30-year financial life,
# uniform across every resource (not technology-specific).
WACC, CAPITAL_RECOVERY_PERIOD, LIFETIME = "0.07", "30", "30"

THERMAL_FIELDS = [
    "Resource", "Zone", "Model", "New_Build", "Can_Retire", "Existing_Cap_MW",
    "Max_Cap_MW", "Min_Cap_MW", "Inv_Cost_per_MWyr", "Fixed_OM_Cost_per_MWyr",
    "Var_OM_Cost_per_MWh", "Heat_Rate_MMBTU_per_MWh", "Fuel", "Cap_Size",
    "Start_Cost_per_MW", "Start_Fuel_MMBTU_per_MW", "Up_Time", "Down_Time",
    "Ramp_Up_Percentage", "Ramp_Dn_Percentage", "Min_Power", "Reg_Max", "Rsv_Max",
    "Reg_Cost", "Rsv_Cost", "region", "cluster",
]
VRE_FIELDS = [
    "Resource", "Zone", "Num_VRE_Bins", "New_Build", "Can_Retire", "Existing_Cap_MW",
    "Max_Cap_MW", "Min_Cap_MW", "Inv_Cost_per_MWyr", "Fixed_OM_Cost_per_MWyr",
    "Var_OM_Cost_per_MWh", "Reg_Max", "Rsv_Max", "Reg_Cost", "Rsv_Cost", "region", "cluster",
]
STORAGE_FIELDS = [
    "Resource", "Zone", "Model", "New_Build", "Can_Retire", "Existing_Cap_MW",
    "Existing_Cap_MWh", "Max_Cap_MW", "Max_Cap_MWh", "Min_Cap_MW", "Min_Cap_MWh",
    "Inv_Cost_per_MWyr", "Inv_Cost_per_MWhyr", "Fixed_OM_Cost_per_MWyr",
    "Fixed_OM_Cost_per_MWhyr", "Var_OM_Cost_per_MWh", "Var_OM_Cost_per_MWh_In",
    "Self_Disch", "Eff_Up", "Eff_Down", "Min_Duration", "Max_Duration", "Reg_Max",
    "Rsv_Max", "Reg_Cost", "Rsv_Cost", "region", "cluster",
]
HYDRO_FIELDS = [
    "Resource", "Zone", "Hydro_Energy_to_Power_Ratio", "Min_Power",
    "Ramp_Up_Percentage", "Ramp_Dn_Percentage", "Mga", "Resource_Type", "Must_Run",
    "LDS", "Existing_Cap_MW", "Cap_Size", "New_Build", "Can_Retire", "Min_Cap_MW",
    "Max_Cap_MW", "Inv_Cost_per_MWyr", "Fixed_OM_Cost_per_MWyr", "Var_OM_Cost_per_MWh",
    "Heat_Rate_MMBTU_per_MWh", "Fuel", "Reg_Cost", "Rsv_Cost", "Reg_Max", "Rsv_Max",
    "region", "cluster",
]
MULTISTAGE_FIELDS = [
    "Resource", "WACC", "Capital_Recovery_Period", "Lifetime",
    "Min_Retired_Cap_MW", "Min_Retired_Energy_Cap_MW", "Min_Retired_Charge_Cap_MW",
]
CAP_CREDIT_FIELDS = ["Resource", "Derating_Factor_1"]
CAP_RES_FIELDS = ["Region_description", "Network_zones", "CapRes_1"]


def zone_int(node: str) -> int:
    return int(ZONE_MAP[node][1:])


def is_candidate(unit: str) -> bool:
    return "_Invest" in unit


def fmt(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else str(round(value, 6))


def annualized_investment_cost(row: dict[str, str]) -> float:
    if not is_candidate(row["Unit"]):
        return 0.0
    return float(row["FixedInvestmentCost"]) * 1000 * float(row["FixedChargeRate"])


def compute_retirement_schedule(retirement_rows: list[dict[str, str]]) -> dict[str, dict[str, float]]:
    schedule: dict[str, dict[str, float]] = defaultdict(dict)
    for row in retirement_rows:
        year = row["Year"]
        for unit, fraction in row.items():
            if unit == "Year":
                continue
            schedule[unit][year] = float(fraction) if fraction not in (None, "") else 0.0
    return schedule


def min_retired_capacity(schedule: dict[str, dict[str, float]], unit: str, year: str,
                          previous_year: str | None, nameplate: float) -> float:
    if unit not in schedule:
        return 0.0
    current = schedule[unit].get(year, 0.0)
    previous = schedule[unit].get(previous_year, 0.0) if previous_year else 0.0
    return max(current - previous, 0.0) * nameplate


def build_thermal_row(row: dict[str, str], zone: int) -> dict[str, object]:
    unit, node, tech = row["Unit"], row["Node"], row["Technology"]
    candidate = is_candidate(unit)
    fuel = REVERSE_FUEL_MAP.get((node, tech), "None")
    return {
        "Resource": unit,
        "Zone": zone,
        "Model": 2,  # doc section 1: no unit commitment / ramp constraints modeled
        "New_Build": 1 if candidate else 0,
        "Can_Retire": 1,
        "Existing_Cap_MW": "0" if candidate else row["MaximumPower"],
        "Max_Cap_MW": row["MaximumPower"] if candidate else "-1",
        "Min_Cap_MW": "-1",
        "Inv_Cost_per_MWyr": fmt(annualized_investment_cost(row)),
        "Fixed_OM_Cost_per_MWyr": fmt(float(row["OMFixedCost"]) * 1000),
        "Var_OM_Cost_per_MWh": row["OMVariableCost"],
        "Heat_Rate_MMBTU_per_MWh": row["LinearTerm"] or "0",
        "Fuel": fuel,
        "Cap_Size": 1,
        "Start_Cost_per_MW": 0,
        "Start_Fuel_MMBTU_per_MW": 0,
        "Up_Time": 0,
        "Down_Time": 0,
        "Ramp_Up_Percentage": 1,
        "Ramp_Dn_Percentage": 1,
        "Min_Power": 0,
        "Reg_Max": 0,
        "Rsv_Max": 0,
        "Reg_Cost": 0,
        "Rsv_Cost": 0,
        "region": node,
        "cluster": 1,
    }


def build_vre_row(row: dict[str, str], zone: int) -> dict[str, object]:
    unit, node = row["Unit"], row["Node"]
    candidate = is_candidate(unit)
    return {
        "Resource": unit,
        "Zone": zone,
        "Num_VRE_Bins": 1,
        "New_Build": 1 if candidate else 0,
        "Can_Retire": 1,
        "Existing_Cap_MW": "0" if candidate else row["MaximumPower"],
        "Max_Cap_MW": row["MaximumPower"] if candidate else "-1",
        "Min_Cap_MW": "-1",
        "Inv_Cost_per_MWyr": fmt(annualized_investment_cost(row)),
        "Fixed_OM_Cost_per_MWyr": fmt(float(row["OMFixedCost"]) * 1000),
        "Var_OM_Cost_per_MWh": row["OMVariableCost"] or "0",
        "Reg_Max": 0,
        "Rsv_Max": 0,
        "Reg_Cost": 0,
        "Rsv_Cost": 0,
        "region": node,
        "cluster": 1,
    }


def build_storage_row(row: dict[str, str], zone: int) -> dict[str, object]:
    unit, node = row["Unit"], row["Node"]
    candidate = is_candidate(unit)
    max_power = float(row["MaximumPower"])
    max_energy = float(row["MaximumStorage"])
    duration = fmt(max_energy / max_power)
    round_trip_eff = float(row["Efficiency"])
    # PENDING project-lead sign-off: symmetric sqrt() split of the source's
    # single round-trip efficiency into charge/discharge legs.
    leg_eff = fmt(round_trip_eff ** 0.5)
    return {
        "Resource": unit,
        "Zone": zone,
        "Model": 1,  # symmetric charge/discharge, matches the source's single Efficiency value
        "New_Build": 1 if candidate else 0,
        "Can_Retire": 1,
        "Existing_Cap_MW": "0" if candidate else row["MaximumPower"],
        "Existing_Cap_MWh": "0" if candidate else row["MaximumStorage"],
        "Max_Cap_MW": row["MaximumPower"] if candidate else "-1",
        "Max_Cap_MWh": row["MaximumStorage"] if candidate else "-1",
        "Min_Cap_MW": "-1",
        "Min_Cap_MWh": "-1",
        "Inv_Cost_per_MWyr": fmt(annualized_investment_cost(row)),
        # The source gives one $/kW figure and a fixed energy/power ratio per
        # unit (every storage record's MaximumStorage/MaximumPower ratio is
        # constant) rather than separate power/energy costs, so the full
        # annualized cost is carried on power and Min/Max_Duration are locked
        # to that ratio instead of letting GenX size energy independently.
        "Inv_Cost_per_MWhyr": 0,
        "Fixed_OM_Cost_per_MWyr": fmt(float(row["OMFixedCost"]) * 1000),
        "Fixed_OM_Cost_per_MWhyr": 0,
        "Var_OM_Cost_per_MWh": row["OMVariableCost"] or "0",
        "Var_OM_Cost_per_MWh_In": 0,
        "Self_Disch": 0,
        "Eff_Up": leg_eff,
        "Eff_Down": leg_eff,
        "Min_Duration": duration,
        "Max_Duration": duration,
        "Reg_Max": 0,
        "Rsv_Max": 0,
        "Reg_Cost": 0,
        "Rsv_Cost": 0,
        "region": node,
        "cluster": 0,
    }


def build_hydro_row(row: dict[str, str], zone: int) -> dict[str, object]:
    unit, node = row["Unit"], row["Node"]
    return {
        "Resource": unit,
        "Zone": zone,
        # PENDING project-lead sign-off: 0 = pure run-of-river (no reservoir
        # carryover). The source gives no reservoir-size data for hydro
        # (MaximumStorage is blank for every Hydro record) and has no hydro
        # investment candidates.
        "Hydro_Energy_to_Power_Ratio": 0,
        "Min_Power": 0,
        "Ramp_Up_Percentage": 1,
        "Ramp_Dn_Percentage": 1,
        "Mga": 0,
        "Resource_Type": "conventional_hydroelectric",
        "Must_Run": 0,
        "LDS": 0,
        "Existing_Cap_MW": row["MaximumPower"],
        "Cap_Size": 1,
        "New_Build": 0,
        "Can_Retire": 1,
        "Min_Cap_MW": "-1",
        "Max_Cap_MW": "-1",
        "Inv_Cost_per_MWyr": 0,
        "Fixed_OM_Cost_per_MWyr": fmt(float(row["OMFixedCost"]) * 1000),
        "Var_OM_Cost_per_MWh": row["OMVariableCost"] or "0",
        "Heat_Rate_MMBTU_per_MWh": 0,
        "Fuel": "None",
        "Reg_Cost": 0,
        "Rsv_Cost": 0,
        "Reg_Max": 0,
        "Rsv_Max": 0,
        "region": node,
        "cluster": 1,
    }


def build_multistage_row(resource: str, min_retired_cap: float,
                          min_retired_energy: float = 0.0, min_retired_charge: float = 0.0) -> dict[str, object]:
    return {
        "Resource": resource,
        "WACC": WACC,
        "Capital_Recovery_Period": CAPITAL_RECOVERY_PERIOD,
        "Lifetime": LIFETIME,
        "Min_Retired_Cap_MW": fmt(min_retired_cap),
        "Min_Retired_Energy_Cap_MW": fmt(min_retired_energy),
        "Min_Retired_Charge_Cap_MW": fmt(min_retired_charge),
    }


def main() -> int:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs-root", type=Path, default=root,
                         help="GenX inputs directory; defaults to this script's directory")
    parser.add_argument("--source", type=Path,
                         help="Project-manager data directory; defaults to WECC-9n test system/data below inputs-root")
    parser.add_argument("--dry-run", action="store_true",
                         help="Validate the delivery without writing any files")
    args = parser.parse_args()
    inputs_root = args.inputs_root.resolve()
    source = (args.source or inputs_root / "WECC-9n test system" / "data").resolve()
    require(source.is_dir(), f"Source directory does not exist: {source}")

    generation_fields, generation_rows = read_csv(source / "Generation.csv")
    _, retirement_rows = read_csv(source / "Retirements.csv")
    _, area_rows = read_csv(source / "AreaConstraints.csv")

    required_generation_fields = (
        "Unit", "Node", "Technology", "MaximumPower", "MaximumStorage", "Efficiency",
        "OMVariableCost", "OMFixedCost", "LinearTerm", "CapacityCredit",
        "FixedInvestmentCost", "FixedChargeRate",
    )
    for field in required_generation_fields:
        require(field in generation_fields, f"Generation.csv is missing {field}")
    require("Year" in area_rows[0] and "Area" in area_rows[0] and "ReserveMargin" in area_rows[0],
            "AreaConstraints.csv is missing Year/Area/ReserveMargin")

    all_techs = {row["Technology"] for row in generation_rows}
    known_techs = THERMAL_TECHS | VRE_TECHS | STORAGE_TECHS | HYDRO_TECHS
    require(all_techs <= known_techs, f"Generation.csv has unmapped technologies: {all_techs - known_techs}")
    require(all(row["Node"] in ZONE_MAP for row in generation_rows), "Generation.csv has a Node outside ZONE_MAP")

    schedule = compute_retirement_schedule(retirement_rows)
    nameplate_mw = {row["Unit"]: float(row["MaximumPower"]) for row in generation_rows}
    nameplate_mwh = {row["Unit"]: float(row["MaximumStorage"]) for row in generation_rows
                      if row["MaximumStorage"] not in (None, "")}
    area_reserve = {(row["Year"], row["Area"]): float(row["ReserveMargin"]) for row in area_rows}

    if args.dry_run:
        print(f"Validated source delivery: {source}")
        print("No files were changed.")
        return 0

    for stage_index, (stage, year) in enumerate(STAGES):
        previous_year = STAGES[stage_index - 1][1] if stage_index > 0 else None
        stage_dir = inputs_root / f"inputs_p{stage}"
        resources_dir = stage_dir / "resources"
        policy_assignments_dir = resources_dir / "policy_assignments"
        policy_assignments_dir.mkdir(exist_ok=True)
        require((stage_dir / "policies").is_dir(), f"Missing directory: {stage_dir / 'policies'}")
        require((stage_dir / "system").is_dir(), f"Missing directory: {stage_dir / 'system'}")

        thermal_rows, vre_rows, storage_rows, hydro_rows = [], [], [], []
        multistage_rows, credit_rows = [], []

        for row in generation_rows:
            unit, node, tech = row["Unit"], row["Node"], row["Technology"]
            zone = zone_int(node)

            if tech in THERMAL_TECHS:
                thermal_rows.append(build_thermal_row(row, zone))
                min_retired = min_retired_capacity(schedule, unit, year, previous_year, nameplate_mw[unit])
                multistage_rows.append(build_multistage_row(unit, min_retired))
            elif tech in VRE_TECHS:
                vre_rows.append(build_vre_row(row, zone))
                min_retired = min_retired_capacity(schedule, unit, year, previous_year, nameplate_mw[unit])
                multistage_rows.append(build_multistage_row(unit, min_retired))
            elif tech in STORAGE_TECHS:
                storage_rows.append(build_storage_row(row, zone))
                min_retired_power = min_retired_capacity(schedule, unit, year, previous_year, nameplate_mw[unit])
                min_retired_energy = min_retired_capacity(
                    schedule, unit, year, previous_year, nameplate_mwh.get(unit, nameplate_mw[unit] * 4))
                multistage_rows.append(build_multistage_row(unit, min_retired_power, min_retired_energy))
            elif tech in HYDRO_TECHS:
                hydro_rows.append(build_hydro_row(row, zone))
                min_retired = min_retired_capacity(schedule, unit, year, previous_year, nameplate_mw[unit])
                multistage_rows.append(build_multistage_row(unit, min_retired))

            credit_rows.append({"Resource": unit, "Derating_Factor_1": row["CapacityCredit"]})

        write_csv_atomic(resources_dir / "Thermal.csv", THERMAL_FIELDS, thermal_rows)
        write_csv_atomic(resources_dir / "Vre.csv", VRE_FIELDS, vre_rows)
        write_csv_atomic(resources_dir / "Storage.csv", STORAGE_FIELDS, storage_rows)
        write_csv_atomic(resources_dir / "Hydro.csv", HYDRO_FIELDS, hydro_rows)
        write_csv_atomic(resources_dir / "Resource_multistage_data.csv", MULTISTAGE_FIELDS, multistage_rows)
        write_csv_atomic(policy_assignments_dir / "Resource_capacity_reserve_margin.csv",
                          CAP_CREDIT_FIELDS, credit_rows)

        cap_res_rows = [
            {
                "Region_description": node,
                "Network_zones": ZONE_MAP[node],
                "CapRes_1": fmt(area_reserve[(year, NODE_AREA[node])] - 1),
            }
            for node in ZONE_MAP
        ]
        write_csv_atomic(stage_dir / "policies" / "Capacity_reserve_margin.csv", CAP_RES_FIELDS, cap_res_rows)

        print(f"Wrote resource inputs for p{stage} ({year}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
