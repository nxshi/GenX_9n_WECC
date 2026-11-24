@doc raw"""
	load_cap_reserve_margin!(setup::Dict, path::AbstractString, inputs::Dict)

Read input parameters related to planning reserve margin constraints
"""
function load_cap_reserve_margin!(setup::Dict, path::AbstractString, inputs::Dict)
    scale_factor = setup["ParameterScale"] == 1 ? ModelScalingFactor : 1

    filename = "Capacity_reserve_margin_slack.csv"
    if isfile(joinpath(path, filename))
        df = load_dataframe(joinpath(path, filename))
        inputs["dfCapRes_slack"] = df
        inputs["dfCapRes_slack"][!, :PriceCap] ./= scale_factor # Million $/GW if scaled, $/MW if not scaled
    end

    filename = "Capacity_reserve_margin.csv"
    df = load_dataframe(joinpath(path, filename))

    mat = extract_matrix_from_dataframe(df, "CapRes")
    inputs["dfCapRes"] = mat
    inputs["NCapacityReserveMargin"] = size(mat, 2)

    gen = inputs["RESOURCES"]
    res = 1:inputs["NCapacityReserveMargin"]
    inputs["DERATING_FACTOR"] = [derating_factor(g, tag = r) for g in gen, r = res]

    if setup["CapacityReserveMargin"] == 2
        load_annual_derating_factors!(gen, res, inputs)
    end

    println(filename * " Successfully Read!")
end

@doc raw"""
	load_annual_derating_factors!(gen::Vector{<:AbstractResource}, res::UnitRange{Int}, inputs::Dict)

Store the annual capacity accreditation factors (`Annual_Derating_Factor_*` columns of
`Resource_capacity_reserve_margin.csv`) in `inputs["ANNUAL_DERATING_FACTOR"]` (resources × requirements).

The annual formulation multiplies these factors by installed capacity, while the hourly formulation
multiplies `Derating_Factor_*` by hourly availability, so the two are not interchangeable. To avoid
silently reusing hourly derating factors as capacity credits, an error is thrown if the annual column
of any requirement is missing. An error is also thrown if a value is blank, not finite, or outside
[0, 1], or if a resource has a non-zero factor for a requirement that does not include its zone
(capacity located outside a requirement can only contribute through transmission, otherwise it
could be counted both directly and in the transfers backed by its zone). Resources that are not
listed in the file have a factor of zero.
"""
function load_annual_derating_factors!(gen::Vector{<:AbstractResource},
        res::UnitRange{Int},
        inputs::Dict)
    missing_cols = [r for r in res
                    if !any(haskey(g, Symbol("annual_derating_factor_$r")) for g in gen)]
    if !isempty(missing_cols)
        error("CapacityReserveMargin = 2 (annual formulation) requires the column(s) " *
              join(("Annual_Derating_Factor_$r" for r in missing_cols), ", ") *
              " in Resource_capacity_reserve_margin.csv. These are capacity accreditation " *
              "factors (e.g., ELCC or UCAP fractions) applied to installed capacity, and differ " *
              "from the Derating_Factor_* columns used by the hourly formulation.")
    end
    factors = [annual_derating_factor(g, tag = r) for g in gen, r in res]
    valid(x) = x isa Real && isfinite(x) && 0 <= x <= 1
    invalid = [(resource_name(gen[y]), r, factors[y, r]) for y in eachindex(gen), r in res
               if !valid(factors[y, r])]
    if !isempty(invalid)
        entries = join(("$name (Annual_Derating_Factor_$r = $x)" for (name, r, x) in invalid), ", ")
        error("Annual_Derating_Factor_* values in Resource_capacity_reserve_margin.csv must be " *
              "numbers between 0 and 1 (blank cells are not allowed). Invalid values: " * entries)
    end
    # Resources can only be accredited to the requirements that include their zone
    margin = inputs["dfCapRes"]
    outside = [(resource_name(gen[y]), zone_id(gen[y]), r) for y in eachindex(gen), r in res
               if factors[y, r] != 0 && margin[zone_id(gen[y]), r] == 0]
    if !isempty(outside)
        entries = join(("$name (zone $z, Annual_Derating_Factor_$r)" for (name, z, r) in outside),
            ", ")
        error("Annual_Derating_Factor_* must be zero for resources located in zones that are not " *
              "part of the requirement (zones with a zero margin in Capacity_reserve_margin.csv); " *
              "capacity located outside a requirement can only contribute through transmission " *
              "(CapRes_Excl_* in Network.csv). Invalid values: " * entries)
    end
    inputs["ANNUAL_DERATING_FACTOR"] = Float64.(factors)
    return nothing
end

@doc raw"""
	load_cap_reserve_margin_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)

Read input parameters related to participation of transmission imports/exports in capacity reserve margin constraint.
"""
function load_cap_reserve_margin_trans!(setup::Dict, inputs::Dict, network_var::DataFrame)
    mat = extract_matrix_from_dataframe(network_var, "DerateCapRes")
    inputs["dfDerateTransCapRes"] = mat

    mat = extract_matrix_from_dataframe(network_var, "CapRes_Excl")
    inputs["dfTransCapRes_excl"] = mat
end
