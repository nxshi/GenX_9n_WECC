@doc raw"""
	annual_capacity_reserve_contribution(EP::Model, inputs::Dict, res::Int; val::Function = value)

Return a vector (one entry per resource, in model units) with the contribution of each resource to
the annual capacity reserve margin requirement `res` at the solution: the annual factor times the
accreditable capacity `eCapResAnnualCapacity`. Electrolyzers have a negative contribution, equal to
the requirement they add, $-(1 + RM^{CRM}_{z,p}) \times \epsilon^{CRM,annual}_{y,p} \times \Delta^{total}_{y}$
(see [`cap_reserve_margin_annual!`](@ref)).

`val` returns the value of a variable or expression; it defaults to the value in the solved model and
is used to evaluate the incumbent planning solution with Benders decomposition.
"""
function annual_capacity_reserve_contribution(EP::Model,
        inputs::Dict,
        res::Int;
        val::Function = value)
    gen = inputs["RESOURCES"]
    capresfactor = inputs["ANNUAL_DERATING_FACTOR"][:, res]
    margin = inputs["dfCapRes"][:, res]

    contribution = capresfactor .* val.(EP[:eCapResAnnualCapacity])
    for y in inputs["ELECTROLYZER"]
        contribution[y] *= -(1 + margin[zone_id(gen[y])])
    end
    return contribution
end

@doc raw"""
	capacity_reserve_margin_price_annual(EP::Model, setup::Dict)::Vector{Float64}

Marginal price of each annual capacity reserve margin requirement, i.e. the dual variable of
`cCapacityResMarginAnnual`, in US\$/MW-yr. The objective scaling (`ObjScale`) and the parameter
scaling (`ParameterScale`) are removed.
"""
function capacity_reserve_margin_price_annual(EP::Model, setup::Dict)::Vector{Float64}
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    return dual.(EP[:cCapacityResMarginAnnual]) * scale_factor / get(setup, "ObjScale", 1)
end

@doc raw"""
	write_reserve_margin_annual(path::AbstractString, inputs::Dict, setup::Dict, EP::Model;
		val::Function = value, prices::Bool = has_duals(EP) && setup["MultiStage"] == 0)

Write `ReserveMargin_annual.csv`, with one row per annual capacity reserve margin requirement and
the following columns (MW unless noted):
- `Peak_Time_Index`: time step at which the requirement peaks.
- `Peak_Demand_MW`: coincident demand of the zones in the requirement at that time step.
- `Requirement_MW`: demand-driven requirement, i.e. peak demand including the reserve margin.
- `Electrolyzer_Requirement_MW`: requirement added by electrolyzers.
- `Accredited_Capacity_MW`: accredited capacity of all other resources.
- `Net_Import_MW`: derated net transfer into the region over eligible lines.
- `Slack_MW`: unmet requirement (only if `Capacity_reserve_margin_slack.csv` is provided).
- `Price_USD_per_MW_yr`: shadow price of the requirement (only if `prices` is true). By default it
  is not written for multi-stage runs, where the shadow prices include the discounting of the stage,
  as for the other price outputs that are not written for multi-stage runs.

`val` returns the value of a variable or expression (see [`annual_capacity_reserve_contribution`](@ref)).
"""
function write_reserve_margin_annual(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model;
        val::Function = value,
        prices::Bool = has_duals(EP) && setup["MultiStage"] == 0)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    NCRM = inputs["NCapacityReserveMargin"]
    ELECTROLYZERS = inputs["ELECTROLYZER"]
    margin = inputs["dfCapRes"]

    peak_t, requirement = annual_capacity_reserve_requirement(inputs)
    peak_demand = [sum((inputs["pD"][peak_t[res], z] for z in findall(!=(0), margin[:, res]));
                       init = 0.0) for res in 1:NCRM]
    contribution = [annual_capacity_reserve_contribution(EP, inputs, res; val = val)
                    for res in 1:NCRM]
    electrolyzer = [sum((-contribution[res][y] for y in ELECTROLYZERS); init = 0.0)
                    for res in 1:NCRM]
    accredited = [sum(contribution[res]) + electrolyzer[res] for res in 1:NCRM]
    net_import = haskey(EP, :eCapResAnnualNetImport) ?
                 val.(EP[:eCapResAnnualNetImport]) : zeros(NCRM)

    df = DataFrame(Constraint = [Symbol("CapRes_$res") for res in 1:NCRM],
        Peak_Time_Index = peak_t,
        Peak_Demand_MW = peak_demand * scale_factor,
        Requirement_MW = requirement * scale_factor,
        Electrolyzer_Requirement_MW = electrolyzer * scale_factor,
        Accredited_Capacity_MW = accredited * scale_factor,
        Net_Import_MW = net_import * scale_factor)
    if haskey(inputs, "dfCapRes_slack")
        df.Slack_MW = val.(EP[:vCapResSlack]) * scale_factor
    end
    if prices
        df.Price_USD_per_MW_yr = capacity_reserve_margin_price_annual(EP, setup)
    end
    CSV.write(joinpath(path, "ReserveMargin_annual.csv"), df)
    return nothing
end

@doc raw"""
	write_reserve_margin_revenue_annual(path::AbstractString, inputs::Dict, setup::Dict, EP::Model)

Write `ReserveMarginRevenue.csv` for the annual capacity reserve margin. The revenue of each
resource for each requirement is its accredited capacity times the shadow price of the requirement
(US\$). Electrolyzers have a negative revenue (a cost) equal to the requirement they add times the
price. The columns are the same as for the hourly formulation, so that the total (`AnnualSum`) can be
used in `NetRevenue.csv`.
"""
function write_reserve_margin_revenue_annual(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    gen = inputs["RESOURCES"]
    price = capacity_reserve_margin_price_annual(EP, setup)

    dfResRevenue = DataFrame(Region = region.(gen),
        Resource = inputs["RESOURCE_NAMES"],
        Zone = zone_id.(gen),
        Cluster = cluster.(gen))
    annual_sum = zeros(inputs["G"])
    for res in 1:inputs["NCapacityReserveMargin"]
        revenue = annual_capacity_reserve_contribution(EP, inputs, res) * price[res] *
                  scale_factor
        annual_sum .+= revenue
        dfResRevenue[!, Symbol("CapRes_$res")] = revenue
    end
    dfResRevenue.AnnualSum = annual_sum
    CSV.write(joinpath(path, "ReserveMarginRevenue.csv"), dfResRevenue)
    return dfResRevenue
end

@doc raw"""
	write_reserve_margin_slack_annual(path::AbstractString, inputs::Dict, setup::Dict, EP::Model;
		val::Function = value)

Write `ReserveMargin_slack_and_penalties.csv` for the annual capacity reserve margin: the slack of
each requirement (MW) and its penalty (US\$). `val` returns the value of a variable or expression
(see [`annual_capacity_reserve_contribution`](@ref)).
"""
function write_reserve_margin_slack_annual(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model;
        val::Function = value)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    NCRM = inputs["NCapacityReserveMargin"]
    df = DataFrame(CRM_Constraint = [Symbol("CapRes_$res") for res in 1:NCRM],
        Slack = val.(EP[:vCapResSlack]) * scale_factor,  # MW
        Penalty = val.(EP[:eCCapResSlack]) * scale_factor^2)  # $
    CSV.write(joinpath(path, "ReserveMargin_slack_and_penalties.csv"), df)
    return nothing
end
