function _bus(id::Int, name::AbstractString)
    bus = PDP.stage(PDP.PO.ACBus)
    PDP.set_value!(bus, :id, id)
    PDP.set_value!(bus, :name, name)
    PDP.set_value!(bus, :available, true)
    PDP.set_value!(bus, :number, id)
    return bus
end

@testset "OpenAPISystem starts empty" begin
    sys = PDP.OpenAPISystem(100.0)
    @test PDP.get_base_power(sys) == 100.0
    @test isempty(PDP.component_type_names(sys))
    @test isempty(sys.time_series)
    @test isempty(PDP.get_document(sys).supplemental_attributes)
    @test isempty(PDP.get_supplemental_attribute_associations(sys))
end

@testset "add_component! groups by type name" begin
    sys = PDP.OpenAPISystem(100.0)
    PDP.add_component!(sys, _bus(1, "Abel"))
    PDP.add_component!(sys, _bus(2, "Adams"))

    area = PDP.stage(PDP.PO.Area)
    PDP.set_value!(area, :id, 3)
    PDP.set_value!(area, :name, "1")
    PDP.set_value!(area, :base_power, 100.0, "MVA")
    PDP.add_component!(sys, area)

    @test PDP.component_type_names(sys) == ["ACBus", "Area"]
    @test length(PDP.get_components(sys, "ACBus")) == 2
    @test length(PDP.get_components(sys, "Area")) == 1
end

@testset "component_type_names is sorted for deterministic output" begin
    sys = PDP.OpenAPISystem(100.0)
    line = PDP.stage(PDP.PO.Line)
    PDP.set_value!(line, :id, 1)
    PDP.set_value!(line, :name, "L1")
    PDP.set_value!(line, :available, true)
    PDP.set_value!(line, :arc, 0)
    PDP.set_value!(line, :active_power_flow, 0.0, "MW")
    PDP.set_value!(line, :reactive_power_flow, 0.0, "MVAr")
    PDP.set_value!(line, :base_power, 100.0, "MVA")
    PDP.set_value!(line, :r, 0.01, "pu")
    PDP.set_value!(line, :x, 0.1, "pu")
    PDP.set_value!(line, :rating, 1.0, "MVA")
    PDP.set_value!(line, :angle_limits, (min = -0.5, max = 0.5), "rad")
    PDP.add_component!(sys, line)
    PDP.add_component!(sys, _bus(2, "Abel"))
    @test PDP.component_type_names(sys) == ["ACBus", "Line"]
end

@testset "per-type buckets stay concretely typed" begin
    sys = PDP.OpenAPISystem(100.0)
    PDP.add_component!(sys, _bus(1, "Abel"))
    PDP.add_component!(sys, _bus(2, "Adams"))
    @test eltype(PDP.get_components(sys, "ACBus")) == PDP.PO.ACBus
end

@testset "get_components on an absent type is empty, not an error" begin
    sys = PDP.OpenAPISystem(100.0)
    @test isempty(PDP.get_components(sys, "ACBus"))
end

@testset "the registry travels with the system" begin
    sys = PDP.OpenAPISystem(100.0)
    reg = PDP.get_registry(sys)
    id = PDP.register_bus!(reg, 101, "Abel")
    PDP.add_component!(sys, _bus(id, "Abel"))
    @test PDP.get_bus_id(PDP.get_registry(sys), 101) == id
end
