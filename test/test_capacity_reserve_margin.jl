module TestCapacityReserveMargin

using Test
using YAML

include(joinpath(@__DIR__, "utilities.jl"))

# Three-zone system with two capacity reserve margin requirements:
#   CapRes_1: system-wide, 15% margin (no transmission contribution)
#   CapRes_2: MA only, 15% margin; both lines leave MA (CapRes_Excl_2 = 1, DerateCapRes_2 = 0.95)
test_path = "capacity_reserve_margin"

genx_setup = Dict("NetworkExpansion" => 1,
    "Trans_Loss_Segments" => 1,
    "CO2Cap" => 2,
    "StorageLosses" => 1,
    "ParameterScale" => 1,
    "UCommit" => 2)

hourly_setup = merge(genx_setup, Dict("CapacityReserveMargin" => 1))
annual_setup = merge(genx_setup, Dict("CapacityReserveMargin" => 2))

function run_case(path, setup)
    redirect_stdout(devnull) do
        run_genx_case_testing(path, setup)
    end
end

function test_objective(EP, obj_true, log_name)
    obj_test = objective_value(EP)
    optimal_tol = get_attribute(EP, "ipm_optimality_tolerance") * obj_test
    test_result = @test obj_test≈obj_true atol=optimal_tol
    obj_test = round_from_tol!(obj_test, optimal_tol)
    optimal_tol = round_from_tol!(optimal_tol, optimal_tol)
    write_testlog(log_name, obj_test, optimal_tol, test_result)
end

# Inequality constraints are only satisfied up to the primal feasibility tolerance of the solver
# (`Feasib_Tol` in highs_settings.yml), in model units
feasibility_tolerance(EP) = get_attribute(EP, "primal_feasibility_tolerance")

# Run `f` on a copy of a test case, so that its input files can be modified.
# The copy is in a temporary folder that is removed when `f` returns or throws.
function with_case_copy(f, path)
    mktempdir() do dir
        case = joinpath(dir, basename(path))
        cp(joinpath(@__DIR__, path), case)
        f(case)
    end
end

@testset "Invalid CapacityReserveMargin flag" begin
    settings = merge(GenX.default_settings(), Dict("CapacityReserveMargin" => 3))
    @test_throws ErrorException GenX.validate_settings!(settings)
end

@testset "Hourly formulation" begin
    EP, inputs, _ = run_case(test_path, hourly_setup)
    test_objective(EP, 7099.152406, test_path * "_hourly")
    @test haskey(EP, :cCapacityResMargin)
    @test !haskey(EP, :cCapacityResMarginAnnual)

    # Capacity credit: price-weighted capacity value over the binding hours
    settings = merge(GenX.default_settings(), hourly_setup)
    credit = mktempdir() do dir
        redirect_stdout(devnull) do
            dfrev = GenX.write_reserve_margin_revenue(dir, inputs, settings, EP)
            GenX.write_capacity_credit(dir, inputs, settings, EP, dfrev)
        end
        CSV.read(joinpath(dir, "CapacityCredit.csv"), DataFrame).CapRes_1
    end
    price = dual.(EP[:cCapacityResMargin][1, :])
    capresfactor = inputs["DERATING_FACTOR"][:, 1]
    built = value.(EP[:eTotalCap]) * GenX.ModelScalingFactor .>= 1
    for y in inputs["THERM_ALL"]
        @test credit[y] ≈ capresfactor[y]
    end
    for y in inputs["VRE"]
        if built[y]
            @test credit[y] ≈ capresfactor[y] * sum(price .* inputs["pP_Max"][y, :]) / sum(price)
        else
            @test ismissing(credit[y])
        end
    end
end

