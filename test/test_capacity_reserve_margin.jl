module TestCapacityReserveMargin

using Test

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
    test_objective(EP, 6860.7921, test_path * "_annual")
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

    price = GenX.capacity_reserve_margin_price_annual(EP, annual_setup)
    @test all(price .>= 0)

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
        EP, inputs, _ = run_case(case, setup)
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

end # module TestCapacityReserveMargin
