const _HEX_HASH_RE = r"^[0-9a-f]{64}$"

function _built()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data)
end

# Staged rows grouped by the series they reference. The fan-out shares one
# series object across its owners, so those rows always group; separately
# constructed series never collide because no two entries agree on all of
# (name, resolution, data).
function _rows_by_series(rows)
    groups = Dict{IS.SingleTimeSeries, Vector{PDP.StagedTimeSeries}}()
    for row in rows
        push!(get!(groups, row.series, PDP.StagedTimeSeries[]), row)
    end
    return groups
end

@testset "category maps to candidate component types" begin
    @test "LoadZone" in PDP.category_to_type_names("LoadZone")
    @test "ThermalStandard" in PDP.category_to_type_names("Generator")
    @test !("Area" in PDP.category_to_type_names("LoadZone"))
    @test_throws IS.DataFormatError PDP.category_to_type_names("Weather")
end

@testset "one staged row per owner, both resolutions kept" begin
    sys = _built()
    # 260 pointer entries, of which the 6 zone load series fan out to the loads.
    @test length(sys.time_series) == 362
    @test length(_rows_by_series(sys.time_series)) == 260
    resolutions = Set(IS.get_resolution(row.series) for row in sys.time_series)
    @test resolutions ==
          Set([Dates.Millisecond(Dates.Hour(1)), Dates.Millisecond(Dates.Minute(5))])
end

@testset "keep_time_series_resolution! drops the other resolution" begin
    sys = _built()
    total = length(sys.time_series)
    hourly = count(r -> IS.get_resolution(r.series) == Dates.Hour(1), sys.time_series)
    @test 0 < hourly < total

    PDP.keep_time_series_resolution!(sys, Dates.Hour(1))
    @test length(sys.time_series) == hourly
    @test all(IS.get_resolution(r.series) == Dates.Hour(1) for r in sys.time_series)

    # The staging is what the sidecar is written from, so the drop reaches the store and
    # the document rows alike. Going through `write_time_series` is the real path: the rows
    # describe the catalog that was committed, not the staged objects.
    mktempdir() do dir
        rows = PDP.write_time_series(sys, joinpath(dir, "ts.h5"))
        @test length(rows) == hourly
    end

    # `nothing` keeps everything; a resolution nothing was staged at errors rather than
    # silently emptying the bundle.
    PDP.keep_time_series_resolution!(sys, nothing)
    @test length(sys.time_series) == hourly
    @test_throws IS.DataFormatError PDP.keep_time_series_resolution!(sys, Dates.Minute(5))
end

@testset "a multiplier becomes device-base units on normalized values" begin
    sys = _built()
    # Every RTS pointer entry declares a scaling_factor_multiplier, so every
    # series stores normalized values tagged with the device-base units label
    # in place of the removed multiplier metadata.
    @test all(
        IS.get_unit_system(row.series) == PDP.COMPONENT_BASE_UNIT_SYSTEM
        for row in sys.time_series
    )
    zone_rows = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    # Normalized by the zone peak: per-unit values, nothing above 1.
    for row in zone_rows
        @test maximum(IS.get_array(row.series)) <= 1.0
    end
end

@testset "a normalized series declares its basis and the quantity it scales to" begin
    sys = _built()
    # Every RTS pointer declares a multiplier, so every series is per unit on its owner's
    # own base. `units` stays unset: a per-unit basis is not a units label.
    for row in sys.time_series
        @test IS.get_unit_system(row.series) == PDP.COMPONENT_BASE_UNIT_SYSTEM
        @test isnothing(IS.get_units(row.series))
        @test !isnothing(IS.get_quantity_kind(row.series))
    end

    # The quantity is the multiplier's own, not the accessor name. RTS reservoirs are
    # accounted in ENERGY, so a level scales to energy and an inflow to power.
    by_name = Dict(
        IS.get_name(r.series) => IS.get_quantity_kind(r.series) for r in sys.time_series
    )
    @test by_name["max_active_power"] == "active_power"
    @test by_name["requirement"] == "active_power"
    @test by_name["storage_capacity"] == "energy"
    @test by_name["inflow"] == "power"
end

@testset "an unmapped or unnormalized multiplier is not silently unstated" begin
    sys = _built()
    reservoir = first(PDP.get_components(sys, "HydroReservoir"))
    entry = PDP.TimeSeriesPointer(
        "Component", "x", "inflow", 1.0, "f.csv", Dates.Hour(1), "get_weather",
    )
    @test_throws IS.DataFormatError PDP._series_quantity_kind(
        sys, entry, "HydroReservoir", PDP.get_value(reservoir, :id),
    )

    # No multiplier means no declared basis, so no quantity to name either.
    bare = PDP.TimeSeriesPointer(
        "Component", "x", "inflow", 1.0, "f.csv", Dates.Hour(1), nothing,
    )
    @test isnothing(
        PDP._series_quantity_kind(
            sys, bare, "HydroReservoir", PDP.get_value(reservoir, :id),
        ),
    )
    @test isnothing(PDP._series_unit_system(bare))
end