@testset "Annual formulation" begin
    EP, inputs, _ = run_case(test_path, annual_setup)
    test_objective(EP, 6860.8197, test_path * "_annual")
    tol = feasibility_tolerance(EP)

    # None of the hourly formulation objects are created
    @test !haskey(EP, :cCapacityResMargin)
    @test !haskey(EP, :eCapResMarBalance)
    @test !haskey(EP, :vCAPRES_discharge)

    # Requirement: (1 + margin) x coincident peak demand of the zones in the requirement
    pD = inputs["pD"]
    peak_t, requirement = GenX.annual_capacity_reserve_requirement(inputs)
    @test requirement[1] ≈ 1.15 * maximum(sum(pD, dims = 2))
    @test requirement[2] ≈ 1.15 * maximum(pD[:, 1])

    # Balance: accredited capacity + derated net imports (demand curtailment does not contribute)
    capresfactor = inputs["ANNUAL_DERATING_FACTOR"]
    capacity = value.(EP[:eTotalCap])
    transfer = value.(EP[:vCAPRES_TRANSFER])
    balance = value.(EP[:eCapResMarBalanceAnnual])
    @test balance[1] ≈ capresfactor[:, 1]' * capacity
    # Both lines leave MA, so flows out of MA (positive) are subtracted
    @test balance[2] ≈ capresfactor[:, 2]' * capacity - 0.95 * (transfer[1] + transfer[2])
    @test all(balance .>= requirement .- tol)

    # Peak transfers are limited by the line capacity
    line_capacity = value.(EP[:eAvail_Trans_Cap])
    @test all(abs(transfer[l]) <= line_capacity[l] + tol for l in 1:inputs["L"])

    # Transfers are backed by the firm capacity of the exporting zone (largest annual factor)
    firm = [sum(maximum(capresfactor[y, :]) * capacity[y]
                for y in GenX.resources_in_zone_by_rid(inputs["RESOURCES"], z))
            for z in 1:inputs["Z"]]
    @test value.(EP[:eCapResAnnualFirmCapacity]) ≈ firm
    net_export = inputs["pNet_Map"]' * [transfer[l] for l in 1:inputs["L"]]
    @test all(net_export .<= firm .+ tol)

    price = GenX.capacity_reserve_margin_price_annual(EP, annual_setup)
    @test all(price .>= 0)

    # Prices do not depend on the objective scaling
    scaled_setup = merge(annual_setup, Dict("ObjScale" => 0.01))
    EP_scaled, _, _ = run_case(test_path, scaled_setup)
    @test GenX.capacity_reserve_margin_price_annual(EP_scaled, scaled_setup)≈price rtol=1e-3

    # Outputs
    settings = merge(GenX.default_settings(), annual_setup)
    mktempdir() do dir
        redirect_stdout(devnull) do
            GenX.write_reserve_margin_annual(dir, inputs, settings, EP)
        end
        df = CSV.read(joinpath(dir, "ReserveMargin_annual.csv"), DataFrame)
        @test df.Peak_Time_Index == peak_t
        @test df.Requirement_MW ≈ requirement * GenX.ModelScalingFactor
        @test df.Accredited_Capacity_MW .+ df.Net_Import_MW ≈ balance * GenX.ModelScalingFactor
        @test df.Price_USD_per_MW_yr ≈ price

        dfrev = redirect_stdout(devnull) do
            GenX.write_reserve_margin_revenue_annual(dir, inputs, settings, EP)
        end
        for res in 1:2
            @test sum(dfrev[!, "CapRes_$res"]) ≈ price[res] * df.Accredited_Capacity_MW[res]
        end
        @test dfrev.AnnualSum ≈ dfrev.CapRes_1 .+ dfrev.CapRes_2

        # With the annual formulation, the capacity credit is the annual derating factor
        redirect_stdout(() -> GenX.write_capacity_credit(dir, inputs, settings, EP), devnull)
        credit = CSV.read(joinpath(dir, "CapacityCredit.csv"), DataFrame)
        built = findall(>=(1), capacity * GenX.ModelScalingFactor)
        for res in 1:2
            @test credit[built, "CapRes_$res"] ≈ capresfactor[built, res]
        end
    end
end

@testset "Annual formulation requires annual derating factors" begin
    with_case_copy(test_path) do case
        file = joinpath(case, "resources", "policy_assignments",
            "Resource_capacity_reserve_margin.csv")
        CSV.write(file, select(CSV.read(file, DataFrame), Not(r"^Annual")))
        settings = merge(GenX.default_settings(), annual_setup)
        @test_throws ErrorException redirect_stdout(() -> GenX.load_inputs(settings, case),
            devnull)
    end
