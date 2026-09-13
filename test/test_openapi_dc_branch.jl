function _dc()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.dc_branch_csv_parser!(sys, data)
    return sys, data
end

@testset "one DC line named DC1" begin
    sys, _ = _dc()
    lines = PDP.get_components(sys, "TwoTerminalGenericHVDCLine")
    @test length(lines) == 1
    @test PDP.get_value(only(lines), :name) == "DC1"
    @test PDP.get_value(only(lines), :available)
end

@testset "the DC arc connects buses 113 and 316" begin
    sys, _ = _dc()
    reg = PDP.get_registry(sys)
    arc = only(PDP.get_components(sys, "Arc"))
    @test PDP.get_value(arc, :from_id) == PDP.get_bus_id(reg, 113)
    @test PDP.get_value(arc, :to_id) == PDP.get_bus_id(reg, 316)
end

@testset "power limits are populated from the descriptor" begin
    sys, _ = _dc()
    line = only(PDP.get_components(sys, "TwoTerminalGenericHVDCLine"))
    for field in (
        :active_power_limits_from,
        :active_power_limits_to,
        :reactive_power_limits_from,
        :reactive_power_limits_to,
    )
        limits = PDP.get_value(line, field)
        @test limits.max >= limits.min
    end
    # RTS states only MW Load = 100, so the limits are symmetric around zero.
    from = PDP.get_value(line, :active_power_limits_from)
    @test from.max ≈ 100.0
    @test from.min ≈ -100.0
end

@testset "the loss margin becomes a proportional curve" begin
    sys, _ = _dc()
    line = only(PDP.get_components(sys, "TwoTerminalGenericHVDCLine"))
    # `loss.value_curve` is a oneOf (`LossValueCurve`), so assignment wraps the curve.
    loss = PDP.get_value(line, :loss).value_curve.value
    @test loss.curve_type == "INPUT_OUTPUT"
    @test loss.function_data.value.proportional_term ≈ 0.1
    @test iszero(loss.function_data.value.constant_term)
end

@testset "make_dc_limits mirrors a stated maximum and rejects an empty pair" begin
    row = (min = nothing, max = 50.0, both_missing = nothing)
    @test PDP.make_dc_limits(row, :min, :max) == (min = -50.0, max = 50.0)
    @test PDP.make_dc_limits((min = -10.0, max = 50.0), :min, :max) ==
          (min = -10.0, max = 50.0)
    @test_throws IS.DataFormatError PDP.make_dc_limits(row, :both_missing, :min)
end
