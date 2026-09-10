@testset "RTS thermal cost is a FuelCurve, not a CostCurve" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(
        g for
        g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false)
        if g.fuel == "Coal"
    )
    cost = PDP.make_thermal_cost(data, gen)
    @test cost.cost_type == "THERMAL"
    @test cost.variable_operation_cost.value.variable_cost_type == "FUEL"
    @test cost.variable_operation_cost.value.fuel_cost > 0
    # $/MMBtu in the table, $/MBtu in the model.
    @test cost.variable_operation_cost.value.fuel_cost ≈ gen.fuel_price / 1000.0
    @test cost.variable_operation_cost.value.power_units.value == "NATURAL_UNITS"
    # Heat rates give an incremental curve over the output points.
    @test cost.variable_operation_cost.value.value_curve.value.curve_type == "INCREMENTAL"
    @test cost.variable_operation_cost.value.value_curve.value.function_data.value.function_type ==
          "PIECEWISE_STEP"
    @test cost.start_up.value > 0
    @test required_fields_populated(cost)
end

@testset "RTS uses the heat-rate columns" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    @test PDP.cost_columns(data) === PDP.COST_COLUMN_NAMES
end

@testset "create_pwl_cost preserves point order" begin
    curve = PDP.create_pwl_cost([(0.0, 0.0), (10.0, 100.0), (20.0, 250.0)])
    @test curve.function_type == "PIECEWISE_LINEAR"
    @test length(curve.points) == 3
    @test [p.x for p in curve.points] == [0.0, 10.0, 20.0]
    @test [p.y for p in curve.points] == [0.0, 100.0, 250.0]
end

@testset "create_pwinc_cost drops the first slope, which is the initial input" begin
    step = PDP.create_pwinc_cost([(0.0, 9.0), (10.0, 10.5), (20.0, 11.0)])
    @test step.function_type == "PIECEWISE_STEP"
    @test step.x_coords == [0.0, 10.0, 20.0]
    @test step.y_coords == [10.5, 11.0]
end

@testset "get_cost_pairs drops incomplete points" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false))
    pairs = PDP.get_cost_pairs(gen, PDP.COST_COLUMN_NAMES)
    @test !isempty(pairs)
    @test all(p -> !isnothing(p[1]) && !isnothing(p[2]), pairs)
    # RTS declares five output points, so no curve can exceed that.
    @test length(pairs) <= 5
end

@testset "cost point x values are MW, scaled off the active power maximum" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    steam = first(
        g for
        g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false)
        if g.name == "101_STEAM_3"
    )
    pairs = PDP.get_cost_pairs(steam, PDP.COST_COLUMN_NAMES)
    xs = [first(p) for p in pairs]
    # PMax is 76 MW and the last output point is 1.0, not the 89 MVA equipment base.
    @test last(xs) ≈ 76.0
    @test issorted(xs)
    @test first(xs) ≈ steam.output_point_0 * 76.0
end

@testset "linear and quadratic curves carry their discriminators" begin
    linear = PDP.linear_curve(3.0, 1.0)
    @test linear.curve_type == "INPUT_OUTPUT"
    @test linear.function_data.value.function_type == "LINEAR"
    @test linear.function_data.value.proportional_term ≈ 3.0
    @test linear.function_data.value.constant_term ≈ 1.0

    quad = PDP.quadratic_curve(1.0, 2.0, 3.0)
    @test quad.function_data.value.function_type == "QUADRATIC"
    @test quad.function_data.value.quadratic_term ≈ 1.0
end

@testset "create_poly_cost reads the coefficients it is given" begin
    base = (
        name = "G",
        heat_rate_a0 = 1.0,
        heat_rate_a1 = 2.0,
        heat_rate_a2 = 3.0,
    )
    @test PDP.create_poly_cost(base).function_data.value.function_type == "QUADRATIC"

    linear = merge(base, (heat_rate_a2 = nothing,))
    @test PDP.create_poly_cost(linear).function_data.value.constant_term ≈ 1.0

    proportional = merge(base, (heat_rate_a2 = nothing, heat_rate_a0 = nothing))
    @test iszero(PDP.create_poly_cost(proportional).function_data.value.constant_term)

    incomplete = merge(base, (heat_rate_a1 = nothing,))
    @test_throws IS.DataFormatError PDP.create_poly_cost(incomplete)
end

@testset "renewable heat-rate costs collapse to zero" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(
        g for
        g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false)
        if g.fuel == "Solar"
    )
    cost = PDP.make_renewable_cost(data, gen)
    @test cost.cost_type == "RENEWABLE"
    @test cost.variable_operation_cost.variable_cost_type == "COST"
    @test iszero(
        cost.variable_operation_cost.value_curve.value.function_data.value.proportional_term,
    )
end

@testset "hydro heat-rate costs are a FuelCurve" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(
        g for
        g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false)
        if g.fuel == "Hydro"
    )
    cost = PDP.make_hydro_cost(data, gen)
    @test cost.cost_type == "HYDRO_GEN"
    @test cost.variable_operation_cost.value.variable_cost_type == "FUEL"
    @test iszero(cost.fixed)
end