end

@testset "Annual derating factors must be between 0 and 1" begin
    settings = merge(GenX.default_settings(), annual_setup)
    for bad in ("1.2", "-0.1", "NaN", "")
        with_case_copy(test_path) do case
            file = joinpath(case, "resources", "policy_assignments",
                "Resource_capacity_reserve_margin.csv")
            lines = readlines(file)
            # Annual_Derating_Factor_1 of MA_natural_gas_combined_cycle
            cells = split(lines[2], ",")
            cells[4] = bad
            lines[2] = join(cells, ",")
            write(file, join(lines, "\n") * "\n")
            @test_throws "MA_natural_gas_combined_cycle (Annual_Derating_Factor_1" redirect_stdout(
                () -> GenX.load_inputs(settings, case), devnull)
        end
    end
end

@testset "Annual formulation: transfers need firm capacity in the exporting zone" begin
    with_case_copy(test_path) do case
        # ME (end of line 2, MA_to_ME) has no accredited capacity
        file = joinpath(case, "resources", "policy_assignments",
            "Resource_capacity_reserve_margin.csv")
        df = CSV.read(file, DataFrame)
        me = startswith.(df.Resource, "ME_")
        df[me, :Annual_Derating_Factor_1] .= 0.0
        df[me, :Annual_Derating_Factor_2] .= 0.0
        CSV.write(file, df)
        EP, inputs, _ = run_case(case, annual_setup)
        tol = feasibility_tolerance(EP)
        @test value(EP[:eCapResAnnualFirmCapacity][3])≈0 atol=tol
        # So ME cannot export firm capacity to MA (a negative transfer flows from ME to MA)...
        @test value(EP[:vCAPRES_TRANSFER][2]) >= -tol
        # ...and the MA requirement is met with local capacity and imports from CT
        _, requirement = GenX.annual_capacity_reserve_requirement(inputs)
        @test value(EP[:eCapResMarBalanceAnnual][2]) >= requirement[2] - tol
    end
end

# Helpers to change the requirements and the transmission inputs of a copy of the test case
function write_requirements!(case, margins::Matrix{Float64})
    rows = ["MA,z1", "CT,z2", "ME,z3"]
    header = "," * join(["Network_zones"; ["CapRes_$r" for r in 1:size(margins, 2)]], ",")
    write(joinpath(case, "policies", "Capacity_reserve_margin.csv"),
        join([header; [rows[z] * "," * join(margins[z, :], ",") for z in 1:3]], "\n") * "\n")
end
function set_network!(case; excl::Matrix{Int}, derate::Matrix{Float64},
        max_reinforcement::Union{Nothing, Float64} = nothing)
    file = joinpath(case, "system", "Network.csv")
    df = CSV.read(file, DataFrame)
    for r in 1:size(excl, 2)
        df[!, "CapRes_Excl_$r"] = [l <= 2 ? excl[l, r] : missing for l in 1:3]
        df[!, "DerateCapRes_$r"] = [l <= 2 ? derate[l, r] : missing for l in 1:3]
    end
    if !isnothing(max_reinforcement)
        df.Line_Max_Reinforcement_MW = [l <= 2 ? max_reinforcement : missing for l in 1:3]
    end
    CSV.write(file, df)
end
# Annual factors of the base case for the requirements covering the resource's zone, zero otherwise
in_region_factors(regions) = (name, base, r) -> any(startswith(name, z * "_") for z in regions[r]) ?
                                                base : 0.0
function set_factors!(case, factor::Function, NCRM::Int)
    file = joinpath(case, "resources", "policy_assignments",
        "Resource_capacity_reserve_margin.csv")
    df = CSV.read(file, DataFrame)
    for r in 1:NCRM
        df[!, "Annual_Derating_Factor_$r"] = [factor(name, base, r)
                                              for (name, base) in zip(df.Resource,
            df.Annual_Derating_Factor_1)]
    end
    CSV.write(file, df)
end

