@testset "set_value! stores a matching unit unchanged" begin
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test PDP.get_value(bus, :base_voltage) == 138.0
end

@testset "set_value! assigns units that have no conversion factor" begin
    # to_default is 0.0 for Angle and null for pu bases, so no factor exists.
    # Assignment must still work when source and target already agree.
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :angle, 0.3, "rad")
    @test PDP.get_value(bus, :angle) == 0.3

    line = PDP.stage(PDP.PO.Line)
    PDP.set_value!(line, :r, 0.003, "pu")
    @test PDP.get_value(line, :r) == 0.003
end

@testset "set_value! converts within a quantity" begin
    reserve = PDP.stage(PDP.PO.OnlineReserve)
    PDP.set_value!(reserve, :time_frame, 60.0, "min")
    @test PDP.get_value(reserve, :time_frame) ≈ 60.0

    storage = PDP.stage(PDP.PO.EnergyReservoirStorage)
    # `prime_mover_type`/`storage_technology_type` staged before the power/energy-family
    # field below, mirroring `make_storage`'s convention — see `_shadow` (units.jl).
    PDP.set_value!(storage, :prime_mover_type, "PS")
    PDP.set_value!(storage, :storage_technology_type, "OTHER_CHEM")
    PDP.set_value!(storage, :storage_capacity, 3600.0, "MJ")
    @test PDP.get_value(storage, :storage_capacity) ≈ 1.0
end

@testset "set_value! rejects a cross-quantity conversion" begin
    bus = PDP.stage(PDP.PO.ACBus)
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0, "MW")

    gen = PDP.stage(PDP.PO.ThermalStandard)
    @test_throws IS.DataFormatError PDP.set_value!(gen, :base_power, 100.0, "MWh")
end

@testset "set_value! converts degrees to radians" begin
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :angle, 180.0, "deg")
    @test PDP.get_value(bus, :angle) ≈ pi
    PDP.set_value!(bus, :angle, 0.0, "deg")
    @test PDP.get_value(bus, :angle) == 0.0
end

@testset "set_value! rejects pu, which needs a base rather than a factor" begin
    bus = PDP.stage(PDP.PO.ACBus)
    # magnitude is declared pu on base_voltage; kV cannot be converted into it.
    @test_throws IS.DataFormatError PDP.set_value!(bus, :magnitude, 138.0, "kV")
end

@testset "set_value! rejects units absent from the vocabulary" begin
    gen = PDP.stage(PDP.PO.ThermalStandard)
    @test_throws IS.DataFormatError PDP.set_value!(gen, :base_power, 100_000.0, "kW")
end

@testset "arity enforces the unit rule in both directions" begin
    bus = PDP.stage(PDP.PO.ACBus)
    @test_throws IS.DataFormatError PDP.set_value!(bus, :name, "Abel", "kV")
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0)

    PDP.set_value!(bus, :name, "Abel")
    PDP.set_value!(bus, :available, true)
    PDP.set_value!(bus, :number, 101)
    @test PDP.get_value(bus, :name) == "Abel"
    @test PDP.get_value(bus, :available)
    @test PDP.get_value(bus, :number) == 101
end

@testset "set_value! runs the generated property validation" begin
    bus = PDP.stage(PDP.PO.ACBus)
    @test_throws Exception PDP.set_value!(bus, :bustype, "Ref")
    PDP.set_value!(bus, :bustype, "REF")
    @test PDP.get_value(bus, :bustype) == "REF"
end

@testset "compound properties take the unit at object level" begin
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :voltage_limits, (min = 0.95, max = 1.05), "pu")
    @test PDP.get_value(bus, :voltage_limits).min == 0.95
    @test PDP.get_value(bus, :voltage_limits).max == 1.05

    gen = PDP.stage(PDP.PO.ThermalStandard)
    # `status` is a required enum field staged before the power-family fields below,
    # mirroring `make_thermal_generator`'s own convention.
    PDP.set_value!(gen, :status, "ONLINE")
    PDP.set_value!(gen, :active_power_limits, (min = 15.2, max = 76.0), "MW")
    @test PDP.get_value(gen, :active_power_limits).min == 15.2
    @test PDP.get_value(gen, :active_power_limits).max == 76.0

    PDP.set_value!(gen, :ramp_limits, (up = 3.0, down = 3.0), "MW/min")
    @test PDP.get_value(gen, :ramp_limits).up == 3.0
    @test PDP.get_value(gen, :ramp_limits).down == 3.0

    line = PDP.stage(PDP.PO.Line)
    PDP.set_value!(line, :b, (from = 0.0225, to = 0.0225), "pu")
    @test PDP.get_value(line, :b).from == 0.0225
