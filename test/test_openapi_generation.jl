function _generation()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.branch_csv_parser!(sys, data)
    PDP.dc_branch_csv_parser!(sys, data)
    PDP.gen_csv_parser!(sys, data)
    return sys, data
end

const GENERATOR_TYPES = [
    "ThermalStandard",
    "RenewableDispatch",
    "RenewableNonDispatch",
    "HydroTurbine",
    "HydroDispatch",
    "SynchronousCondenser",
    "EnergyReservoirStorage",
]

@testset "158 generators across the mapped types" begin
    sys, _ = _generation()
    counts = Dict(t => length(PDP.get_components(sys, t)) for t in GENERATOR_TYPES)
    @test sum(values(counts)) == 158
    @test counts["ThermalStandard"] == 73
    @test counts["HydroTurbine"] == 19
    @test counts["HydroDispatch"] == 1
    @test counts["SynchronousCondenser"] == 3
    @test counts["EnergyReservoirStorage"] == 1
    @test counts["RenewableNonDispatch"] == 31
end

@testset "hydro turbines get reservoirs, linked both ways" begin
    sys, _ = _generation()
    reservoirs = PDP.get_components(sys, "HydroReservoir")
    @test !isempty(reservoirs)
    turbine_ids =
        Set(PDP.get_value(t, :id) for t in PDP.get_components(sys, "HydroTurbine"))

    linked = Set{Int}()
    for reservoir in reservoirs
        @test PDP.get_value(reservoir, :level_data_type) == "ENERGY"
        downstream = PDP.get_value(reservoir, :downstream_turbines)
        upstream = PDP.get_value(reservoir, :upstream_turbines)
        # A reservoir links one way or the other, never neither.
        @test !isnothing(downstream) || !isnothing(upstream)
        for ids in (downstream, upstream)
            if !isnothing(ids)
                @test all(in(turbine_ids), ids)
                union!(linked, ids)
            end
        end
    end
    # Every turbine has at least a head reservoir.
    @test linked == turbine_ids
end

@testset "every generator bus reference resolves" begin
    sys, _ = _generation()
    bus_ids = Set(PDP.get_value(b, :id) for b in PDP.get_components(sys, "ACBus"))
    for type_name in GENERATOR_TYPES
        for gen in PDP.get_components(sys, type_name)
            @test PDP.get_value(gen, :bus) in bus_ids
        end
    end
end

@testset "thermal generators carry cost and limits" begin
    sys, _ = _generation()
    gen = first(PDP.get_components(sys, "ThermalStandard"))
    # operation_cost is a oneOf, so assignment wraps the cost in ThermalStandardOperationCost.
    @test PDP.get_value(gen, :operation_cost).value.cost_type == "THERMAL"
    limits = PDP.get_value(gen, :active_power_limits)
    @test limits.max >= limits.min
    @test PDP.get_value(gen, :base_power) > 0
end

@testset "a thermal unit's values match its CSV row" begin
    sys, _ = _generation()
    steam = first(
        g for g in PDP.get_components(sys, "ThermalStandard") if
        PDP.get_value(g, :name) == "101_STEAM_3"
    )
    limits = PDP.get_value(steam, :active_power_limits)
    @test limits.max ≈ 76.0
    @test limits.min ≈ 30.0
    # Base MVA, not the system base.
    @test PDP.get_value(steam, :base_power) ≈ 89.0
    @test PDP.get_value(steam, :rating) ≈ sqrt(76.0^2 + 30.0^2)
    @test PDP.get_value(steam, :prime_mover_type) == "ST"
    @test PDP.get_value(steam, :fuel) == "COAL"
    ramp = PDP.get_value(steam, :ramp_limits)
    @test ramp.up ≈ 2.0
    @test ramp.down ≈ 2.0
    time_limits = PDP.get_value(steam, :time_limits)
    @test time_limits.up ≈ 480.0
    @test time_limits.down ≈ 240.0
    # No Status at Start column in RTS, so the descriptor default applies.
    @test PDP.get_value(steam, :status) == "ONLINE"
    @test PDP.get_value(steam, :commitment_mode) == "COMMITTED"
end

@testset "synchronous condensers fall back to the system base" begin
    sys, _ = _generation()
    condensers = PDP.get_components(sys, "SynchronousCondenser")
    @test length(condensers) == 3
    for condenser in condensers
        # Base MVA is 0 upstream in RTS-GMLC; a zero base is unusable downstream.
        @test PDP.get_value(condenser, :base_power) ≈ 100.0
        @test PDP.get_value(condenser, :rating) ≈ 200.0
        limits = PDP.get_value(condenser, :reactive_power_limits)
        @test limits.max ≈ 200.0
    end
end

@testset "renewables carry a power factor and the mapped prime mover" begin
    sys, _ = _generation()
    for gen in PDP.get_components(sys, "RenewableNonDispatch")
        @test PDP.get_value(gen, :prime_mover_type) == "PVe"
        @test PDP.get_value(gen, :power_factor) ≈ 1.0
    end
    movers = Set(
        PDP.get_value(g, :prime_mover_type) for
        g in PDP.get_components(sys, "RenewableDispatch")
    )
    @test movers ⊆ Set(["PVe", "WT", "CP"])
end

@testset "storage levels are fractions of the stated capacity" begin
    sys, _ = _generation()
    battery = only(PDP.get_components(sys, "EnergyReservoirStorage"))
    # Max Volume 0.15 GWh becomes 150 MWh.
    @test PDP.get_value(battery, :storage_capacity) ≈ 150.0
    @test PDP.get_value(battery, :initial_storage_capacity_level) ≈ 0.5
    limits = PDP.get_value(battery, :storage_level_limits)
    @test iszero(limits.min)
    @test limits.max ≈ 1.0
    @test PDP.get_value(battery, :rating) ≈ 50.0
    # Inflow Limit 0.1 GW becomes 100 MW.
    @test PDP.get_value(battery, :input_active_power_limits).max ≈ 100.0
    efficiency = PDP.get_value(battery, :efficiency)
    @test efficiency.in ≈ 1.0
    @test efficiency.out ≈ 1.0
end

@testset "prime mover and fuel spellings map to enum values" begin
    @test PDP.prime_mover_type("STEAM") == "ST"
    @test PDP.prime_mover_type("CT") == "CT"
    @test PDP.prime_mover_type("RTPV") == "PVe"
    @test PDP.prime_mover_type("SYNC_COND") == "OT"
    @test PDP.thermal_fuel("NG") == "NATURAL_GAS"
    @test PDP.thermal_fuel("Oil") == "DISTILLATE_FUEL_OIL"
    @test PDP.thermal_fuel("Coal") == "COAL"
end

@testset "an unmapped generator type is an error, not a skip" begin
    sys = PDP.OpenAPISystem(100.0)
    gen = (name = "G", fuel = "Unobtanium", unit_type = "XX")
    @test_throws IS.DataFormatError PDP._make_generator(
        Val(:NotAType),
        sys,
        nothing,
        gen,
        1,
        nothing,
        nothing,
    )
end

@testset "every generator component satisfies its required properties" begin
    sys, _ = _generation()
    for type_name in vcat(GENERATOR_TYPES, "HydroReservoir")
        for component in PDP.get_components(sys, type_name)
            @test PDP.OpenAPI.check_required(component)
        end
    end
end
