function _attributed()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data)
end

@testset "emissions become one attribute per pollutant a unit reports" begin
    sys = _attributed()
    emissions = PDP.get_supplemental_attributes(sys, "EmissionsData")
    @test length(emissions) == 336
    @test all(PDP.get_value(e, :basis) == "FUEL_INPUT" for e in emissions)
    @test all(PDP.get_value(e, :mass_unit) == "LB" for e in emissions)
    @test all(PDP.get_value(e, :energy_unit) == "MMBTU" for e in emissions)
    @test all(required_fields_populated(e) for e in emissions)

    # Particulates alone stay CUSTOM: the enum splits them by a size RTS omits.
    @test Set(PDP.get_value(e, :pollutant) for e in emissions) ==
          Set(["SO2", "NOX", "CO2", "CH4", "N2O", "CO", "VOC", "CUSTOM"])

    co2 = first(
        e for e in emissions if PDP.get_value(e, :name) == "101_CT_1_CO2"
    )
    # A constant rate is a constant incremental curve.
    curve = PDP.get_value(co2, :emission_rate).value
    @test curve.curve_type == "INCREMENTAL"
    @test curve.function_data.value.constant_term ≈ 160.0
    @test iszero(curve.function_data.value.proportional_term)
end

@testset "a unit-specific rate is not invented" begin
    sys = _attributed()
    names = Set(
        PDP.get_value(e, :name) for
        e in PDP.get_supplemental_attributes(sys, "EmissionsData")
    )
    # 101_STEAM_3 states "Unit-specific" for SO2, so no SO2 attribute exists...
    @test !("101_STEAM_3_SO2" in names)
    # ...but it does report CO2, which is a number.
    @test "101_STEAM_3_CO2" in names

    # The statement itself survives, in the column the descriptors do not claim.
    reg = PDP.get_registry(sys)
    extras = PDP.get_ext(sys, PDP.get_id(reg, "ThermalStandard", "101_STEAM_3"))
    @test extras["Fuel Sulfur Content %"] == "Unit-specific"
end

@testset "forced outages carry the geometric parameters the tables state" begin
    sys = _attributed()
    outages = PDP.get_supplemental_attributes(sys, "GeometricDistributionForcedOutage")
    # 94 generators and 120 branches state an outage rate.
    @test length(outages) == 214
    @test all(PDP.get_value(o, :outage_transition_probability) > 0 for o in outages)
    @test all(PDP.get_value(o, :mean_time_to_recovery) > 0 for o in outages)

    reg = PDP.get_registry(sys)
    by_entity = Dict(
        a.component_id => a.attribute_id for
        a in PDP.get_supplemental_attribute_associations(sys)
    )
    attributes = Dict(PDP.get_value(o, :id) => o for o in outages)

    # 101_CT_1 states MTTF 450 h and MTTR 50 h, both stated in minutes here.
    gen = attributes[by_entity[PDP.get_id(reg, "ThermalStandard", "101_CT_1")]]
    @test PDP.get_value(gen, :mean_time_to_recovery) == 3000
    @test PDP.get_value(gen, :outage_transition_probability) ≈ 1 / (450 * 60)
    mttr = PDP.get_value(gen, :mean_time_to_recovery)
    mttf = 1 / PDP.get_value(gen, :outage_transition_probability)
    @test mttr / (mttf + mttr) ≈ 0.1

    # A1 states 0.24 permanent outages a year over a 16 hour repair.
    line = attributes[by_entity[PDP.get_id(reg, "Line", "A1")]]
    @test PDP.get_value(line, :mean_time_to_recovery) == 960
    @test PDP.get_value(line, :outage_transition_probability) ≈ 0.24 / (8760 * 60)
end

@testset "every bus carries its position as GeoJSON" begin
    sys = _attributed()
    geo = PDP.get_supplemental_attributes(sys, "GeographicInfo")
    @test length(geo) == 73
    for attribute in geo
        point = PDP.get_value(attribute, :geo_json).additional_properties
        @test point["type"] == "Point"
        longitude, latitude = point["coordinates"]
        # RTS sits in the south-western United States.
        @test -120.0 < longitude < -110.0
        @test 30.0 < latitude < 40.0
    end