@testset "Annual formulation: transit over lines inside the requirement regions" begin
    with_case_copy(test_path) do case
        # CapRes_2 covers CT only, whose only boundary line is MA_to_CT (line 1, entering CT).
        # MA_to_ME (line 2) does not cross any boundary. No resource is accredited to CapRes_2 and
        # MA resources are not accredited at all, so the CT requirement must be met with capacity
        # from ME, through MA. The lines can be expanded enough to carry it.
        write_requirements!(case, [0.15 0; 0.15 0.15; 0.15 0])
        set_network!(case; excl = [0 -1; 0 0], derate = fill(0.95, 2, 2),
            max_reinforcement = 8000.0)
        set_factors!(case,
            (name, base, r) -> r == 1 && !startswith(name, "MA_") ? base : 0.0, 2)
        EP, inputs, _ = run_case(case, annual_setup)
        tol = feasibility_tolerance(EP)
        factor = inputs["ANNUAL_DERATING_FACTOR"]
        MA = findall(startswith("MA_"), inputs["RESOURCE_NAMES"])
        @test all(iszero, factor[:, 2])
        @test all(iszero, factor[MA, :])
        @test termination_status(EP) == JuMP.MOI.OPTIMAL
        @test GenX.annual_capacity_reserve_transfer_lines(inputs) == [1, 2]
        transfer = value.(EP[:vCAPRES_TRANSFER])
        _, requirement = GenX.annual_capacity_reserve_requirement(inputs)
        @test 0.95 * transfer[1] >= requirement[2] - tol   # imports from MA cover the CT requirement
        @test transfer[2] <= -transfer[1] + tol            # and come from ME, through MA
    end
end

@testset "Annual formulation: transmission inputs are validated" begin
    margins = [0.15 0.15 0; 0.15 0 0.15; 0.15 0 0.15]  # all zones, MA, and CT + ME
    cases = [
        # MA_to_CT leaves MA, so CapRes_Excl_2 must be 1
        (excl = [0 -1 0; 0 1 0], derate = fill(0.95, 2, 3), message = "line 1 has CapRes_Excl_2"),
        # Both lines cross the boundaries of CapRes_2 and CapRes_3, but line 2 is only
        # eligible for CapRes_2
        (excl = [0 1 -1; 0 1 0], derate = fill(0.95, 2, 3),
            message = "line 2 crosses the boundaries of CapRes_2, CapRes_3"),
        # The boundary lines of CapRes_2 have different derating factors
        (excl = [0 1 -1; 0 1 -1], derate = [0.95 0.95 0.95; 0.95 0.5 0.95],
            message = "different DerateCapRes_2"),
        # The same lines have different derating factors for MA and for CT + ME, so a transfer
        # would add 1.0 MW to CT + ME for each 0.95 MW it removes from MA
        (excl = [0 1 -1; 0 1 -1], derate = [0.95 0.95 1.0; 0.95 0.95 1.0],
            message = "line 1 has different DerateCapRes values for CapRes_2")]
    for c in cases
        with_case_copy(test_path) do case
            write_requirements!(case, margins)
            set_network!(case; excl = c.excl, derate = c.derate)
            set_factors!(case, in_region_factors([["MA", "CT", "ME"], ["MA"], ["CT", "ME"]]), 3)
            @test_throws c.message run_case(case, annual_setup)
        end
    end
end

@testset "Annual derating factors are zero outside the requirement's zones" begin
    with_case_copy(test_path) do case
        # CT_onshore_wind (zone 2) accredited to CapRes_2, which covers MA only
        file = joinpath(case, "resources", "policy_assignments",
            "Resource_capacity_reserve_margin.csv")
        df = CSV.read(file, DataFrame)
        df[df.Resource .== "CT_onshore_wind", :Annual_Derating_Factor_2] .= 0.2
        CSV.write(file, df)
        settings = merge(GenX.default_settings(), annual_setup)
        @test_throws "CT_onshore_wind (zone 2, Annual_Derating_Factor_2)" redirect_stdout(
            () -> GenX.load_inputs(settings, case), devnull)
    end
end

