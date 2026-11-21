@doc raw"""
	cap_reserve_margin!(EP::Model, inputs::Dict, setup::Dict)
Instead of modeling capacity reserve margin requirement (a.k.a. capacity market or resource adequacy requirement) using an annual constraint,
we model each requirement with hourly constraint by simulating the activation of the capacity obligation.
We define capacity reserve margin constraint for subsets of zones,
$z \in \mathcal{Z}^{CRM}_{p}$, and each subset stands for a
locational deliverability area (LDA) or a reserve sharing group.
For thermal resources, the available capacity is the total capacity in the LDA derated by
the outage rate, $\epsilon_{y,z,p}^{CRM}$.
For variable renewable energy ($y \in \mathcal{VRE}$), the available capacity is the
maximum discharge potential in time step $t$ derated by the derating factor.
For standalone storage and co-located VRE and storage resources
($y \in \mathcal{O} \cup \mathcal{VS}$) the available capacity is the net injection
into the transmission network plus the net virtual injection corresponding to charge held
in reserve, derated by the derating factor.
For information on how each component contributes to the capacity reserve margin formulation for co-located VRE and storage resources, see [`vre_stor_capres!()`](@ref).
For flexible demand resources ($y \in \mathcal{DF}$), the available capacity is the net
injection into the transmission network in time step $t$ derated by the derating factor,
also stored in the parameter, $\epsilon_{y,z,p}^{CRM}$.
If the imported capacity is eligible to provide capacity to the CRM constraint,
the inbound powerflow on all lines $\mathcal{L}_{p}^{in}$ in time step $t$ will be derated
to form the available capacity from outside of the LDA.
The reverse is true as well: the outbound derated powerflow on all lines
$\mathcal{L}_{p}^{out}$ in time step $t$ is taken out from the total available capacity.
The derating factor should be equal to the expected availability of the resource during
periods when the capacity reserve constraint is binding (e.g. accounting for forced outages
during supply constrained periods) and is similar to derating factors used in the capacity
markets.
On top of the flexible demand resources, demand curtailment can also provide capacity
(i.e., demand response or load management).
We allow all segments of voluntary demand curtailment, $s \geq 2 \in S$,
to contribute to capacity requirements.
The first segment $s = 1 \in S$ corresponds to involuntary demand curtailment or
emergency load shedding at the price cap or value of lost demand, and thus does not contribute to reserve requirements.
Note that the time step-weighted sum of the shadow prices of this constraint corresponds
to the capacity market payments reported by ISOs with mandate capacity market mechanism.
```math
\begin{aligned}
	& \sum_{z  \in \mathcal{Z}^{CRM}_{p}} \Big( \sum_{y \in \mathcal{H}} \epsilon_{y,z,p}^{CRM} \times \Delta^{\text{total}}_{y,z} + \sum_{y \in \mathcal{VRE}} \epsilon_{y,z,p}^{CRM} \times \rho^{max}_{y,z,t} \\
	& + \sum_{y \in \mathcal{O}} \epsilon_{y,z,p}^{CRM} \times \left(\Theta_{y,z,t} + \Theta^{CRM}_{o,z,t} - \Pi^{CRM}_{o,z,t} - \Pi_{y,z,t} \right) + \sum_{y \in \mathcal{DF}} \epsilon_{y,z,p}^{CRM} \times \left(\Pi_{y,z,t} - \Theta_{y,z,t} \right) \\
	& + \sum_{y \in \mathcal{VS}^{pv}} (\epsilon_{y,z,p}^{CRM} \times \eta^{inverter}_{y,z} \times \rho^{max,pv}_{y,z,t} \times \Delta^{total,pv}_{y,z}) \\
	& + \sum_{y \in \mathcal{VS}^{wind}} (\epsilon_{y,z,p}^{CRM} \times \rho^{max,wind}_{y,z,t} \times \Delta^{total,wind}_{y,z}) \\
    & + \sum_{y \in \mathcal{VS}^{sym,dc} \cup \mathcal{VS}^{asym,dc,dis}} (\epsilon_{y,z,p}^{CRM} \times \eta^{inverter}_{y,z} \times (\Theta^{dc}_{y,z,t} + \Theta^{CRM,dc}_{y,z,t})) \\
    & + \sum_{y \in \mathcal{VS}^{sym,ac} \cup \mathcal{VS}^{asym,ac,dis}} (\epsilon_{y,z,p}^{CRM} \times (\Theta^{ac}_{y,z,t} + \Theta^{CRM,ac}_{y,z,t})) \\
    & - \sum_{y \in \mathcal{VS}^{sym,dc} \cup \mathcal{VS}^{asym,dc,cha}} (\epsilon_{y,z,p}^{CRM} \times \frac{\Pi^{dc}_{y,z,t} + \Pi^{CRM,dc}_{y,z,t}}{\eta^{inverter}_{y,z}}) \\
    & - \sum_{y \in \mathcal{VS}^{sym,dc} \cup \mathcal{VS}^{asym,dc,cha}} (\epsilon_{y,z,p}^{CRM} \times (\Pi^{ac}_{y,z,t} + \Pi^{CRM,ac}_{y,z,t})) \\
	& + \sum_{l \in \mathcal{L}_{p}^{in}} \epsilon_{y,z,p}^{CRM} \times \Phi_{l,t} -  \sum_{l \in \mathcal{L}_{p}^{out}} \epsilon_{y,z,p}^{CRM} \times \Phi_{l,t}
   	+  \sum_{s \geq 2} \Lambda_{s,t,z}  \Big) \\
   	& \geq \sum_{z  \in \mathcal{Z}^{CRM}_{p}} \left( \left(1 + RM_{z,p}^{CRM} \right) \times D_{z,t} \right)  \hspace{1 cm}  \forall t \in \mathcal{T}, \forall p\in \mathcal{P}^{CRM}
\end{aligned}
```
Note that multiple capacity reserve margin requirements can be specified covering different
individual zones or aggregations of zones; the number of requirements is the number of
`CapRes_*` columns in `Capacity_reserve_margin.csv`.
This hourly formulation is used when the GenX setting ```CapacityReserveMargin``` is 1;
setting it to 2 selects the annual formulation instead (see [`cap_reserve_margin_annual!`](@ref)).
The expressions establishing the capacity reserve margin contributions of each technology
class are included in their respective technology modules.
"""
function cap_reserve_margin!(EP::Model, inputs::Dict, setup::Dict)
    # capacity reserve margin constraint
    T = inputs["T"]
    NCRM = inputs["NCapacityReserveMargin"]
    println("Capacity Reserve Margin Policies Module")

    # if input files are present, add capacity reserve margin slack variables
    if haskey(inputs, "dfCapRes_slack")
        @variable(EP, vCapResSlack[res = 1:NCRM, t = 1:T]>=0)
        add_similar_to_expression!(EP[:eCapResMarBalance], vCapResSlack)

        @expression(EP,
            eCapResSlack_Year[res = 1:NCRM],
            sum(EP[:vCapResSlack][res, t] * inputs["omega"][t] for t in 1:T))
        @expression(EP,
            eCCapResSlack[res = 1:NCRM],
            inputs["dfCapRes_slack"][res, :PriceCap]*EP[:eCapResSlack_Year][res])
        @expression(EP, eCTotalCapResSlack, sum(EP[:eCCapResSlack][res] for res in 1:NCRM))
        add_to_expression!(EP[:eObj], eCTotalCapResSlack)
    end

    @constraint(EP,
        cCapacityResMargin[res = 1:NCRM, t = 1:T],
        EP[:eCapResMarBalance][res, t]
        >= sum(inputs["pD"][t, z] * (1 + inputs["dfCapRes"][z, res])
        for z in findall(x -> x != 0, inputs["dfCapRes"][:, res])))
