@testset "RTS-GMLC acceptance" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)

    @testset "component counts" begin
        @test length(PDP.get_components(sys, "ACBus")) == 73
        @test length(PDP.get_components(sys, "Area")) == 3
        @test length(PDP.get_components(sys, "LoadZone")) == 3
        @test length(PDP.get_components(sys, "Arc")) == 109
        @test length(PDP.get_components(sys, "Line")) == 105
        @test length(PDP.get_components(sys, "TwoWindingTransformer")) == 15
        @test length(PDP.get_components(sys, "TransformerCircuit")) == 15
        @test length(PDP.get_components(sys, "TwoTerminalGenericHVDCLine")) == 1
        @test length(PDP.get_components(sys, "ThermalStandard")) == 73
        @test length(PDP.get_components(sys, "HydroTurbine")) == 19
        @test length(PDP.get_components(sys, "HydroDispatch")) == 1
        @test length(PDP.get_components(sys, "RenewableNonDispatch")) == 31
        @test length(PDP.get_components(sys, "SynchronousCondenser")) == 3
        @test length(PDP.get_components(sys, "EnergyReservoirStorage")) == 1
        @test length(PDP.get_components(sys, "PowerLoad")) == 51
        @test length(PDP.get_components(sys, "OnlineReserve")) == 7
        @test length(sys.time_series) == 362
        @test length(Set(row.series for row in sys.time_series)) == 260
    end

    @testset "referential integrity" begin
        ids = Set{Int}()
        for type_name in PDP.component_type_names(sys)
            union!(
                ids,
                Set(PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)),
            )
        end
        arc_ids = Set(PDP.get_value(a, :id) for a in PDP.get_components(sys, "Arc"))
        bus_ids = Set(PDP.get_value(b, :id) for b in PDP.get_components(sys, "ACBus"))

        for bus in PDP.get_components(sys, "ACBus")
            @test PDP.get_value(bus, :area) in ids
            @test PDP.get_value(bus, :load_zone) in ids
        end
        for line in PDP.get_components(sys, "Line")
            @test PDP.get_value(line, :arc) in arc_ids
        end
        for gen in PDP.get_components(sys, "ThermalStandard")
            @test PDP.get_value(gen, :bus) in bus_ids
        end
        for row in sys.time_series
            @test row.owner_id in ids
        end
    end

    @testset "required properties are populated" begin
        for type_name in PDP.component_type_names(sys)
            for component in PDP.get_components(sys, type_name)
                @test required_fields_populated(component)
            end
        end
    end

    @testset "the sidecar pair, both resolutions" begin
        mktempdir() do dir
            path = joinpath(dir, "rts.json")
            PDP.to_json(sys, path; pretty = true)
            store_path = joinpath(dir, "rts_time_series_storage.h5")
            @test isfile(path)
            @test isfile(store_path)
            @test isfile(store_path * ".sqlite")
            store = InfraStore.open_store(store_path; read_only = true)
            try
                metadata = InfraStore.list_metadata(store)
                @test length(metadata) == length(sys.time_series)
                @test Set(m.resolution for m in metadata) == Set(
                    Dates.Millisecond.([Dates.Hour(1), Dates.Minute(5)]),
                )
            finally
                InfraStore.close!(store)
            end
        end
    end

    @testset "the tables' other data is carried, not dropped" begin
        # Emissions, forced outages and bus positions, none of which reach a
        # PowerSystems System from table data today.
        @test length(PDP.get_supplemental_attributes(sys, "EmissionsData")) == 336
        @test length(
            PDP.get_supplemental_attributes(sys, "GeometricDistributionForcedOutage"),
        ) == 214
        @test length(PDP.get_supplemental_attributes(sys, "GeographicInfo")) == 73
        # The unified table also carries the 510 service-membership rows below, so the
        # 623 plain attribute associations are counted by filtering on attribute_type.
        plain_attribute_types =
            Set(["EmissionsData", "GeometricDistributionForcedOutage", "GeographicInfo"])
        @test count(
            row -> PDP.get_value(row, :attribute_type) in plain_attribute_types,
            PDP.get_supplemental_attribute_associations(sys),
        ) == 623
        # Columns with no field at all are kept against their component.
        @test length(PDP.get_document(sys).ext) == 352
    end

    @testset "ext survives emission, not just the in-memory container" begin
        # serialize.jl used to hardcode "ext" => Dict{String,Any}() on write, silently
        # dropping every extra column. This checks the EMITTED document, not sys, so that
        # drop can never come back unnoticed.
        reg = PDP.get_registry(sys)
        mktempdir() do dir
            path = joinpath(dir, "rts.json")
            PDP.to_json(sys, path)
            doc = JSON.parse(read(path, String))
            @test length(doc["ext"]) == 352
            line_id = PDP.get_id(reg, "Line", "A1")
            @test doc["ext"][string(line_id)]["Length"] ≈ 3.0
        end
    end

    @testset "the emitted document round trips through PC" begin
        reg = PDP.get_registry(sys)
        mktempdir() do dir
            path = joinpath(dir, "rts.json")
            PDP.to_json(sys, path; pretty = true)
            read_back = PDP.PD.read_document(path)
            PDP.PD.validate_document(read_back)
            @test PDP.PD.component_type_names(read_back) == PDP.component_type_names(sys)
            @test length(PDP.PD.get_ext(read_back, PDP.get_id(reg, "Line", "A1"))) > 0
        end
    end

    @testset "reserve membership is rows, not a component property" begin
        # Reserve-to-device contribution is many-to-many, so it is emitted as rows in the
        # dedicated service_associations table rather than a field on the reserve.
        reserve = first(PDP.get_components(sys, "OnlineReserve"))
        @test !hasproperty(reserve, :contributing_devices)
        @test length(PDP.get_service_associations(sys)) == 510
    end
end