@testset "Annual formulation: exporters covered by their own requirement" begin
    # In the base case, CT and ME export to the MA requirement but are only covered by the
    # system-wide requirement, so their exports are not subtracted from their own requirement
    settings = merge(GenX.default_settings(), annual_setup)
    inputs = redirect_stdout(() -> GenX.load_inputs(settings, test_path), devnull)
    @test GenX.annual_capacity_reserve_uncovered_exports(inputs) ==
          [(zone = 2, line = 1, requirement = 2), (zone = 3, line = 2, requirement = 2)]

    # With a requirement for CT + ME, whose boundary lines are the same, the exports are subtracted
    with_case_copy(test_path) do case
        write_requirements!(case, [0.15 0.15 0; 0.15 0 0.15; 0.15 0 0.15])
        set_network!(case; excl = [0 1 -1; 0 1 -1], derate = fill(0.95, 2, 3))
        set_factors!(case, in_region_factors([["MA", "CT", "ME"], ["MA"], ["CT", "ME"]]), 3)
        EP, inputs, _ = run_case(case, annual_setup)
        tol = feasibility_tolerance(EP)
        @test isempty(GenX.annual_capacity_reserve_uncovered_exports(inputs))
        transfer = value.(EP[:vCAPRES_TRANSFER])
        capacity = value.(EP[:eCapResAnnualCapacity])
        factor = inputs["ANNUAL_DERATING_FACTOR"]
        _, requirement = GenX.annual_capacity_reserve_requirement(inputs)
        balance = value.(EP[:eCapResMarBalanceAnnual])
        # CT + ME: local capacity minus what they send to MA (negative transfers)
        @test balance[3] ≈ factor[:, 3]' * capacity + 0.95 * (transfer[1] + transfer[2])
        @test all(balance .>= requirement .- tol)
    end
end

@testset "Annual formulation with slack" begin
    with_case_copy(test_path) do case
        CSV.write(joinpath(case, "policies", "Capacity_reserve_margin_slack.csv"),
            DataFrame(CRM_Constraint = ["CapRes_1", "CapRes_2"], PriceCap = [1000.0, 9999.0]))
        EP, _, _ = run_case(case, annual_setup)
        # Meeting CapRes_1 costs more at the margin (~29,000 $/MW-yr) than violating it, so the
        # slack is used and sets the price of the requirement
        @test value(EP[:vCapResSlack][1]) > 0
        @test GenX.capacity_reserve_margin_price_annual(EP, annual_setup)[1]≈1000 rtol=1e-4
    end
end

@testset "Annual formulation with electrolyzers" begin
    with_case_copy("electrolyzer") do case
        write(joinpath(case, "policies", "Capacity_reserve_margin.csv"),
            ",Network_zones,CapRes_1\nNE,z1,0.15\n")
        write(joinpath(case, "resources", "policy_assignments",
                "Resource_capacity_reserve_margin.csv"),
            """
            Resource,Annual_Derating_Factor_1
            natural_gas_combined_cycle,0.93
            solar_pv,0.3
            onshore_wind,0.2
            battery,0.8
            battery_for_electrolyzer,0.8
            electrolyzer,1.0
            """)
        setup = Dict("Trans_Loss_Segments" => 1,
            "UCommit" => 2,
            "StorageLosses" => 1,
            "ParameterScale" => 1,
            "HourlyMatchingRequirement" => 1,
            "HydrogenMinimumProduction" => 1,
            "CapacityReserveMargin" => 2)
        EP, inputs, _ = run_case(case, setup)
        # HiGHS reports an unknown model status for this case (also without the capacity reserve
        # margin), so only check that a feasible solution was found
        @test primal_status(EP) == JuMP.MOI.FEASIBLE_POINT

        # The electrolyzer capacity increases the requirement, including the reserve margin
        y = only(inputs["ELECTROLYZER"])
        @test normalized_coefficient(EP[:cCapacityResMarginAnnual][1], EP[:vCAP][y]) ≈ -1.15
        @test value(EP[:eTotalCap][y]) > 0
        @test value(EP[:eCapResAnnualElectrolyzer][1]) ≈ 1.15 * value(EP[:eTotalCap][y])
    end
end

