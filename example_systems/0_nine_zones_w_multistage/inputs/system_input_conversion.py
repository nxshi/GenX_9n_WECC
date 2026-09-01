#!/usr/bin/env python3
"""Replace GenX system inputs from a project-manager WECC delivery.

The converter writes exactly four files in each existing inputs_p1…inputs_p5
system directory.  It uses the p1 system files as the GenX default template for
fields that are absent from the project-manager data.
"""
from __future__ import annotations

import argparse
import csv
import os
import tempfile
from collections import defaultdict
from pathlib import Path


STAGES = ((1, "2025"), (2, "2030"), (3, "2035"), (4, "2040"), (5, "2045"))
ZONE_MAP = {
    "Central": "z1", "IID": "z2", "LADWP": "z3", "NCNC": "z4", "North": "z5",
    "PGE": "z6", "SCE": "z7", "SDGE": "z8", "South": "z9",
}
FUEL_MAP = {
    "biomass_north": ("North", "Biomass"), "biomass_pge": ("PGE", "Biomass"), "biomass_sce": ("SCE", "Biomass"),
    "coal_central": ("Central", "Coal"), "coal_south": ("South", "Coal"),
    "ngcc_central": ("Central", "NGCC"), "ngcc_iid": ("IID", "NGCC"), "ngcc_ladwp": ("LADWP", "NGCC"),
    "ngcc_ncnc": ("NCNC", "NGCC"), "ngcc_north": ("North", "NGCC"), "ngcc_pge": ("PGE", "NGCC"),
    "ngcc_sce": ("SCE", "NGCC"), "ngcc_sdge": ("SDGE", "NGCC"), "ngcc_south": ("South", "NGCC"),
    "nuclear_north": ("North", "Nuclear"), "nuclear_pge": ("PGE", "Nuclear"), "nuclear_south": ("South", "Nuclear"),
    "peaker_central": ("Central", "Peaker"), "peaker_iid": ("IID", "Peaker"), "peaker_ladwp": ("LADWP", "Peaker"),
    "peaker_ncnc": ("NCNC", "Peaker"), "peaker_north": ("North", "Peaker"), "peaker_pge": ("PGE", "Peaker"),
    "peaker_sce": ("SCE", "Peaker"), "peaker_sdge": ("SDGE", "Peaker"), "peaker_south": ("South", "Peaker"),
    "ng_ccs_central": ("Central", "NG-CCS"), "ng_ccs_north": ("North", "NG-CCS"),
    "ng_ccs_pge": ("PGE", "NG-CCS"), "ng_ccs_sce": ("SCE", "NG-CCS"),
    "ng_ccs_sdge": ("SDGE", "NG-CCS"), "ng_ccs_south": ("South", "NG-CCS"),
}
EMISSION_OVERRIDES = {"ng_ccs_central": "0.00265"}
SYSTEM_FILES = ("Demand_data.csv", "Generators_variability.csv", "Fuels_data.csv", "Network.csv")


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        return reader.fieldnames or [], list(reader)


