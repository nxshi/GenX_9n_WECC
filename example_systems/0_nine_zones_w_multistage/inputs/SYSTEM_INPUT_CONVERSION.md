# System Input Conversion

This note covers only the four `system` tables. Case scope, planning years,
and source-data location are documented in the parent [README](../README.md).

## Converter

Run `python3 system_input_conversion.py` from this `inputs` folder. It validates
the delivery before replacing these files in each existing `system` folder:

- `Demand_data.csv`: maps yearly hourly node demand to `Demand_MW_z1` through
  `Demand_MW_z9`; maps `Parameter.csv.ENSCost` to `Voll` and `$/MWh`.
- `Generators_variability.csv`: maps the yearly hourly availability columns by
  matching resource name.
- `Fuels_data.csv`: maps `Generation.csv` fuel cost and CO2 rate by
  node/technology and preserves GenX's emission row plus hourly price layout.
- `Network.csv`: maps line endpoints, TTC, length, loss factor, and security
  factor into GenX's nine-zone network representation.

For a future delivery in the same format, use
`python3 system_input_conversion.py --source /path/to/data`. Use `--dry-run` to
validate a delivery without changing inputs, and `--verify` after conversion
to reconcile every converted value against the delivery and approved defaults.
Writes are atomic per CSV; no duplicate staged copies or backups are created.

## When GenX defaults are used

The provided data does not supply the following GenX fields, so the
script retains the values already in `inputs_p1/system` and applies them to all
five stages:

- Demand metadata: `Demand_Segment=1`,
  `Cost_of_Demand_Curtailment_per_MW=1`, `Max_Demand_Curtailment=1`,
  `Rep_Periods=1`, `Timesteps_per_Rep_Period=8760`, and `Sub_Weights=8760`.
- Fuel CO2 intensity: the delivery leaves biomass, nuclear, and Central
  NG-CCS blank. GenX defaults of `0 tonnes/MMBtu` are retained for
  `biomass_north`, `biomass_pge`, `biomass_sce`, `nuclear_north`,
  `nuclear_pge`, and `nuclear_south`. `ng_ccs_central` is explicitly set to
  `0.00265 tonnes/MMBtu` to match the other five NG-CCS candidates.
- Network: for all 17 lines the retained defaults are
  `Line_Max_Reinforcement_MW=-1`,
  `Line_Reinforcement_Cost_per_MWyr=0`, `CapRes_Excl_1=0`, `WACC=0.07`, and
  `Capital_Recovery_Period=30`.

All other populated values in these four tables come directly from the
provided inputs. The script uses the p1 system files as the default
template, so intentional future changes to GenX defaults are preserved on the
next conversion.