@testset "Annual formulation with co-located VRE and storage" begin
    setup = Dict("NetworkExpansion" => 1,
        "UCommit" => 2,
        "CO2Cap" => 1,
        "StorageLosses" => 1,
        "VirtualChargeDischargeCost" => 1,
        "ParameterScale" => 1,
        "CapacityReserveMargin" => 2)
    # For testing, use the hourly derating factors as annual factors
    function add_annual_factors!(case)
        file = joinpath(case, "resources", "policy_assignments",
            "Resource_capacity_reserve_margin.csv")
        df = CSV.read(file, DataFrame)
        for res in 1:3
            df[!, "Annual_Derating_Factor_$res"] = df[!, "Derating_Factor_$res"]
        end
        CSV.write(file, df)
    end
    # Capacity that the components of co-located resource y can deliver to the grid
    function deliverable(EP, inputs, y)
        gen = inputs["RESOURCES"]
        cap(sym) = value(EP[sym][y])
        dc = 0.0
        if y in inputs["VS_DC"]
            dc_sources = (y in inputs["VS_SOLAR"] ? cap(:eTotalCap_SOLAR) : 0.0) +
                         (y in inputs["VS_SYM_DC"] ?
                          GenX.power_to_energy_dc(gen[y]) * cap(:eTotalCap_STOR) : 0.0) +
                         (y in inputs["VS_ASYM_DC_DISCHARGE"] ?
                          cap(:eTotalCapDischarge_DC) : 0.0)
            dc = min(cap(:eTotalCap_DC), GenX.etainverter(gen[y]) * dc_sources)
        end
        ac = (y in inputs["VS_WIND"] ? cap(:eTotalCap_WIND) : 0.0) +
             (y in inputs["VS_SYM_AC"] ?
              GenX.power_to_energy_ac(gen[y]) * cap(:eTotalCap_STOR) : 0.0) +
             (y in inputs["VS_ASYM_AC_DISCHARGE"] ? cap(:eTotalCapDischarge_AC) : 0.0)
        return min(cap(:eTotalCap), ac + dc)
    end
    credited(inputs) = filter(y -> any(!=(0), inputs["ANNUAL_DERATING_FACTOR"][y, :]),
        inputs["VRE_STOR"])

    # The credited capacity is bounded by the grid connection and by the components
    with_case_copy(joinpath("VRE_storage", "solar_wind")) do case
        add_annual_factors!(case)
        EP, inputs, _ = run_case(case, setup)
        tol = feasibility_tolerance(EP)
        VS = credited(inputs)
        @test !isempty(VS)
        for y in VS
            @test value(EP[:vCAPRES_ANNUAL_VS][y]) <= deliverable(EP, inputs, y) + tol
        end
    end

    # A grid connection without components is not credited: 1000 MW of existing grid connection
    # for each co-located resource, no existing components and no new builds
    with_case_copy(joinpath("VRE_storage", "solar_wind")) do case
        add_annual_factors!(case)
        file = joinpath(case, "resources", "Vre_stor.csv")
        df = CSV.read(file, DataFrame)
        df.New_Build .= 0
        df.Can_Retire .= 0
        df.Existing_Cap_MW .= 1000.0
        for col in names(df)
            if (startswith(col, "Existing_Cap_") && col != "Existing_Cap_MW") ||
               startswith(col, "Min_Cap_")
                df[!, col] .= 0
            end
        end
        CSV.write(file, df)
        EP, inputs, _ = run_case(case, setup)
        tol = feasibility_tolerance(EP)
        for y in credited(inputs)
            @test value(EP[:eTotalCap][y]) * GenX.ModelScalingFactor≈1000 rtol=1e-6
            @test deliverable(EP, inputs, y)≈0 atol=tol
            @test value(EP[:vCAPRES_ANNUAL_VS][y])≈0 atol=tol
        end
    end
end

