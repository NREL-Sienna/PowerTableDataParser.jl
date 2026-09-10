function _branches()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.branch_csv_parser!(sys, data)
    return sys, data
end

@testset "get_branch_type distinguishes lines from transformers" begin
    @test PDP.get_branch_type(1.0, nothing) == :Line
    @test PDP.get_branch_type(0.98, nothing) == :TwoWindingTransformer
    @test PDP.get_branch_type(1.0, true) == :TwoWindingTransformer
    @test PDP.get_branch_type(0.98, false) == :Line
    # RTS writes 0 for "not a transformer" rather than 1.
    @test PDP.get_branch_type(0.0, nothing) == :Line
end

@testset "120 branches total, split 105/15" begin
    sys, _ = _branches()
    @test length(PDP.get_components(sys, "Line")) == 105
    @test length(PDP.get_components(sys, "TwoWindingTransformer")) == 15
end

@testset "each transformer emits a paired circuit" begin
    sys, _ = _branches()
    circuits = PDP.get_components(sys, "TransformerCircuit")
    ids = Set(PDP.get_value(c, :id) for c in circuits)
    xfmrs = PDP.get_components(sys, "TwoWindingTransformer")
    @test length(circuits) == length(xfmrs)
    @test length(ids) == length(circuits)
    for x in xfmrs
        @test PDP.get_value(x, :circuit) in ids
    end
end

@testset "arcs are deduplicated and every reference resolves" begin
    sys, _ = _branches()
    arcs = PDP.get_components(sys, "Arc")
    pairs = Set(
        (PDP.get_value(a, :from_id), PDP.get_value(a, :to_id)) for a in arcs
    )
    @test length(pairs) == length(arcs)
    # 120 branches over 108 distinct bus pairs: 12 pairs carry two circuits.
    @test length(arcs) == 108

    ids = Set(PDP.get_value(a, :id) for a in arcs)
    for line in PDP.get_components(sys, "Line")
        @test PDP.get_value(line, :arc) in ids
    end
    for circuit in PDP.get_components(sys, "TransformerCircuit")
        @test PDP.get_value(circuit, :arc) in ids
    end

    bus_ids = Set(PDP.get_value(b, :id) for b in PDP.get_components(sys, "ACBus"))
    for arc in arcs
        @test PDP.get_value(arc, :from_id) in bus_ids
        @test PDP.get_value(arc, :to_id) in bus_ids
    end
end

@testset "line electrical parameters come through in schema units" begin
    sys, _ = _branches()
    a1 = first(
        l for l in PDP.get_components(sys, "Line") if PDP.get_value(l, :name) == "A1"
    )
    @test PDP.get_value(a1, :r) ≈ 0.003
    @test PDP.get_value(a1, :x) ≈ 0.014
    # The table's B is the total charging susceptance; the schema splits it.
    b = PDP.get_value(a1, :b)
    @test b.from ≈ 0.461 / 2
    @test b.to ≈ 0.461 / 2
    g = PDP.get_value(a1, :g)
    @test iszero(g.from)
    @test iszero(g.to)
    @test PDP.get_value(a1, :rating) ≈ 175.0
    @test PDP.get_value(a1, :base_power) ≈ 100.0
    limits = PDP.get_value(a1, :angle_limits)
    @test limits.min ≈ -3.1416
    @test limits.max ≈ 3.1416
    @test iszero(PDP.get_value(a1, :active_power_flow))
    @test iszero(PDP.get_value(a1, :reactive_power_flow))
end

