# WECC 9-Zone Multi-Stage Case

This case is a stylized, aggregated WECC capacity-expansion model built around
nine zones and five planning years: 2025, 2030, 2035, 2040, and 2045. The
project-manager delivery provides full-year hourly demand and availability,
aggregated generation data, and a 17-line transport network.

The intended five model-input periods are:

| Input folder | Planning year |
|---|---:|
| `inputs/inputs_p1` | 2025 |
| `inputs/inputs_p2` | 2030 |
| `inputs/inputs_p3` | 2035 |
| `inputs/inputs_p4` | 2040 |
| `inputs/inputs_p5` | 2045 |

## Inputs

The project-manager source delivery is in
`inputs/WECC-9n test system/`. Its [data documentation](inputs/WECC-9n%20test%20system/documentation/DATA_DOCUMENTATION.md)
describes the nine-zone test system and source assumptions.

At present, the source data has been converted only for the four `system`
tables in each planning-period folder:

- `Demand_data.csv`
- `Generators_variability.csv`
- `Fuels_data.csv`
- `Network.csv`

The reusable converter, its validation mode, direct mappings, and documented
GenX-default assumptions are described in
[inputs/SYSTEM_INPUT_CONVERSION.md](inputs/SYSTEM_INPUT_CONVERSION.md).
Resource and policy table conversion remains separate work.

## Running the case

Run from this case directory:

```bash
julia Run.jl
```

Before running, review the settings files—especially the multi-stage and
time-domain-reduction settings—so they reflect the intended five-period,
nine-zone study. The current settings are retained separately and are not
changed by the system-input converter.

Model results are written to the case results directory.