@testset "Annual formulation with multi-stage (DDP)" begin
    with_case_copy("multi_stage") do case
        for p in 1:3
            dir = joinpath(case, "inputs_p$p")
            write(joinpath(dir, "policies", "Capacity_reserve_margin.csv"),
                ",Network_zones,CapRes_1\nNE,z1,0.15\n")
            mkpath(joinpath(dir, "resources", "policy_assignments"))
            write(joinpath(dir, "resources", "policy_assignments",
                    "Resource_capacity_reserve_margin.csv"),
                """
                Resource,Annual_Derating_Factor_1
                natural_gas_combined_cycle,0.93
                solar_pv,0.3
                onshore_wind,0.2
                battery,0.8
                """)
        end
        multistage_setup = Dict("NumStages" => 3,
            "StageLengths" => [10, 10, 10],
            "DiscountRate" => 0.045,
            "ConvergenceTolerance" => 0.01,
            "Myopic" => 0,
            "WriteIntermittentOutputs" => 0)
        setup = Dict("Trans_Loss_Segments" => 1,
            "OperationalReserves" => 1,
            "CO2Cap" => 2,
            "StorageLosses" => 1,
            "ParameterScale" => 1,
            "UCommit" => 2,
            "MultiStage" => 1,
            "MultiStageSettingsDict" => multistage_setup,
            "CapacityReserveMargin" => 2)
        # Run from the temporary copy: the DDP algorithm writes to the relative folder "results"
        EP, inputs, _ = cd(case) do
            mkpath("results")
            run_case(case, setup)
        end
        settings = merge(GenX.default_settings(), setup)
        for p in 1:3
            # The requirement is met in every stage
            _, requirement = GenX.annual_capacity_reserve_requirement(inputs[p])
            @test value(EP[p][:eCapResMarBalanceAnnual][1]) >=
                  requirement[1] - feasibility_tolerance(EP[p])

            # The outputs that do not depend on prices are written for multi-stage runs
            mktempdir() do dir
                redirect_stdout(devnull) do
                    GenX.write_reserve_margin_annual(dir, inputs[p], settings, EP[p])
                    GenX.write_capacity_credit(dir, inputs[p], settings, EP[p])
                end
                df = CSV.read(joinpath(dir, "ReserveMargin_annual.csv"), DataFrame)
                @test df.Requirement_MW ≈ requirement * GenX.ModelScalingFactor
                @test !("Price_USD_per_MW_yr" in names(df))
                credit = CSV.read(joinpath(dir, "CapacityCredit.csv"), DataFrame).CapRes_1
                built = findall(>=(1), value.(EP[p][:eTotalCap]) * GenX.ModelScalingFactor)
                @test credit[built] ≈ inputs[p]["ANNUAL_DERATING_FACTOR"][built, 1]
            end
        end
    end
end

@testset "Annual formulation with Benders decomposition" begin
    with_case_copy(joinpath("benders", "4_three_zones_w_policies_slack")) do case
        file = joinpath(case, "resources", "policy_assignments",
            "Resource_capacity_reserve_margin.csv")
        df = CSV.read(file, DataFrame)
        df.Annual_Derating_Factor_1 = [occursin(r"solar|wind", name) ? 0.25 : factor
                                       for (name, factor) in zip(df.Resource, df.Derating_Factor_1)]
        CSV.write(file, df)
        settings_file = joinpath(case, "settings", "genx_settings.yml")
        settings = YAML.load_file(settings_file)
        merge!(settings, Dict("CapacityReserveMargin" => 2, "Benders" => 1, "OverwriteResults" => 1))
        YAML.write_file(settings_file, settings)
        redirect_stdout(() -> run_genx_case!(case, HiGHS.Optimizer), devnull)

        # Outputs of the incumbent planning solution, without shadow prices
        results = joinpath(case, "results_benders")
        df = CSV.read(joinpath(results, "ReserveMargin_annual.csv"), DataFrame)
        @test !("Price_USD_per_MW_yr" in names(df))
        @test all(df.Accredited_Capacity_MW .+ df.Net_Import_MW .+ df.Slack_MW .>=
                  df.Requirement_MW .- 1e-3)
        @test isfile(joinpath(results, "CapacityCredit.csv"))

        # The slack penalty is part of the planning costs
        slack = CSV.read(joinpath(results, "ReserveMargin_slack_and_penalties.csv"), DataFrame)
        costs = CSV.read(joinpath(results, "planning_problem_costs.csv"), DataFrame)
        penalty = only(costs[costs.Costs .== "cUnmetPlanningPolicyPenalty", :Total])
        @test sum(slack.Penalty) > 0
        @test penalty >= sum(slack.Penalty) * (1 - 1e-6)
    end
end

end # module TestCapacityReserveMargin
