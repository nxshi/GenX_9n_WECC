@doc raw"""
	write_capacity_credit(path::AbstractString, inputs::Dict, setup::Dict, EP::Model,
		dfResRevenue::Union{DataFrame, Nothing} = nothing; val::Function = value)

Write `CapacityCredit.csv`, with the capacity credit of each resource $y$ in each capacity reserve
margin requirement $p$: the accredited capacity per MW of installed capacity that the requirement
grants the resource at the optimal solution.

With the hourly formulation (`CapacityReserveMargin = 1`), the credit is the price-weighted average
of the hourly contribution per MW of capacity over the time steps in which the requirement binds,
i.e. what system operators call a capacity credit:

```math
\text{credit}_{y,p} = \frac{R_{y,p}}{\Delta^{\text{total}}_{y} \times \sum_{t \in \mathcal{T}} \omega_{t} \pi_{p,t}}
```

where $R_{y,p}$ is the capacity revenue of the resource (`dfResRevenue`, see
[`write_reserve_margin_revenue`](@ref)) and $\pi_{p,t}$ the price of the requirement in time step
$t$. It is left empty for requirements with a total price below 1 \$/MW-yr (i.e., not binding).

With the annual formulation (`CapacityReserveMargin = 2`), the credit is the accredited capacity per
MW of installed capacity. For most resources it is equal to the `Annual_Derating_Factor_*` input. It
is lower for co-located VRE and storage resources whose components cannot deliver their full grid
connection capacity (see [`annual_capacity_reserve_capacity!`](@ref)). For electrolyzers, which add
to the requirement, it is negative and includes the reserve margin of their zone:
$-(1 + RM^{CRM}_{z,p}) \times \epsilon^{CRM,annual}_{y,p}$, e.g. -0.575 for a factor of 0.5 and a 15%
margin. The annual credit does not depend on prices, so it is also written for multi-stage runs and
Benders decomposition (`val` evaluates the solution, see
[`annual_capacity_reserve_contribution`](@ref)). The file allows comparing the capacity credits
implied by the two formulations.

Credits are left empty for resources with less than 1 MW of capacity and for Allam cycle resources,
whose capacity is defined per component.
"""
function write_capacity_credit(path::AbstractString,
        inputs::Dict,
        setup::Dict,
        EP::Model,
        dfResRevenue::Union{DataFrame, Nothing} = nothing;
        val::Function = value)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1
    gen = inputs["RESOURCES"]
    NCRM = inputs["NCapacityReserveMargin"]
    annual = setup["CapacityReserveMargin"] == 2
    if !annual && isnothing(dfResRevenue)
        error("The capacity credit of the hourly capacity reserve margin requires the capacity revenue.")
    end
    capacity = val.(EP[:eTotalCap]) * scale_factor  # MW
    minimum_capacity = 1  # MW
    minimum_price = 1  # $/MW-yr
    eligible = setdiff(findall(>=(minimum_capacity), capacity), inputs["ALLAM_CYCLE_LOX"])

    dfCredit = DataFrame(Resource = inputs["RESOURCE_NAMES"], Zone = zone_id.(gen))
    for res in 1:NCRM
        credit = Vector{Union{Missing, Float64}}(missing, inputs["G"])
        if annual
            contribution = annual_capacity_reserve_contribution(EP, inputs, res; val = val) *
                           scale_factor
            credit[eligible] = contribution[eligible] ./ capacity[eligible]
        else
            total_price = sum(capacity_reserve_margin_price(EP, inputs, setup, res) .*
                              inputs["omega"])
            if total_price >= minimum_price
                revenue = dfResRevenue[!, Symbol("CapRes_$res")]
                credit[eligible] = revenue[eligible] ./ (capacity[eligible] * total_price)
            end
        end
        dfCredit[!, Symbol("CapRes_$res")] = credit
    end
    CSV.write(joinpath(path, "CapacityCredit.csv"), dfCredit)
    return nothing
end