def write_csv_atomic(path: Path, fields: list[str], rows: list[dict[str, object]]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=fields, extrasaction="raise")
            writer.writeheader()
            writer.writerows(rows)
        Path(temporary_name).replace(path)
    except Exception:
        Path(temporary_name).unlink(missing_ok=True)
        raise


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_outputs(inputs_root: Path, demand_by_year: dict, availability_by_year: dict,
                   network_rows: list[dict[str, str]], parameter: dict[str, str],
                   demand_header: list[str], variability_header: list[str],
                   fuel_header: list[str], network_header: list[str],
                   demand_template: list[dict[str, str]], fuel_values: dict[str, tuple[str, str]]) -> None:
    """Reconcile every converted system value against its PM source or approved default."""
    failures: list[str] = []

    def check(condition: bool, message: str) -> bool:
        if not condition:
            failures.append(message)
        return condition

    default_demand_fields = (
        "Demand_Segment", "Cost_of_Demand_Curtailment_per_MW", "Max_Demand_Curtailment",
        "Rep_Periods", "Timesteps_per_Rep_Period", "Sub_Weights",
    )
    for stage, year in STAGES:
        system = inputs_root / f"inputs_p{stage}" / "system"
        demand_fields, demand_out = read_csv(system / "Demand_data.csv")
        availability_fields, availability_out = read_csv(system / "Generators_variability.csv")
        fuel_fields, fuel_out = read_csv(system / "Fuels_data.csv")
        network_fields, network_out = read_csv(system / "Network.csv")
        check(demand_fields == demand_header and len(demand_out) == 8760, f"p{stage} Demand_data.csv schema or row count differs")
        check(availability_fields == variability_header and len(availability_out) == 8760, f"p{stage} Generators_variability.csv schema or row count differs")
        check(fuel_fields == fuel_header and len(fuel_out) == 8761, f"p{stage} Fuels_data.csv schema or row count differs")
        check(network_fields == network_header and len(network_out) == 17, f"p{stage} Network.csv schema or row count differs")
        if failures:
            continue

        for index, (source_row, output_row) in enumerate(zip(demand_by_year[year], demand_out), start=1):
            if not check(output_row["Time_Index"] == str(index), f"p{stage} demand Time_Index mismatch at row {index}"):
                break
            for node, zone in ZONE_MAP.items():
                if not check(output_row[f"Demand_MW_{zone}"] == source_row[node], f"p{stage} demand mismatch: {node}, hour {index}"):
                    break
            else:
                continue
            break
        check(demand_out[0]["Voll"] == parameter["ENSCost"] and demand_out[0]["$/MWh"] == parameter["ENSCost"], f"p{stage} load-shedding cost mismatch")
        for field in default_demand_fields:
            check(demand_out[0][field] == demand_template[0][field], f"p{stage} demand default mismatch: {field}")

        for index, (source_row, output_row) in enumerate(zip(availability_by_year[year], availability_out), start=1):
            if not check(output_row["Time_Index"] == str(index), f"p{stage} availability Time_Index mismatch at row {index}"):
                break
            if any(output_row[field] != source_row[field] for field in variability_header if field != "Time_Index"):
                check(False, f"p{stage} availability mismatch at hour {index}")
                break

        emissions_row, prices_row = fuel_out[0], fuel_out[1]
        check(emissions_row["Time_Index"] == "0", f"p{stage} fuel emissions row lacks Time_Index 0")
        check(prices_row["Time_Index"] == "1", f"p{stage} fuel price row lacks Time_Index 1")
        for fuel in fuel_header[1:]:
            expected_emissions, expected_price = fuel_values[fuel]
            check(emissions_row[fuel] == expected_emissions, f"p{stage} fuel-emission mismatch: {fuel}")
            check(prices_row[fuel] == expected_price, f"p{stage} fuel-price mismatch: {fuel}")
        for index, output_row in enumerate(fuel_out[2:], start=2):
            if not check(output_row["Time_Index"] == str(index), f"p{stage} fuel Time_Index mismatch at row {index}"):
                break
            if any(output_row[fuel] != prices_row[fuel] for fuel in fuel_header[1:]):
                check(False, f"p{stage} hourly fuel-price mismatch at row {index}")
                break

        for index, (source_row, output_row) in enumerate(zip(network_rows, network_out), start=1):
            expected = {
                "Network_Lines": str(index),
                "Start_Zone": str(int(ZONE_MAP[source_row["NodeFrom"]][1:])),
                "End_Zone": str(int(ZONE_MAP[source_row["NodeTo"]][1:])),
                "Line_Max_Flow_MW": source_row["TTC"],
                "transmission_path_name": f'{source_row["NodeFrom"]}_to_{source_row["NodeTo"]}',
                "distance_mile": source_row["Length"],
                "Line_Loss_Percentage": source_row["LossFactor"],
                "DerateCapRes_1": source_row["SecurityFactor"],
                "Line_Max_Flow_Possible_MW": source_row["TTC"],
            }
            for field, value in expected.items():
                if not check(output_row[field] == value, f"p{stage} network mismatch: line {index}, {field}"):
                    break
    if failures:
        raise ValueError("Verification failed:\n- " + "\n- ".join(failures))
    print("Verification passed: all five system-input sets reconcile with the PM delivery and approved defaults.")


