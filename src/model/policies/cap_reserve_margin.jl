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
	& \sum_{y \in \mathcal{G} \setminus \mathcal{EL}} \epsilon^{CRM,annual}_{y,p} \times \Delta^{CRM}_{y}
	- \sum_{y \in \mathcal{EL}} \left(1 + RM^{CRM}_{z(y),p}\right) \times \epsilon^{CRM,annual}_{y,p} \times \Delta^{\text{total}}_{y} \\
	& + \sum_{l \in \mathcal{L}_{p}^{in}} \epsilon^{CRM}_{l,p} \times \Phi^{CRM}_{l} - \sum_{l \in \mathcal{L}_{p}^{out}} \epsilon^{CRM}_{l,p} \times \Phi^{CRM}_{l} \\
	& \geq \max_{t \in \mathcal{T}} \sum_{z \in \mathcal{Z}^{CRM}_{p}} \left(1 + RM^{CRM}_{z,p}\right) \times D_{z,t}
	\hspace{1 cm} \forall p \in \mathcal{P}^{CRM}
\end{aligned}
```

Here $\Delta^{CRM}_{y}$ is the accreditable capacity of resource $y$: its installed capacity
$\Delta^{\text{total}}_{y}$, except for co-located and Allam cycle resources (see below).
With equal margins $RM^{CRM}_{z,p}$ across zones, the right-hand side is $(1 + RM_{p})$ times the
coincident peak demand, i.e. the highest total demand of the zones at the same time step. With
unequal margins, the selected time step maximizes the margin-adjusted demand, which can differ from
the time of the highest unadjusted demand. As in the hourly formulation, the zones of requirement
$p$ are those with a non-zero margin in `Capacity_reserve_margin.csv`: a zero margin excludes the
zone rather than including it with no margin.

**Accreditation.** $\epsilon^{CRM,annual}_{y,p}$ is read from the `Annual_Derating_Factor_*` columns of
`Resource_capacity_reserve_margin.csv`. It multiplies installed capacity directly, so it must represent
the full capacity credit of the resource (e.g., ELCC or UCAP fraction), including the coincidence of
variable renewable output with the peak and the duration limits of energy-limited resources. It is
therefore different from the `Derating_Factor_*` columns used by the hourly formulation, which are
multiplied by hourly availability or dispatch. The factors must lie in [0, 1]; resources not listed
in the file have a factor of zero. A resource can only be accredited to the requirements that include
its zone: capacity located outside a requirement contributes only through transmission, so that it
cannot be counted both directly and in the transfers backed by its zone. Notes on specific resources:
- Storage, hydro and flexible demand are credited on their (discharge) power capacity. Charging is not
  subtracted, since a resource cannot charge and discharge at full power at the peak. The factor must
  therefore account for the storage duration: it is not checked that enough energy is available.
- Co-located VRE and storage resources are credited on the capacity their components can deliver to
  the grid, $\Delta^{CRM}_{y}$: the smallest of the grid connection capacity and the capacity of the
  components (wind, AC storage discharge, and the output of the DC components, i.e. solar and DC
  storage discharge, limited by the inverter), see [`annual_capacity_reserve_capacity!`](@ref). The
  grid connection alone is not credited.
- Allam cycle resources are credited on their net output capacity (sCO2 turbine capacity minus the
  power used by the air separation unit), as in the minimum capacity requirement.
- Fusion and thermal maintenance adjustments of the hourly formulation are not applied; the
  accreditation factor should be net of recirculating power and planned outages.

**Electrolyzers** ($y \in \mathcal{EL}$) are treated as firm consumption at the peak: their capacity,
scaled by $\epsilon^{CRM,annual}_{y,p}$ (the expected coincident consumption share), increases the
requirement and is subject to the same reserve margin as demand.

**Transmission.** Each requirement treats its zones as a single region (a copper plate), and a
requirement covering only part of the system can rely on firm capacity located outside of it. The
boundary lines of a requirement are the lines with a non-zero `CapRes_Excl_*` in `Network.csv`. If
there are any, a peak transfer variable $\Phi^{CRM}_{l}$ is defined for every boundary line and for
every line that does not cross the boundary of any requirement, which can carry firm capacity in
transit (e.g., between two zones outside a requirement, towards one of its boundary lines). It is
the firm capacity delivered over the line at the time of the peak, positive in the line direction
(from `Start_Zone` to `End_Zone`). It is not an hourly flow and has no cost; it is only bounded by
the line capacity, $-\varphi^{cap}_{l} \leq \Phi^{CRM}_{l} \leq \varphi^{cap}_{l}$, which can be
expanded. Only boundary lines contribute to the requirements, with the same sign convention and
derating factors $\epsilon^{CRM}_{l,p}$ (`DerateCapRes_*`) as in the hourly formulation. Because the
same transfer enters every requirement, capacity imported into one region is exported from the other
and cannot be counted twice. The inputs are validated so that all firm capacity crossing the
boundary of a requirement is accounted for in it (see [`validate_annual_capacity_reserve_lines`](@ref)):
the signs of `CapRes_Excl_*` must match the direction of the lines, a line crossing several
boundaries must be eligible for all or none of them, the eligible lines of a requirement must have
the same derating factor (otherwise capacity could gain credit by circulating, in over a line and out
over another), and a line must have the same derating factor in all the requirements it is eligible
for (otherwise a transfer could add more to the importing requirement than it removes from the
exporting one). Transfers must also be backed by firm capacity: the net firm capacity a zone
sends out over these lines cannot exceed the firm capacity located in the zone,

```math
\sum_{l \in \mathcal{L}} \varphi^{map}_{l,z} \times \Phi^{CRM}_{l} \leq
\sum_{y \in \mathcal{G}_{z} \setminus \mathcal{EL}} \max_{p} \epsilon^{CRM,annual}_{y,p} \times \Delta^{CRM}_{y}
\hspace{1 cm} \forall z
```

where $\varphi^{map}_{l,z}$ is the network map (1 if line $l$ starts in zone $z$, -1 if it ends there)
and $\Delta^{CRM}_{y}$ the accreditable capacity of the resource (its installed capacity, except for
co-located and Allam cycle resources). A zone can pass on firm capacity it receives, but cannot export
capacity it does not have, e.g., from an empty or disconnected zone. The firm capacity of a resource
uses its largest annual factor over the requirements, in practice the factor of the requirement
covering its zone. This constraint does not reserve capacity for the exporting zone's own peak. That
is only ensured if the exporting zone is covered by a requirement that has the line as a boundary, in
which the export is subtracted. A requirement containing both ends of the line, such as a
system-wide one, counts the capacity once in aggregate, but it does not ensure that the exporter
keeps enough capacity for its own peak, nor that its capacity can reach the other zones of that
requirement. A warning lists the exporting zones that are not covered by such a requirement (see
[`annual_capacity_reserve_uncovered_exports`](@ref)); for a network-backed assessment, define a
requirement for each region that exports capacity. The transfers are firm-capacity allocations, not
hourly flows, and their values may not be unique.

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
    SUPPLY = setdiff(1:G, ELECTROLYZERS)

    if setup["TimeDomainReduction"] == 1
        @info "Annual capacity reserve margin: the peak demand is taken from the representative " *
              "periods. Make sure the peak demand period is included (e.g., as an extreme period)."
    end

    _, requirement = annual_capacity_reserve_requirement(inputs)

    # Capacity of each resource that can be accredited, before applying the accreditation factors
    annual_capacity_reserve_capacity!(EP, inputs)
    eCapResAnnualCapacity = EP[:eCapResAnnualCapacity]

    # Accredited capacity
    create_empty_expression!(EP, :eCapResMarBalanceAnnual, NCRM)
    eCapResMarBalanceAnnual = EP[:eCapResMarBalanceAnnual]
    for res in 1:NCRM, y in SUPPLY
        capresfactor[y, res] == 0 && continue
        add_to_expression!(eCapResMarBalanceAnnual[res], capresfactor[y, res],
            eCapResAnnualCapacity[y])
    end

    # Electrolyzers are firm consumption at the peak and are subject to the reserve margin
    if !isempty(ELECTROLYZERS)
        create_empty_expression!(EP, :eCapResAnnualElectrolyzer, NCRM)
        eCapResAnnualElectrolyzer = EP[:eCapResAnnualElectrolyzer]
        for res in 1:NCRM, y in ELECTROLYZERS
            capresfactor[y, res] == 0 && continue
            add_to_expression!(eCapResAnnualElectrolyzer[res],
                (1 + margin[zone_id(gen[y]), res]) * capresfactor[y, res],
                eCapResAnnualCapacity[y])
        end
        add_similar_to_expression!(eCapResMarBalanceAnnual, -1.0, eCapResAnnualElectrolyzer)
    end

    # Peak transfers between regions, limited by the line capacity
    BOUNDARY_LINES = annual_capacity_reserve_lines(inputs)
    if !isempty(BOUNDARY_LINES)
        validate_annual_capacity_reserve_lines(inputs)
        uncovered = annual_capacity_reserve_uncovered_exports(inputs)
        if !isempty(uncovered)
            @warn "Annual capacity reserve margin: the following zones can export firm capacity " *
                  "over a requirement boundary, but no requirement covering them has that line as " *
                  "a boundary, so the capacity they export is not reserved for their own peak " *
                  "(requirements containing both ends of the line, e.g. a system-wide one, only " *
                  "count it in aggregate): " *
                  join(("zone $(u.zone) (line $(u.line), CapRes_$(u.requirement))"
                        for u in uncovered), ", ")
        end

        # Firm capacity can be transferred over the boundary lines and, in transit, over the
        # lines that do not cross the boundary of any requirement
        TRANSFER_LINES = annual_capacity_reserve_transfer_lines(inputs)
        excl = inputs["dfTransCapRes_excl"]
        derate = inputs["dfDerateTransCapRes"]
        @variable(EP, vCAPRES_TRANSFER[l in TRANSFER_LINES])
        @constraint(EP, cCapResTransferMax[l in TRANSFER_LINES],
            vCAPRES_TRANSFER[l] <= EP[:eAvail_Trans_Cap][l])
        @constraint(EP, cCapResTransferMin[l in TRANSFER_LINES],
            vCAPRES_TRANSFER[l] >= -EP[:eAvail_Trans_Cap][l])

        # A zone cannot send out more firm capacity than it holds (it can pass on what it
        # receives), so that transfers are backed by firm capacity
        net_map = inputs["pNet_Map"]
        CAPRES_ZONES = findall(z -> any(net_map[l, z] != 0 for l in TRANSFER_LINES),
            1:inputs["Z"])
        firmfactor = vec(maximum(capresfactor, dims = 2))
        create_empty_expression!(EP, :eCapResAnnualFirmCapacity, inputs["Z"])
        eCapResAnnualFirmCapacity = EP[:eCapResAnnualFirmCapacity]
        for y in SUPPLY
            firmfactor[y] == 0 && continue
            add_to_expression!(eCapResAnnualFirmCapacity[zone_id(gen[y])], firmfactor[y],
                eCapResAnnualCapacity[y])
        end
        @constraint(EP, cCapResTransferBacking[z in CAPRES_ZONES],
            sum(net_map[l, z] * vCAPRES_TRANSFER[l] for l in TRANSFER_LINES) <=
            eCapResAnnualFirmCapacity[z])

        # Net import contribution of the boundary lines: flows on outbound lines (CapRes_Excl = 1)
        # are subtracted, flows on inbound lines (CapRes_Excl = -1) are added, as in the hourly
        # formulation
        create_empty_expression!(EP, :eCapResAnnualNetImport, NCRM)
        eCapResAnnualNetImport = EP[:eCapResAnnualNetImport]
        for res in 1:NCRM, l in BOUNDARY_LINES
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

Return the boundary lines of the capacity reserve margin requirements, i.e. the lines that are
eligible for at least one requirement (non-zero `CapRes_Excl_*` in `Network.csv`).
"""
function annual_capacity_reserve_lines(inputs::Dict)
    haskey(inputs, "dfTransCapRes_excl") || return Int[]
    excl = inputs["dfTransCapRes_excl"]
    return findall(l -> any(!=(0), excl[l, :]), 1:inputs["L"])
end

@doc raw"""
	annual_capacity_reserve_crossing(inputs::Dict)

Return a matrix (lines × requirements) describing, from the network topology, how each line crosses
the boundary of each capacity reserve margin requirement: 1 if the line starts in the zones of the
requirement and ends outside them (outbound), -1 if it ends in them and starts outside (inbound),
and 0 if it does not cross the boundary.
"""
function annual_capacity_reserve_crossing(inputs::Dict)
    net_map = inputs["pNet_Map"]
    margin = inputs["dfCapRes"]
    crossing = zeros(Int, inputs["L"], inputs["NCapacityReserveMargin"])
    for l in 1:inputs["L"], res in 1:inputs["NCapacityReserveMargin"]
        start_in = margin[findfirst(==(1), net_map[l, :]), res] != 0
        end_in = margin[findfirst(==(-1), net_map[l, :]), res] != 0
        crossing[l, res] = start_in == end_in ? 0 : (start_in ? 1 : -1)
    end
    return crossing
end

@doc raw"""
	validate_annual_capacity_reserve_lines(inputs::Dict)

Check the transmission inputs of the annual capacity reserve margin (`CapRes_Excl_*` and
`DerateCapRes_*` in `Network.csv`), so that all firm capacity carried across the boundary of a
requirement is accounted for in that requirement:
- a non-zero `CapRes_Excl_*` must be 1 for a line leaving the zones of the requirement and -1 for a
  line entering them; it must be 0 for a line that does not cross the boundary;
- a line crossing the boundaries of several requirements must be eligible for all of them or for
  none of them (a line that is eligible for no requirement does not carry firm capacity);
- the eligible lines of a requirement must have the same `DerateCapRes_*`, so that firm capacity
  cannot gain credit by circulating, in over a line and out over another;
- a line eligible for several requirements must have the same `DerateCapRes_*` in all of them, so
  that a transfer adds to the importing requirement as much as it removes from the exporting one.
An error is thrown otherwise.
"""
function validate_annual_capacity_reserve_lines(inputs::Dict)
    excl = inputs["dfTransCapRes_excl"]
    derate = inputs["dfDerateTransCapRes"]
    NCRM = inputs["NCapacityReserveMargin"]
    L = inputs["L"]
    crossing = annual_capacity_reserve_crossing(inputs)
    errors = String[]
    for l in 1:L, res in 1:NCRM
        if excl[l, res] != 0 && excl[l, res] != crossing[l, res]
            push!(errors,
                "line $l has CapRes_Excl_$res = $(excl[l, res]) but should have " *
                "$(crossing[l, res]) given the zones of CapRes_$res (1: the line leaves the " *
                "zones, -1: it enters them, 0: it does not cross their boundary)")
        end
    end
    for l in 1:L
        crossed = findall(!=(0), crossing[l, :])
        eligible = filter(res -> excl[l, res] != 0, crossed)
        if !isempty(eligible) && length(eligible) < length(crossed)
            push!(errors,
                "line $l crosses the boundaries of " * join(("CapRes_$r" for r in crossed), ", ") *
                " but is only eligible for " * join(("CapRes_$r" for r in eligible), ", ") *
                " (CapRes_Excl must be non-zero for all of them or for none)")
        end
    end
    for res in 1:NCRM
        derates = unique(derate[l, res] for l in 1:L if excl[l, res] != 0)
        if length(derates) > 1
            push!(errors,
                "the eligible lines of CapRes_$res have different DerateCapRes_$res values (" *
                join(derates, ", ") * ")")
        end
    end
    for l in 1:L
        eligible = findall(!=(0), excl[l, :])
        if length(unique(derate[l, res] for res in eligible)) > 1
            push!(errors,
                "line $l has different DerateCapRes values for " *
                join(("CapRes_$r ($(derate[l, r]))" for r in eligible), ", ") *
                " (a transfer must add to the importing requirement as much as it removes " *
                "from the exporting one)")
        end
    end
    if !isempty(errors)
        error("Invalid transmission inputs for the annual capacity reserve margin in " *
              "Network.csv: " * join(errors, "; ") * ".")
    end
    return nothing
end

@doc raw"""
	annual_capacity_reserve_transfer_lines(inputs::Dict)

Return the lines that can carry firm capacity in the annual capacity reserve margin: the boundary
lines (see [`annual_capacity_reserve_lines`](@ref)) and the lines that do not cross the boundary of
any requirement, which can carry firm capacity in transit (e.g., between two zones outside a
requirement, towards one of its boundary lines). Lines that cross a boundary but are eligible for
no requirement do not carry firm capacity.
"""
function annual_capacity_reserve_transfer_lines(inputs::Dict)
    excl = inputs["dfTransCapRes_excl"]
    crossing = annual_capacity_reserve_crossing(inputs)
    return findall(l -> any(!=(0), excl[l, :]) || all(==(0), crossing[l, :]), 1:inputs["L"])
end

@doc raw"""
	annual_capacity_reserve_uncovered_exports(inputs::Dict)

Return the zones that can export firm capacity over the boundary line of a requirement, but are not
covered by any requirement that has this line as a boundary, as a vector of named tuples
`(zone, line, requirement)`. The capacity these zones export is limited by their firm capacity, but
it is not reserved for their own peak demand: requirements that contain both ends of the line (e.g.,
a system-wide one) only count it in aggregate.
"""
function annual_capacity_reserve_uncovered_exports(inputs::Dict)
    excl = inputs["dfTransCapRes_excl"]
    margin = inputs["dfCapRes"]
    net_map = inputs["pNet_Map"]
    NCRM = inputs["NCapacityReserveMargin"]
    uncovered = NamedTuple{(:zone, :line, :requirement), Tuple{Int, Int, Int}}[]
    for l in 1:inputs["L"], res in 1:NCRM
        excl[l, res] == 0 && continue
        # Zone on the other side of the boundary
        outside = findfirst(==(excl[l, res] > 0 ? -1 : 1), net_map[l, :])
        covered = any(margin[outside, q] != 0 && excl[l, q] != 0 for q in 1:NCRM)
        covered || push!(uncovered, (zone = outside, line = l, requirement = res))
    end
    return uncovered
end

@doc raw"""
	annual_capacity_reserve_capacity!(EP::Model, inputs::Dict)

Create the expression `eCapResAnnualCapacity[y]`, the capacity of each resource $y$ that the annual
capacity reserve margin can accredit, $\Delta^{CRM}_{y}$, before applying the accreditation factors:
- installed capacity `eTotalCap` for most resources (consumption capacity for electrolyzers);
- net output capacity for Allam cycle resources (sCO2 turbine capacity minus the power used by the
  air separation unit, as in the minimum capacity requirement);
- for co-located VRE and storage resources with a non-zero annual factor, the capacity their
  components can deliver to the grid. A variable $\Delta^{CRM}_{y}$ is bounded by the grid connection
  capacity and by the AC capacity of the components:

```math
\begin{aligned}
	& \Delta^{CRM}_{y} \leq \Delta^{total}_{y} \\
	& \Delta^{CRM}_{y} \leq \Delta^{total,wind}_{y} + \Delta^{dis,ac}_{y} + \Delta^{CRM,dc}_{y} \\
	& \Delta^{CRM,dc}_{y} \leq \Delta^{total,inv}_{y} \\
	& \Delta^{CRM,dc}_{y} \leq \eta^{inverter}_{y} \times \left(\Delta^{total,pv}_{y} + \Delta^{dis,dc}_{y}\right)