end

@doc raw"""
	cap_reserve_margin_annual!(EP::Model, inputs::Dict, setup::Dict)

Annual (static) capacity reserve margin, used when the GenX setting `CapacityReserveMargin` is 2.
Unlike the hourly formulation of [`cap_reserve_margin!`](@ref), each requirement
$p \in \mathcal{P}^{CRM}$ is a single constraint that compares accredited installed capacity with the
coincident peak demand of the zones $z \in \mathcal{Z}^{CRM}_{p}$ it covers (a planning reserve margin):

```math
\begin{aligned}
	& \sum_{y \in \mathcal{G} \setminus \mathcal{EL}} \epsilon^{CRM,annual}_{y,p} \times \Delta^{\text{total}}_{y}
	- \sum_{y \in \mathcal{EL}} \left(1 + RM^{CRM}_{z(y),p}\right) \times \epsilon^{CRM,annual}_{y,p} \times \Delta^{\text{total}}_{y} \\
	& + \sum_{l \in \mathcal{L}_{p}^{in}} \epsilon^{CRM}_{l,p} \times \Phi^{CRM}_{l} - \sum_{l \in \mathcal{L}_{p}^{out}} \epsilon^{CRM}_{l,p} \times \Phi^{CRM}_{l} \\
	& \geq \max_{t \in \mathcal{T}} \sum_{z \in \mathcal{Z}^{CRM}_{p}} \left(1 + RM^{CRM}_{z,p}\right) \times D_{z,t}
	\hspace{1 cm} \forall p \in \mathcal{P}^{CRM}
\end{aligned}
```

With equal margins $RM^{CRM}_{z,p}$ across zones, the right-hand side is $(1 + RM_{p})$ times the
coincident peak demand, i.e. the highest total demand of the zones at the same time step.

**Accreditation.** $\epsilon^{CRM,annual}_{y,p}$ is read from the `Annual_Derating_Factor_*` columns of
`Resource_capacity_reserve_margin.csv`. It multiplies installed capacity directly, so it must represent
the full capacity credit of the resource (e.g., ELCC or UCAP fraction), including the coincidence of
variable renewable output with the peak and the duration limits of energy-limited resources. It is
therefore different from the `Derating_Factor_*` columns used by the hourly formulation, which are
multiplied by hourly availability or dispatch. Notes on specific resources:
- Storage, hydro and flexible demand are credited on their (discharge) power capacity. Charging is not
  subtracted, since a resource cannot charge and discharge at full power at the peak.
- Co-located VRE and storage resources are credited on their grid connection capacity.
- Allam cycle resources are credited on their net output capacity (sCO2 turbine capacity minus the
  power used by the air separation unit), as in the minimum capacity requirement.
- Fusion and thermal maintenance adjustments of the hourly formulation are not applied; the
  accreditation factor should be net of recirculating power and planned outages.

**Electrolyzers** ($y \in \mathcal{EL}$) are treated as firm consumption at the peak: their capacity,
scaled by $\epsilon^{CRM,annual}_{y,p}$ (the expected coincident consumption share), increases the
requirement and is subject to the same reserve margin as demand.

**Transmission.** A requirement covering only part of the system can rely on firm capacity located
outside of it. For every line $l$ eligible for at least one requirement (non-zero `CapRes_Excl_*` in
`Network.csv`), a peak transfer variable $\Phi^{CRM}_{l}$ is defined: the firm capacity delivered
over the line at the time of the peak, positive in the line direction (from `Start_Zone` to
`End_Zone`). It is not an hourly flow and has no cost; it is only bounded by the line capacity,
$-\varphi^{cap}_{l} \leq \Phi^{CRM}_{l} \leq \varphi^{cap}_{l}$, which can be expanded. The sign
convention and the derating factors $\epsilon^{CRM}_{l,p}$ (`DerateCapRes_*`) are the same as in the
hourly formulation. Because the same transfer enters every requirement, capacity imported into one
region is exported from the other and cannot be counted twice. Note that the zone exporting capacity
is only required to have surplus firm capacity if it is itself covered by a requirement (e.g., a
system-wide one).

**Demand curtailment** (non-served energy) does not contribute to the annual requirement. To account
for demand response, reduce the reserve margin accordingly or model it as a flexible demand resource.

The constraint only involves capacity decisions, so it is part of the planning problem (and of the
master problem when using Benders decomposition). If `Capacity_reserve_margin_slack.csv` is provided,
a slack variable per requirement is added, penalized by `PriceCap` in \$/MW-yr.

Note that when time domain reduction is used, the peak is computed from the representative periods;
the time step with the highest demand should be included, e.g., by selecting extreme periods.
"""
function cap_reserve_margin_annual!(EP::Model, inputs::Dict, setup::Dict)
    println("Annual Capacity Reserve Margin Policies Module")

    gen = inputs["RESOURCES"]
    G = inputs["G"]
    NCRM = inputs["NCapacityReserveMargin"]
    margin = inputs["dfCapRes"]
    capresfactor = inputs["ANNUAL_DERATING_FACTOR"]

    ELECTROLYZERS = inputs["ELECTROLYZER"]
    ALLAM_CYCLE_LOX = inputs["ALLAM_CYCLE_LOX"]
    SUPPLY = setdiff(1:G, ELECTROLYZERS, ALLAM_CYCLE_LOX)

    if setup["TimeDomainReduction"] == 1
        @info "Annual capacity reserve margin: the peak demand is taken from the representative " *
              "periods. Make sure the peak demand period is included (e.g., as an extreme period)."
    end

    _, requirement = annual_capacity_reserve_requirement(inputs)

    # Accredited installed capacity
    create_empty_expression!(EP, :eCapResMarBalanceAnnual, NCRM)
    eCapResMarBalanceAnnual = EP[:eCapResMarBalanceAnnual]
    for res in 1:NCRM, y in SUPPLY
        capresfactor[y, res] == 0 && continue
        add_to_expression!(eCapResMarBalanceAnnual[res], capresfactor[y, res], EP[:eTotalCap][y])
    end

    # Allam cycle resources are credited on their net output capacity
    if !isempty(ALLAM_CYCLE_LOX)
        sco2turbine, asu = 1, 2
        eTotalCapAllam = EP[:eTotalCap_AllamcycleLOX]
        for res in 1:NCRM, y in ALLAM_CYCLE_LOX
            capresfactor[y, res] == 0 && continue
            asu_power_use = gen[y].lox_poweruserate_o2 + gen[y].gox_poweruserate_o2 +
                            gen[y].poweruserate_other
            add_to_expression!(eCapResMarBalanceAnnual[res], capresfactor[y, res],
                eTotalCapAllam[y, sco2turbine])
            add_to_expression!(eCapResMarBalanceAnnual[res], -capresfactor[y, res] * asu_power_use,
                eTotalCapAllam[y, asu])
        end
    end

    # Electrolyzers are firm consumption at the peak and are subject to the reserve margin
    if !isempty(ELECTROLYZERS)
        create_empty_expression!(EP, :eCapResAnnualElectrolyzer, NCRM)
        eCapResAnnualElectrolyzer = EP[:eCapResAnnualElectrolyzer]
        for res in 1:NCRM, y in ELECTROLYZERS
            capresfactor[y, res] == 0 && continue
            add_to_expression!(eCapResAnnualElectrolyzer[res],
                (1 + margin[zone_id(gen[y]), res]) * capresfactor[y, res], EP[:eTotalCap][y])
        end
        add_similar_to_expression!(eCapResMarBalanceAnnual, -1.0, eCapResAnnualElectrolyzer)
    end

    # Peak transfers between regions, limited by the line capacity
    CAPRES_LINES = annual_capacity_reserve_lines(inputs)
    if !isempty(CAPRES_LINES)
        excl = inputs["dfTransCapRes_excl"]
        derate = inputs["dfDerateTransCapRes"]
        @variable(EP, vCAPRES_TRANSFER[l in CAPRES_LINES])
        @constraint(EP, cCapResTransferMax[l in CAPRES_LINES],
            vCAPRES_TRANSFER[l] <= EP[:eAvail_Trans_Cap][l])
        @constraint(EP, cCapResTransferMin[l in CAPRES_LINES],
            vCAPRES_TRANSFER[l] >= -EP[:eAvail_Trans_Cap][l])
        # Net import contribution: flows on outbound lines (CapRes_Excl = 1) are subtracted,
        # flows on inbound lines (CapRes_Excl = -1) are added, as in the hourly formulation
        create_empty_expression!(EP, :eCapResAnnualNetImport, NCRM)
        eCapResAnnualNetImport = EP[:eCapResAnnualNetImport]
        for res in 1:NCRM, l in CAPRES_LINES
            excl[l, res] == 0 && continue
            add_to_expression!(eCapResAnnualNetImport[res], -excl[l, res] * derate[l, res],
                vCAPRES_TRANSFER[l])
        end
        add_similar_to_expression!(eCapResMarBalanceAnnual, eCapResAnnualNetImport)
    end

    # Slack variables, penalized in $/MW-yr
    if haskey(inputs, "dfCapRes_slack")
        @variable(EP, vCapResSlack[res = 1:NCRM]>=0)
        add_similar_to_expression!(eCapResMarBalanceAnnual, vCapResSlack)
        @expression(EP, eCCapResSlack[res = 1:NCRM],
            inputs["dfCapRes_slack"][res, :PriceCap] * vCapResSlack[res])
        @expression(EP, eCTotalCapResSlack, sum(eCCapResSlack[res] for res in 1:NCRM))
        add_to_expression!(EP[:eObj], eCTotalCapResSlack)
    end

    @constraint(EP, cCapacityResMarginAnnual[res = 1:NCRM],
        eCapResMarBalanceAnnual[res] >= requirement[res])
