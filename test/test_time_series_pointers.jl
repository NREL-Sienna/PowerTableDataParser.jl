# Exercises the PowerTableDataParserPowerSystemsExt extension: pointer-file time series
# ingestion into a live PowerSystems.System, migrated from PowerSystemCaseBuilder.

import PowerSystems
import TimeSeries
const PSY = PowerSystems

# A zone with two loads and a shunt, plus a load outside the zone. `load1` also
# carries its own pointer entry, so the zone fan-out must skip it; `load3` has no
# entry of its own, so the fan-out is what gives it a series.
function _pointer_test_system()
    sys = PSY.System(100.0; time_series_in_memory = true)
    zone = PSY.LoadZone(;
        name = "Zone1",
        peak_active_power = 200.0,
        peak_reactive_power = 40.0,
    )
    PSY.add_component!(sys, zone)
    make_bus(number, name, load_zone) = PSY.ACBus(;
        number = number,
        name = name,
        available = true,
        bustype = PSY.ACBusTypes.REF,
        angle = 0.0,
        magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = 230.0,
        load_zone = load_zone,
    )
    bus1 = make_bus(1, "bus1", zone)
    bus2 = make_bus(2, "bus2", nothing)
    PSY.add_component!(sys, bus1)
    PSY.add_component!(sys, bus2)
    make_load(name, bus) = PSY.PowerLoad(;
        name = name,
        available = true,
        bus = bus,
        active_power = 0.8,
        reactive_power = 0.1,
        base_power = 100.0,
        max_active_power = 1.0,
        max_reactive_power = 0.2,
    )
    PSY.add_component!(sys, make_load("load1", bus1))
    PSY.add_component!(sys, make_load("load2", bus2))
    PSY.add_component!(sys, make_load("load3", bus1))
    PSY.add_component!(
        sys,
        PSY.FixedAdmittance(;
            name = "shunt1",
            available = true,
            bus = bus1,
            Y = 1.0 + 1.0im,
        ),
    )
    return sys
end

const _DIRECT_VALUES = [10.0, 20.0, 30.0, 40.0]
const _ZONE_VALUES = [100.0, 150.0, 200.0, 120.0]
const _PIVOTED_VALUES = [1.0, 2.0, 3.0, 4.0]

function _write_pointer_fixtures(dir)
    hours = ["00:00:00", "01:00:00", "02:00:00", "03:00:00"]
    open(joinpath(dir, "direct.csv"), "w") do io
        println(io, "DateTime,load1")
        for (h, v) in zip(hours, _DIRECT_VALUES)
            println(io, "2024-01-01T$h,$v")
        end
    end
    open(joinpath(dir, "zone.csv"), "w") do io
        println(io, "DateTime,Zone1")
        for (h, v) in zip(hours, _ZONE_VALUES)
            println(io, "2024-01-01T$h,$v")
        end
    end
    # Period-pivoted: one row per day, one column per 12-hour period, no
    # component-named column.
    open(joinpath(dir, "pivoted.csv"), "w") do io
        println(io, "Year,Month,Day,1,2")
        println(io, "2024,1,1,1.0,2.0")
        println(io, "2024,1,2,3.0,4.0")
    end

    entries = [
        Dict(
            "category" => "PowerLoad",
            "component_name" => "load1",
            "name" => "max_active_power",
            "normalization_factor" => 1.0,
            "data_file" => "direct.csv",
            "resolution" => 3600,
            "type" => "SingleTimeSeries",
        ),
        # Duplicate of the entry above; the store rejects duplicate associations,
        # so ingestion must skip it.
        Dict(
            "category" => "PowerLoad",
            "component_name" => "load1",
            "name" => "max_active_power",
            "normalization_factor" => 1.0,
            "data_file" => "direct.csv",
            "resolution" => 3600,
            "type" => "SingleTimeSeries",
        ),
        # Zonal shape: raw values for the zone itself, fanned out normalized and
        # rescaled to every load in the zone that has no series of its own.
        Dict(
            "category" => "LoadZone",
            "component_name" => "Zone1",
            "name" => "max_active_power",
            "normalization_factor" => 200.0,
            "scaling_factor_multiplier" => "get_max_active_power",
            "data_file" => "zone.csv",
            "resolution" => 3600,
            "type" => "SingleTimeSeries",
        ),
        Dict(
            "category" => "PowerLoad",
            "component_name" => "load2",
            "name" => "requirement",
            "normalization_factor" => 1.0,
            "data_file" => "pivoted.csv",
            "resolution" => 43200,
            "type" => "SingleTimeSeries",
        ),
        # Unsupported type: skipped, not an error.
        Dict(
            "category" => "PowerLoad",
            "component_name" => "load2",
            "name" => "forecast",
            "normalization_factor" => 1.0,
            "data_file" => "direct.csv",
            "resolution" => 3600,
            "type" => "Deterministic",
        ),
        # Unknown component: skipped.
        Dict(
            "category" => "PowerLoad",
            "component_name" => "no_such_load",
            "name" => "max_active_power",
            "normalization_factor" => 1.0,
            "data_file" => "direct.csv",
            "resolution" => 3600,
            "type" => "SingleTimeSeries",
        ),
    ]
    pointer_file = joinpath(dir, "timeseries_pointers.json")
    open(pointer_file, "w") do io
        JSON.print(io, entries)
    end
    return pointer_file