end

@testset "compound properties convert every member" begin
    gen = PDP.stage(PDP.PO.ThermalStandard)
    PDP.set_value!(gen, :status, "ONLINE")
    PDP.set_value!(gen, :time_limits, (up = 120.0, down = 60.0), "min")
    @test PDP.get_value(gen, :time_limits).up ≈ 120.0
    @test PDP.get_value(gen, :time_limits).down ≈ 60.0
end

@testset "discriminated units are read off the instance" begin
    line = PDP.stage(PDP.PO.TwoTerminalLCCLine)
    PDP.set_value!(line, :parameter_units, "NATURAL_UNITS")
    PDP.set_value!(line, :r, 5.0, "ohm")
    @test PDP.get_value(line, :r) == 5.0

    other = PDP.stage(PDP.PO.TwoTerminalLCCLine)
    PDP.set_value!(other, :parameter_units, "COMPONENT_BASE")
    @test_throws IS.DataFormatError PDP.set_value!(other, :r, 5.0, "ohm")
    PDP.set_value!(other, :r, 0.01, "pu")
    @test PDP.get_value(other, :r) == 0.01
end

@testset "get_value returns the stored value and converts on request" begin
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test PDP.get_value(bus, :base_voltage) == 138.0
    @test PDP.get_value(bus, :base_voltage, "kV") == 138.0
    @test_throws IS.DataFormatError PDP.get_value(bus, :base_voltage, "MW")

    reserve = PDP.stage(PDP.PO.OnlineReserve)
    PDP.set_value!(reserve, :time_frame, 60.0, "min")
    @test PDP.get_value(reserve, :time_frame, "min") ≈ 60.0
end

@testset "a required oneOf field's shadow placeholder does not need it staged first" begin
    # Regression: `head_to_volume_factor` (`FunctionData`, a oneOf wrapper) and
    # `operation_cost` (`HydroReservoirOperationCost`, likewise) are both required and
    # deliberately left unstaged here. Resolving `storage_level_limits`'s discriminated
    # unit (on `level_data_type`) must not need either of them.
    reservoir = PDP.stage(PDP.PO.HydroReservoir)
    PDP.set_value!(reservoir, :id, 1)
    PDP.set_value!(reservoir, :name, "R1")
    PDP.set_value!(reservoir, :available, true)
    PDP.set_value!(reservoir, :level_data_type, "ENERGY")
    PDP.set_value!(reservoir, :storage_level_limits, (min = 0.0, max = 100.0), "MWh")
    @test PDP.get_value(reservoir, :storage_level_limits).max == 100.0
end

@testset "a discriminated compound field resolves its unit off the staged basis" begin
    # Regression: `FixedAdmittance.y` (`ComplexNumber`) is per-unit on `admittance_units`.
    # Once that basis is staged, the 4-argument set_value! must resolve and convert it
    # rather than reporting an unresolvable ("?") declared unit.
    shunt = PDP.stage(PDP.PO.FixedAdmittance)
    PDP.set_value!(shunt, :id, 2)
    PDP.set_value!(shunt, :name, "S1")
    PDP.set_value!(shunt, :available, true)
    PDP.set_value!(shunt, :bus, 1)
    PDP.set_value!(shunt, :admittance_units, "COMPONENT_MVAR")
    PDP.set_value!(shunt, :y, (real = 0.02, imag = 0.05), "MVAr")
    @test PDP.get_value(shunt, :y).real == 0.02
    @test PDP.get_value(shunt, :y).imag == 0.05
end