end

@doc raw"""
	annual_capacity_reserve_requirement(inputs::Dict)

Return the time step at which each annual capacity reserve margin requirement peaks and the value
of the requirement, $\max_{t} \sum_{z \in \mathcal{Z}^{CRM}_{p}} (1 + RM^{CRM}_{z,p}) D_{z,t}$,
in model units.
"""
function annual_capacity_reserve_requirement(inputs::Dict)
    margin = inputs["dfCapRes"]
    pD = inputs["pD"]
    NCRM = inputs["NCapacityReserveMargin"]
    peak_t = zeros(Int, NCRM)
    requirement = zeros(NCRM)
    for res in 1:NCRM
        zones = findall(!=(0), margin[:, res])
        requirement_t = [sum(((1 + margin[z, res]) * pD[t, z] for z in zones); init = 0.0)
                         for t in 1:inputs["T"]]
        requirement[res], peak_t[res] = findmax(requirement_t)
    end
    return peak_t, requirement
end

@doc raw"""
	annual_capacity_reserve_lines(inputs::Dict)

Return the lines that are eligible for at least one capacity reserve margin requirement
(non-zero `CapRes_Excl_*` in `Network.csv`).
"""
function annual_capacity_reserve_lines(inputs::Dict)
    haskey(inputs, "dfTransCapRes_excl") || return Int[]
    excl = inputs["dfTransCapRes_excl"]
    return findall(l -> any(!=(0), excl[l, :]), 1:inputs["L"])
end