end

_ts_values(component, name) =
    PSY.get_time_series_values(PSY.SingleTimeSeries, component, name)

@testset "add_time_series_from_pointers! attaches pointer-file series" begin
    mktempdir() do dir
        pointer_file = _write_pointer_fixtures(dir)
        sys = _pointer_test_system()
        PDP.add_time_series_from_pointers!(sys, pointer_file)

        load1 = PSY.get_component(PSY.PowerLoad, sys, "load1")
        load2 = PSY.get_component(PSY.PowerLoad, sys, "load2")
        load3 = PSY.get_component(PSY.PowerLoad, sys, "load3")
        zone = PSY.get_component(PSY.LoadZone, sys, "Zone1")
        shunt = PSY.get_component(PSY.FixedAdmittance, sys, "shunt1")

        # Direct entry: no multiplier, so the values are the device quantities the file
        # states, nothing normalizes them and no basis is declared. The duplicate is dropped.
        @test _ts_values(load1, "max_active_power") ≈ _DIRECT_VALUES
        direct = PSY.get_time_series(PSY.SingleTimeSeries, load1, "max_active_power")
        @test isnothing(IS.get_unit_system(direct))
        @test isnothing(IS.get_quantity_kind(direct))

        # The zone's own series is the normalized shape, declared per unit on the
        # component's base and naming the quantity it scales to.
        shape = _ZONE_VALUES ./ 200.0
        @test _ts_values(zone, "max_active_power") ≈ shape
        zone_ts = PSY.get_time_series(PSY.SingleTimeSeries, zone, "max_active_power")
        @test IS.get_unit_system(zone_ts) == IS.CU
        @test IS.get_quantity_kind(zone_ts) == "active_power"
        @test isnothing(IS.get_units(zone_ts))

        # Fan-out: every load under the zone is associated with that same shape — one
        # array, not a scaled copy per load. load1 is skipped: it already carries a
        # series of that name. A `FixedAdmittance` is an `ElectricLoad` on a zone bus,
        # so it follows the shape too, matching the document path's own load types.
        for follower in (load3, shunt)
            @test _ts_values(follower, "max_active_power") ≈ shape
            ts = PSY.get_time_series(PSY.SingleTimeSeries, follower, "max_active_power")
            @test IS.get_unit_system(ts) == IS.CU
            @test IS.get_quantity_kind(ts) == "active_power"
        end
        @test _ts_values(load1, "max_active_power") ≈ _DIRECT_VALUES

        # load2 is outside the zone, so it never takes the zonal profile.
        @test !PSY.has_time_series(load2, PSY.SingleTimeSeries, "max_active_power")

        # Period-pivoted layout flattens row-major from the Year/Month/Day origin.
        ts = PSY.get_time_series(PSY.SingleTimeSeries, load2, "requirement")
        @test PSY.get_time_series_values(PSY.SingleTimeSeries, load2, "requirement") ≈
              _PIVOTED_VALUES
        @test IS.get_initial_timestamp(ts) == Dates.DateTime(2024, 1, 1)
        @test Dates.Millisecond(IS.get_resolution(ts)) ==
              Dates.Millisecond(Dates.Second(43200))

        # The Deterministic-typed entry was skipped.
        @test !PSY.has_time_series(load2, PSY.SingleTimeSeries, "forecast")
    end
end

@testset "add_time_series_from_pointers! resolution filter" begin
    mktempdir() do dir
        pointer_file = _write_pointer_fixtures(dir)
        sys = _pointer_test_system()
        PDP.add_time_series_from_pointers!(
            sys,
            pointer_file;
            resolution = Dates.Hour(1),
        )

        load1 = PSY.get_component(PSY.PowerLoad, sys, "load1")
        load2 = PSY.get_component(PSY.PowerLoad, sys, "load2")
        @test _ts_values(load1, "max_active_power") ≈ _DIRECT_VALUES
        # The 12-hour pivoted entry does not match the filter.
        @test !PSY.has_time_series(load2)
    end
end