end

@testset "every attribute is associated with a component that exists" begin
    sys = _attributed()
    ids = Set{Int}()
    for type_name in PDP.component_type_names(sys)
        union!(ids, Set(PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)))
    end
    attribute_ids =
        Set(PDP.get_value(a, :id) for a in PDP.get_document(sys).supplemental_attributes)
    # Attribute ids come from the same counter as components, so they never collide.
    @test isempty(intersect(ids, attribute_ids))

    # D10: the unified table also carries service-membership rows (attribute_id names a
    # service *component*, not a supplemental attribute), so a row's attribute_id resolves
    # against one id space or the other, never neither.
    attribute_rows = filter(
        a -> PDP.get_value(a, :attribute_id) in attribute_ids,
        PDP.get_supplemental_attribute_associations(sys),
    )
    service_rows = filter(
        a -> PDP.get_value(a, :attribute_id) in ids,
        PDP.get_supplemental_attribute_associations(sys),
    )
    @test length(attribute_rows) == length(PDP.get_document(sys).supplemental_attributes)
    @test length(attribute_rows) + length(service_rows) ==
          length(PDP.get_supplemental_attribute_associations(sys))

    for association in PDP.get_supplemental_attribute_associations(sys)
        component_id = PDP.get_value(association, :component_id)
        attribute_id = PDP.get_value(association, :attribute_id)
        @test component_id in ids
        @test (attribute_id in attribute_ids) || (attribute_id in ids)
    end
end

@testset "columns the data model has no field for are kept, not dropped" begin
    sys = _attributed()
    reg = PDP.get_registry(sys)

    bus = PDP.get_ext(sys, PDP.get_bus_id(reg, 101))
    # RTS aliases the zone column to Area, leaving a real Zone column unread.
    @test haskey(bus, "Zone")
    @test haskey(bus, "Sub Area")

    line = PDP.get_ext(sys, PDP.get_id(reg, "Line", "A1"))
    @test line["Length"] ≈ 3.0

    gen = PDP.get_ext(sys, PDP.get_id(reg, "ThermalStandard", "101_STEAM_3"))
    @test gen["Inertia MJ/MW"] ≈ 3.0
    @test haskey(gen, "Damping Ratio")
    @test haskey(gen, "Unit Group")

    # The whole LCC description of the DC line survives even though the document
    # models it as a generic HVDC line.
    dc = PDP.get_ext(sys, PDP.get_id(reg, "TwoTerminalGenericHVDCLine", "DC1"))
    @test length(dc) == 44
    @test haskey(dc, "From Series Bridges")
    @test haskey(dc, "From R Commutating")
end

@testset "extras are keyed by component id and survive serialization" begin
    sys = _attributed()
    reg = PDP.get_registry(sys)
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        doc = JSON.parse(read(path, String))
        @test length(doc["ext"]) == length(PDP.get_document(sys).ext)
        line_id = PDP.get_id(reg, "Line", "A1")
        @test doc["ext"][string(line_id)]["Length"] ≈ 3.0
        @test length(doc["supplemental_attributes"]) == 623
        # One link row per attribute; the 510 service memberships are their own table now.
        @test length(doc["supplemental_attribute_associations"]) == 623
        @test length(doc["service_associations"]) == 510
    end
end

@testset "iterate_rows only reports extras when asked" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    plain = first(PDP.iterate_rows(data, PDP.InputCategory.BUS; per_unit = false))
    @test !hasproperty(plain, :ext)
    with_extras = first(
        PDP.iterate_rows(data, PDP.InputCategory.BUS; per_unit = false, extras = true),
    )
    @test hasproperty(with_extras, :ext)
    @test haskey(with_extras.ext, "Zone")
    # A declared column never appears twice.
    @test !haskey(with_extras.ext, "Bus ID")
end