@testset "transformer parameters land on the circuit" begin
    sys, _ = _branches()
    reg = PDP.get_registry(sys)
    a7 = first(
        x for x in PDP.get_components(sys, "TwoWindingTransformer") if
        PDP.get_value(x, :name) == "A7"
    )
    circuits = Dict(
        PDP.get_value(c, :id) => c for c in PDP.get_components(sys, "TransformerCircuit")
    )
    circuit = circuits[PDP.get_value(a7, :circuit)]

    @test PDP.get_value(circuit, :tap) ≈ 1.015
    @test PDP.get_value(circuit, :r) ≈ 0.002
    @test PDP.get_value(circuit, :x) ≈ 0.084
    @test PDP.get_value(circuit, :rating) ≈ 400.0
    @test PDP.get_value(circuit, :base_power) ≈ 100.0
    # Bus 103 is 138 kV, bus 124 is 230 kV.
    @test PDP.get_value(circuit, :base_voltage_primary) ≈ 138.0
    @test PDP.get_value(circuit, :base_voltage_secondary) ≈ 230.0
    @test PDP.get_value(circuit, :available)

    arcs = Dict(PDP.get_value(a, :id) => a for a in PDP.get_components(sys, "Arc"))
    arc = arcs[PDP.get_value(circuit, :arc)]
    @test PDP.get_value(arc, :from_id) == PDP.get_bus_id(reg, 103)
    @test PDP.get_value(arc, :to_id) == PDP.get_bus_id(reg, 124)
end

@testset "the table's B is a susceptance, so it lands in the imaginary part" begin
    sys = PDP.OpenAPISystem(100.0)
    reg = PDP.get_registry(sys)
    from_id = PDP.register_bus!(reg, 1, "from")
    to_id = PDP.register_bus!(reg, 2, "to")
    arc = PDP._add_arc!(sys, from_id, to_id)
    row = (
        name = "T1",
        r = 0.01,
        x = 0.1,
        primary_shunt = 0.05,
        rate = 400.0,
        rating_b = nothing,
        rating_c = nothing,
        tap = 1.02,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
    )
    PDP._add_transformer!(sys, row, arc, 138.0, 230.0)

    xfmr = only(PDP.get_components(sys, "TwoWindingTransformer"))
    shunt = PDP.get_value(xfmr, :magnetizing_shunt)
    @test iszero(shunt.real)
    @test shunt.imag ≈ 0.05
end

@testset "every branch component satisfies its required properties" begin
    sys, _ = _branches()
    for type_name in PDP.component_type_names(sys)
        for component in PDP.get_components(sys, type_name)
            @test required_fields_populated(component)
        end
    end
end

@testset "the emergency ratings the tables state are carried" begin
    sys, _ = _branches()
    a1 = first(
        l for l in PDP.get_components(sys, "Line") if PDP.get_value(l, :name) == "A1"
    )
    # RTS states Cont/LTE/STE; the fixture's own descriptor reads only the first.
    @test PDP.get_value(a1, :rating) ≈ 175.0
    @test PDP.get_value(a1, :rating_b) ≈ 193.0
    @test PDP.get_value(a1, :rating_c) ≈ 200.0

    circuits = Dict(
        PDP.get_value(c, :id) => c for c in PDP.get_components(sys, "TransformerCircuit")
    )
    a7 = first(
        x for x in PDP.get_components(sys, "TwoWindingTransformer") if
        PDP.get_value(x, :name) == "A7"
    )
    circuit = circuits[PDP.get_value(a7, :circuit)]
    @test PDP.get_value(circuit, :rating) ≈ 400.0
    @test PDP.get_value(circuit, :rating_b) ≈ 510.0
    @test PDP.get_value(circuit, :rating_c) ≈ 600.0

    @test all(
        !isnothing(PDP.get_value(l, :rating_b)) for l in PDP.get_components(sys, "Line")
    )
end

@testset "an uncontrolled circuit still states its tap band" begin
    sys, _ = _branches()
    for circuit in PDP.get_components(sys, "TransformerCircuit")
        # A tap ratio with no control block is PSS/E COD 0: a fixed tap.
        @test PDP.get_value(circuit, :control_objective) == "FIXED"
        limits = PDP.get_value(circuit, :control_limits)
        @test limits.min ≈ 0.9
        @test limits.max ≈ 1.1
        # A voltage target is a band whose ends coincide.
        controlled = PDP.get_value(circuit, :controlled_quantity_limits)
        @test controlled.min ≈ 1.0
        @test controlled.max ≈ 1.0
        @test controlled.min == controlled.max
        @test PDP.get_value(circuit, :number_of_tap_positions) == 33
    end
end