\end{aligned}
```

where $\Delta^{dis,ac}_{y}$ and $\Delta^{dis,dc}_{y}$ are the AC and DC storage discharge capacities
(the power-to-energy ratio times the energy capacity for symmetric storage) and $\Delta^{CRM,dc}_{y}$
is the AC output of the DC components, limited by the inverter capacity. Since the variable only
appears on the left-hand side of the requirements, it is set to the smallest of the bounds when the
requirement binds; when it does not, its value (and the reported accredited capacity) can be lower.
"""
function annual_capacity_reserve_capacity!(EP::Model, inputs::Dict)
    gen = inputs["RESOURCES"]
    G = inputs["G"]
    ALLAM_CYCLE_LOX = inputs["ALLAM_CYCLE_LOX"]
    VRE_STOR = inputs["VRE_STOR"]

    create_empty_expression!(EP, :eCapResAnnualCapacity, G)
    eCapResAnnualCapacity = EP[:eCapResAnnualCapacity]
    for y in setdiff(1:G, ALLAM_CYCLE_LOX, VRE_STOR)
        add_to_expression!(eCapResAnnualCapacity[y], EP[:eTotalCap][y])
    end

    # Allam cycle resources: net output capacity
    if !isempty(ALLAM_CYCLE_LOX)
        sco2turbine, asu = 1, 2
        eTotalCapAllam = EP[:eTotalCap_AllamcycleLOX]
        for y in ALLAM_CYCLE_LOX
            asu_power_use = gen[y].lox_poweruserate_o2 + gen[y].gox_poweruserate_o2 +
                            gen[y].poweruserate_other
            add_to_expression!(eCapResAnnualCapacity[y], eTotalCapAllam[y, sco2turbine])
            add_to_expression!(eCapResAnnualCapacity[y], -asu_power_use, eTotalCapAllam[y, asu])
        end
    end

    # Co-located VRE and storage resources: capacity deliverable by their components
    capresfactor = inputs["ANNUAL_DERATING_FACTOR"]
    VS = filter(y -> any(!=(0), capresfactor[y, :]), VRE_STOR)
    if !isempty(VS)
        annual_capacity_reserve_vre_stor!(EP, inputs, VS)
        for y in VS
            add_to_expression!(eCapResAnnualCapacity[y], EP[:vCAPRES_ANNUAL_VS][y])
        end
    end
    return nothing
end

@doc raw"""
	annual_capacity_reserve_vre_stor!(EP::Model, inputs::Dict, VS::Vector{Int})

Create the variables `vCAPRES_ANNUAL_VS[y]` (capacity that co-located resource $y$ can deliver to the
grid) and `vCAPRES_ANNUAL_VS_DC[y]` (AC output of its DC components) and their bounds, see
[`annual_capacity_reserve_capacity!`](@ref).
"""
function annual_capacity_reserve_vre_stor!(EP::Model, inputs::Dict, VS::Vector{Int})
    gen = inputs["RESOURCES"]
    DC = intersect(VS, inputs["VS_DC"])

    # AC output of the DC components (solar and DC storage discharge), limited by the inverter
    @variable(EP, vCAPRES_ANNUAL_VS_DC[y in DC]>=0)
    @constraint(EP, cCapResAnnualVSInverter[y in DC],
        vCAPRES_ANNUAL_VS_DC[y] <= EP[:eTotalCap_DC][y])
    dc_capacity = Dict(y => AffExpr(0.0) for y in DC)
    for y in intersect(DC, inputs["VS_SOLAR"])
        add_to_expression!(dc_capacity[y], etainverter(gen[y]), EP[:eTotalCap_SOLAR][y])
    end
    for y in intersect(DC, inputs["VS_SYM_DC"])
        add_to_expression!(dc_capacity[y], etainverter(gen[y]) * power_to_energy_dc(gen[y]),
            EP[:eTotalCap_STOR][y])
    end
    for y in intersect(DC, inputs["VS_ASYM_DC_DISCHARGE"])
        add_to_expression!(dc_capacity[y], etainverter(gen[y]), EP[:eTotalCapDischarge_DC][y])
    end
    @constraint(EP, cCapResAnnualVSDC[y in DC], vCAPRES_ANNUAL_VS_DC[y] <= dc_capacity[y])

    # Capacity delivered to the grid, limited by the grid connection and by the components
    @variable(EP, vCAPRES_ANNUAL_VS[y in VS]>=0)
    @constraint(EP, cCapResAnnualVSGrid[y in VS], vCAPRES_ANNUAL_VS[y] <= EP[:eTotalCap][y])
    ac_capacity = Dict(y => AffExpr(0.0) for y in VS)
    for y in intersect(VS, inputs["VS_WIND"])
        add_to_expression!(ac_capacity[y], EP[:eTotalCap_WIND][y])
    end
    for y in intersect(VS, inputs["VS_SYM_AC"])
        add_to_expression!(ac_capacity[y], power_to_energy_ac(gen[y]), EP[:eTotalCap_STOR][y])
    end
    for y in intersect(VS, inputs["VS_ASYM_AC_DISCHARGE"])
        add_to_expression!(ac_capacity[y], EP[:eTotalCapDischarge_AC][y])
    end
    for y in DC
        add_to_expression!(ac_capacity[y], vCAPRES_ANNUAL_VS_DC[y])
    end
    @constraint(EP, cCapResAnnualVSComponents[y in VS], vCAPRES_ANNUAL_VS[y] <= ac_capacity[y])
    return nothing
end