def main() -> int:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs-root", type=Path, default=root, help="GenX inputs directory; defaults to this script's directory")
    parser.add_argument("--source", type=Path, help="Project-manager data directory; defaults to WECC-9n test system/data below inputs-root")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Validate the delivery without replacing any files")
    mode.add_argument("--verify", action="store_true", help="Reconcile existing system inputs against the PM delivery without replacing files")
    args = parser.parse_args()
    inputs_root = args.inputs_root.resolve()
    source = (args.source or inputs_root / "WECC-9n test system" / "data").resolve()
    template_system = inputs_root / "inputs_p1" / "system"
    require(source.is_dir(), f"Source directory does not exist: {source}")
    require(template_system.is_dir(), f"Template system directory does not exist: {template_system}")

    source_tables = {name: read_csv(source / name) for name in ("Demand.csv", "AvailabilityFactor.csv", "Generation.csv", "Network.csv", "Parameter.csv")}
    templates = {name: read_csv(template_system / name) for name in SYSTEM_FILES}
    for stage, _ in STAGES:
        directory = inputs_root / f"inputs_p{stage}" / "system"
        require(directory.is_dir(), f"Missing target directory: {directory}")
        for name in SYSTEM_FILES:
            fields, _ = read_csv(directory / name)
            require(fields == templates[name][0], f"{directory / name} has different columns from the p1 template")

    demand_fields, demand_rows = source_tables["Demand.csv"]
    availability_fields, availability_rows = source_tables["AvailabilityFactor.csv"]
    generation_fields, generation_rows = source_tables["Generation.csv"]
    network_fields, network_rows = source_tables["Network.csv"]
    parameter_fields, parameter_rows = source_tables["Parameter.csv"]
    require("ENSCost" in parameter_fields and len(parameter_rows) == 1, "Parameter.csv must contain exactly one ENSCost value")
    require(len(network_rows) == 17, "Network.csv must contain exactly 17 lines")
    for required in ("Year", *ZONE_MAP):
        require(required in demand_fields, f"Demand.csv is missing {required}")
    for required in ("Year", "LoadLevel"):
        require(required in availability_fields, f"AvailabilityFactor.csv is missing {required}")
    for required in ("Node", "Technology", "FuelCost", "CO2EmissionRate"):
        require(required in generation_fields, f"Generation.csv is missing {required}")
    for required in ("NodeFrom", "NodeTo", "TTC", "Length", "LossFactor", "SecurityFactor"):
        require(required in network_fields, f"Network.csv is missing {required}")

    demand_by_year, availability_by_year = defaultdict(list), defaultdict(list)
    for row in demand_rows:
        demand_by_year[row["Year"]].append(row)
    for row in availability_rows:
        availability_by_year[row["Year"]].append(row)
    for _, year in STAGES:
        require(len(demand_by_year[year]) == 8760, f"Demand.csv {year} must have 8,760 rows")
        require(len(availability_by_year[year]) == 8760, f"AvailabilityFactor.csv {year} must have 8,760 rows")

    demand_header, demand_template = templates["Demand_data.csv"]
    variability_header, _ = templates["Generators_variability.csv"]
    fuel_header, fuel_template = templates["Fuels_data.csv"]
    network_header, network_template = templates["Network.csv"]
    require(all(f"Demand_MW_{zone}" in demand_header for zone in ZONE_MAP.values()), "Demand template does not match the nine-zone map")
    require(all(name in availability_fields for name in variability_header if name != "Time_Index"), "Availability source is missing a GenX resource column")
    require(len(fuel_template) >= 2, "Fuel template must include emission and price rows")

    fuels_by_key = defaultdict(list)
    for row in generation_rows:
        fuels_by_key[(row["Node"], row["Technology"])].append(row)
    fuel_values = {"None": ("0", "0")}
    for fuel in fuel_header[1:]:
        if fuel == "None":
            continue
        key = FUEL_MAP.get(fuel)
        require(key is not None and fuels_by_key[key], f"No Generation.csv mapping for fuel {fuel}")
        records = fuels_by_key[key]
        costs = {record["FuelCost"] for record in records}
        emissions = {record["CO2EmissionRate"] for record in records}
        require(len(costs) == 1 and "" not in costs, f"FuelCost is missing/ambiguous for {fuel}")
        if len(emissions) != 1 or "" in emissions:
            emissions = {EMISSION_OVERRIDES.get(fuel, fuel_template[0][fuel])}  # Explicit overrides take precedence over the GenX default.
        fuel_values[fuel] = (next(iter(emissions)), next(iter(costs)))

    if args.dry_run:
        print(f"Validated source delivery: {source}")
        print("No files were changed.")
        return 0
    if args.verify:
        verify_outputs(inputs_root, demand_by_year, availability_by_year, network_rows,
                       parameter_rows[0], demand_header, variability_header, fuel_header,
                       network_header, demand_template, fuel_values)
        return 0

    ens_cost = parameter_rows[0]["ENSCost"]
    for stage, year in STAGES:
        system = inputs_root / f"inputs_p{stage}" / "system"
        demand_out = []
        for index, source_row in enumerate(demand_by_year[year], start=1):
            row = {field: "" for field in demand_header}
            row["Time_Index"] = index
            for node, zone in ZONE_MAP.items():
                row[f"Demand_MW_{zone}"] = source_row[node]
            if index == 1:
                for field in ("Demand_Segment", "Cost_of_Demand_Curtailment_per_MW", "Max_Demand_Curtailment", "Rep_Periods", "Timesteps_per_Rep_Period", "Sub_Weights"):
                    row[field] = demand_template[0][field]
                row["Voll"] = ens_cost
                row["$/MWh"] = ens_cost
            demand_out.append(row)
        write_csv_atomic(system / "Demand_data.csv", demand_header, demand_out)

        availability_out = []
        for index, source_row in enumerate(availability_by_year[year], start=1):
            row = {"Time_Index": index}
            row.update({field: source_row[field] for field in variability_header if field != "Time_Index"})
            availability_out.append(row)
        write_csv_atomic(system / "Generators_variability.csv", variability_header, availability_out)

        emissions_row, prices_row = {"Time_Index": 0}, {"Time_Index": 1}
        for fuel in fuel_header[1:]:
            emissions_row[fuel], prices_row[fuel] = fuel_values[fuel]
        fuel_out = [emissions_row, prices_row]
        fuel_out.extend({"Time_Index": index, **{fuel: prices_row[fuel] for fuel in fuel_header[1:]}} for index in range(2, 8761))
        write_csv_atomic(system / "Fuels_data.csv", fuel_header, fuel_out)

        network_out = []
        for index, source_row in enumerate(network_rows, start=1):
            row = dict(network_template[index - 1])
            if index <= len(ZONE_MAP):
                node = list(ZONE_MAP)[index - 1]
                row[network_header[0]], row["Network_zones"] = node, ZONE_MAP[node]
            row.update({
                "Network_Lines": index,
                "Start_Zone": int(ZONE_MAP[source_row["NodeFrom"]][1:]),
                "End_Zone": int(ZONE_MAP[source_row["NodeTo"]][1:]),
                "Line_Max_Flow_MW": source_row["TTC"],
                "transmission_path_name": f'{source_row["NodeFrom"]}_to_{source_row["NodeTo"]}',
                "distance_mile": source_row["Length"],
                "Line_Loss_Percentage": source_row["LossFactor"],
                "DerateCapRes_1": source_row["SecurityFactor"],
                "Line_Max_Flow_Possible_MW": source_row["TTC"],
            })
            network_out.append(row)
        write_csv_atomic(system / "Network.csv", network_header, network_out)
        print(f"Replaced system inputs for p{stage} ({year}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
