function _rts_system()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data)
end

function _round_trip(sys)
    return mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        return JSON.parse(read(path, String))
    end
end

@testset "time_series_filename follows the PSY sibling convention" begin
    @test PDP.time_series_filename("rts.json") == "rts_time_series_storage.h5"
    @test PDP.time_series_filename("/a/b/rts.json") == "rts_time_series_storage.h5"
end

@testset "to_json writes the document and the sidecar pair" begin
    sys = _rts_system()
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        @test isfile(path)
        @test isfile(joinpath(dir, "rts_time_series_storage.h5"))
        @test isfile(joinpath(dir, "rts_time_series_storage.h5.sqlite"))
    end
end

@testset "to_json refuses to overwrite without force" begin
    sys = PDP.OpenAPISystem(100.0)
    mktempdir() do dir
        path = joinpath(dir, "x.json")
        PDP.to_json(sys, path)
        # PD.write_document owns the "already exists" check for the JSON path now.
        @test_throws PDP.IC.DocumentFormatError PDP.to_json(sys, path)
        PDP.to_json(sys, path; force = true)
        @test isfile(path)
    end
end

@testset "components serialize as objects, not encoded strings" begin
    doc = _round_trip(_rts_system())
    bus = doc["components"]["ACBus"][1]
    @test haskey(bus, "name")
    @test bus["base_voltage"] isa Number
    @test haskey(bus["voltage_limits"], "max")
    @test bus["voltage_limits"]["max"] isa Number
end

@testset "document top-level shape" begin
    doc = _round_trip(_rts_system())
    @test doc["components"]["Area"][1]["base_power"] == 100.0
    @test doc["time_series_storage_file"] == "rts_time_series_storage.h5"
    @test length(doc["components"]["ACBus"]) == 73
    # One row per staged series. The sidecar holds the values; these rows let a consumer see
    # what the bundle contains, and on what basis, without opening the store.
    rows = doc["time_series_associations"]
    @test length(rows) == 362
    row = first(rows)
    @test row["time_series_type"] == "SingleTimeSeries"
    @test row["owner_category"] == "Component"
    @test row["unit_system"] == "COMPONENT_BASE"
    @test !isempty(row["name"])
    # Every row points at a component the document declares.
    component_ids = Set(
        c["id"] for (_type, bucket) in doc["components"] for c in bucket
    )
    @test all(r -> r["owner_id"] in component_ids, rows)
    @test haskey(doc, "supplemental_attributes")
    @test haskey(doc, "supplemental_attribute_associations")
end

@testset "the sidecar catalog is authoritative for supplemental-attribute associations" begin
    sys = _rts_system()
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        doc = JSON.parse(read(path, String))
        doc_associations = doc["supplemental_attribute_associations"]
        @test !isempty(doc_associations)

        store = IS.open_infrastore_store(
            joinpath(dir, "rts_time_series_storage.h5");
            read_only = true,
        )
        try
            store_rows = IS.openapi_supplemental_attribute_association_rows(store)
            @test length(store_rows) == length(doc_associations)
            key(row) =
                (row.component_id, row.component_type, row.attribute_id, row.attribute_type)
            doc_key(row) =
                (
                    row["component_id"],
                    row["component_type"],
                    row["attribute_id"],
                    row["attribute_type"],
                )
            @test Set(key.(store_rows)) == Set(doc_key.(doc_associations))
        finally
            IS.close!(store)
        end
    end
end

@testset "nested cost objects survive one level of encoding" begin
    doc = _round_trip(_rts_system())
    gen = first(
        g for g in doc["components"]["ThermalStandard"] if g["name"] == "101_STEAM_3"
    )
    cost = gen["operation_cost"]
    @test cost["cost_type"] == "THERMAL"
    @test cost["variable_operation_cost"]["variable_cost_type"] == "FUEL"
    @test cost["variable_operation_cost"]["value_curve"]["curve_type"] == "INCREMENTAL"
    @test cost["variable_operation_cost"]["value_curve"]["function_data"]["x_coords"] isa
          Vector
end

@testset "unset optional properties are omitted, not null" begin
    sys = PDP.OpenAPISystem(100.0)
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :id, 1)
    PDP.set_value!(bus, :name, "Abel")
    PDP.set_value!(bus, :available, true)
    PDP.set_value!(bus, :number, 1)
    PDP.add_component!(sys, bus)
    doc = _round_trip(sys)
    @test !haskey(doc["components"]["ACBus"][1], "base_voltage")
    @test doc["components"]["ACBus"][1]["name"] == "Abel"
end

@testset "component type keys are sorted" begin
    sys = _rts_system()
    @test PDP.component_type_names(sys) == sort(PDP.component_type_names(sys))
end

@testset "pretty printing writes the same document" begin
    sys = _rts_system()
    mktempdir() do dir
        plain = joinpath(dir, "plain.json")
        pretty = joinpath(dir, "pretty.json")
        PDP.to_json(sys, plain)
        PDP.to_json(sys, pretty; pretty = true)
        # Only the whitespace differs; the trees are equal apart from the sidecar
        # name each document points at.
        left = JSON.parse(read(plain, String))
        right = JSON.parse(read(pretty, String))
        @test left["components"] == right["components"]
        @test right["time_series_storage_file"] == "pretty_time_series_storage.h5"
    end
end
