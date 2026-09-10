function _services()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    # Reserve membership resolves eligibility rules against registered device components,
    # so generators must exist before services.
    PDP.gen_csv_parser!(sys, data)
    PDP.services_csv_parser!(sys, data)
    return sys, data
end

@testset "get_reserve_direction maps to the enum" begin
    @test PDP.get_reserve_direction("Up") == "UP"
    @test PDP.get_reserve_direction("Down") == "DOWN"
    @test PDP.get_reserve_direction(" up ") == "UP"
    @test_throws IS.DataFormatError PDP.get_reserve_direction("Sideways")
end

@testset "every reserve product is emitted" begin
    sys, data = _services()
    # One type covers every product now: constant-vs-variable was never a structural
    # difference, only whether a requirement time series is attached.
    n = length(PDP.get_components(sys, "OnlineReserve"))
    @test n == DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.RESERVE))
    @test n == 7
end

@testset "reserves carry direction, requirement and time frame" begin
    sys, _ = _services()
    for reserve in PDP.get_components(sys, "OnlineReserve")
        @test PDP.get_value(reserve, :reserve_direction) in ("UP", "DOWN")
        @test PDP.get_value(reserve, :requirement) >= 0
        @test PDP.get_value(reserve, :time_frame) > 0
        @test required_fields_populated(reserve)
    end
end

@testset "the time frame is converted from seconds to minutes" begin
    sys, _ = _services()
    reserves = Dict(
        PDP.get_value(r, :name) => r for r in PDP.get_components(sys, "OnlineReserve")
    )
    # Spin_Up_R1 states 600 s.
    @test PDP.get_value(reserves["Spin_Up_R1"], :time_frame) ≈ 10.0
    @test PDP.get_value(reserves["Spin_Up_R1"], :time_frame, "min") ≈ 10.0
    @test PDP.get_value(reserves["Spin_Up_R1"], :requirement) ≈ 40.413
    @test PDP.get_value(reserves["Reg_Down"], :reserve_direction) == "DOWN"
    @test PDP.get_value(reserves["Reg_Down"], :time_frame) ≈ 5.0
end

@testset "membership is normalized into dedicated association rows" begin
    sys, _ = _services()
    # The reserve-to-device link is many-to-many, so it is rows rather than a field on
    # either side: the component carries no `contributing_devices`.
    reserve = first(PDP.get_components(sys, "OnlineReserve"))
    @test !hasproperty(reserve, :contributing_devices)

    # Membership has its own table: a service is a component, not a supplemental
    # attribute, so the row's two ends resolve against different id sets. No filtering by
    # attribute_type — every row here is a membership.
    service_rows = PDP.get_service_associations(sys)
    @test !isempty(service_rows)
    reserve_ids = Set(
        PDP.get_value(r, :id) for r in PDP.get_components(sys, "OnlineReserve")
    )
    # Every row points at a reserve, and no pair repeats.
    pairs = Set{Tuple{Int, Int}}()
    for row in service_rows
        service_id = PDP.get_value(row, :service_id)
        @test service_id in reserve_ids
        pair = (service_id, PDP.get_value(row, :entity_id))
        @test !(pair in pairs)
        push!(pairs, pair)
    end

    # RTS scopes the three Spin_Up products by region, so together they cover the same
    # generator set as any one system-wide product.
    by_service = Dict{Int, Int}()
    for row in service_rows
        id = PDP.get_value(row, :service_id)
        by_service[id] = get(by_service, id, 0) + 1
    end
    named = Dict(
        PDP.get_value(r, :name) => by_service[PDP.get_value(r, :id)] for
        r in PDP.get_components(sys, "OnlineReserve")
    )
    @test named["Spin_Up_R1"] + named["Spin_Up_R2"] + named["Spin_Up_R3"] ==
          named["Reg_Up"]
end

@testset "a separately stated load is named apart from its bus load" begin
    sys = PDP.OpenAPISystem(100.0)
    reg = PDP.get_registry(sys)
    PDP.register!(reg, "PowerLoad", "Abel")
    @test PDP._load_name(reg, "Abel") == "load_Abel"
    @test PDP._load_name(reg, "Adams") == "Adams"
end