@testset "a zone's load series fans out to the loads under it" begin
    sys = _built()
    loads = [r for r in sys.time_series if r.owner_type == "PowerLoad"]
    # 51 loads at each of the two resolutions.
    @test length(loads) == 102

    zones = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    @test length(zones) == 6

    # The fan-out is rows against one shared series, not copied data.
    groups = _rows_by_series(vcat(loads, zones))
    @test length(groups) == 6
    for rows in values(groups)
        # One zone plus the loads beneath it share each series.
        @test count(r -> r.owner_type == "LoadZone", rows) == 1
        @test count(r -> r.owner_type == "PowerLoad", rows) == length(rows) - 1
    end
end

@testset "each fanned-out load belongs to the zone that owns the series" begin
    sys = _built()
    zone_of_bus = Dict(
        PDP.get_value(b, :id) => PDP.get_value(b, :load_zone) for
        b in PDP.get_components(sys, "ACBus")
    )
    zone_of_load = Dict(
        PDP.get_value(l, :id) => zone_of_bus[PDP.get_value(l, :bus)] for
        l in PDP.get_components(sys, "PowerLoad")
    )
    zone_by_series = Dict(
        r.series => r.owner_id for r in sys.time_series if r.owner_type == "LoadZone"
    )
    for row in sys.time_series
        if row.owner_type != "PowerLoad"
            continue
        end
        @test zone_of_load[row.owner_id] == zone_by_series[row.series]
    end
end

@testset "every staged owner resolves" begin
    sys = _built()
    ids = Set{Int}()
    for type_name in PDP.component_type_names(sys)
        union!(
            ids,
            Set(PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)),
        )
    end
    for row in sys.time_series
        @test row.owner_id in ids
        @test length(IS.get_array(row.series)) > 0
    end
end

@testset "LoadZone series resolve to the zone, not the area" begin
    sys = _built()
    zone_ids = Set(PDP.get_value(z, :id) for z in PDP.get_components(sys, "LoadZone"))
    zone_rows = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    @test length(zone_rows) == 6
    for row in zone_rows
        @test row.owner_id in zone_ids
    end
end

@testset "reserve requirements are associated with the reserve" begin
    sys = _built()
    reserve_rows = [r for r in sys.time_series if r.owner_type == "OnlineReserve"]
    @test length(reserve_rows) == 12
    @test all(r -> IS.get_name(r.series) == "requirement", reserve_rows)
    @test all(
        r -> IS.get_unit_system(r.series) == PDP.COMPONENT_BASE_UNIT_SYSTEM,
        reserve_rows,
    )
end

@testset "write_time_series persists the catalog and dedups arrays" begin
    sys = _built()
    mktempdir() do dir
        path = joinpath(dir, "ts.h5")
        PDP.write_time_series(sys, path)
        @test isfile(path)
        @test isfile(path * ".sqlite")

        store = InfraStore.open_store(path; read_only = true)
        try
            metadata = InfraStore.list_metadata(store)
            # One catalog row per staged association.
            @test length(metadata) == length(sys.time_series)

            # The arrays are content-addressed: the store holds exactly the
            # distinct value arrays that were staged, however many owners
            # reference each.
            staged_arrays = Set(IS.get_array(row.series) for row in sys.time_series)
            @test length(Set(m.data_hash for m in metadata)) == length(staged_arrays)

            # The device-base declaration survives the round trip. It rides on unit_system,
            # not the units label: a per-unit basis is not a unit.
            @test all(m.unit_system == InfraStore.ComponentBase for m in metadata)

            # A full value round trip for one association: resolve the catalog id from
            # the metadata already listed above, then read by id.
            row = first(r for r in sys.time_series if r.owner_type == "OnlineReserve")
            match = only(
                m for m in metadata if
                m.owner_type == row.owner_type &&
                m.owner_id == row.owner_id &&
                m.name == IS.get_name(row.series) &&
                m.resolution == IS.get_resolution(row.series)
            )
            stored = InfraStore.read_by_id(store, match.id)
            @test stored.data == IS.get_array(row.series)
            @test stored.initial_timestamp == IS.get_initial_timestamp(row.series)
        finally
            InfraStore.close!(store)
        end
    end
end

@testset "write_time_series orders its rows deterministically across builds" begin
    # The catalog is read back in raw store order, which is not guaranteed stable across
    # separate builds. `IS.openapi_time_series_association_rows` sorts by identity in the
    # store itself, so a document written twice lists its series identically.
    sys1 = _built()
    sys2 = _built()
    PDP.keep_time_series_resolution!(sys1, Dates.Hour(1))
    PDP.keep_time_series_resolution!(sys2, Dates.Hour(1))
    mktempdir() do dir
        rows1 = PDP.write_time_series(sys1, joinpath(dir, "ts1.h5"))
        rows2 = PDP.write_time_series(sys2, joinpath(dir, "ts2.h5"))
        key(row) = (row.value.owner_id, row.value.name)
        @test key.(rows1) == key.(rows2)
        @test issorted(key.(rows1))

        # The store speaks unit-style ISO durations (`PT1H`), not the seconds spelling
        # (`PT3600S`) IS's now-deleted `_openapi_duration` used to produce.
        @test all(row.value.resolution == "PT1H" for row in rows1)
        # `uri`/`data_hash` are the store's own content hash, not a caller-supplied
        # locator — the same hex string in both fields.
        @test all(occursin(_HEX_HASH_RE, row.value.uri) for row in rows1)
        @test all(row.value.data_hash == row.value.uri for row in rows1)
        @test all(occursin(_HEX_HASH_RE, row.value.uri) for row in rows2)
        @test all(row.value.data_hash == row.value.uri for row in rows2)
    end
end
