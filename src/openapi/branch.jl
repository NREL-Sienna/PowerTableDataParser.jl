# A transformer emits two components. The electrical parameters and the arc live on a
# `TransformerCircuit`, which the `TwoWindingTransformer` references by id. The circuit
# carries no name.

"""
Classify a branch row as a `Line` or a `TwoWindingTransformer`.

The table model has no phase shifters. Where the data states `is_transformer` it
decides; otherwise an off-nominal tap is the only signal. RTS writes 0 for lines
rather than 1, which `iszero` covers.
"""
function get_branch_type(tap::Float64, ::Nothing)
    if !iszero(tap) && tap != 1.0
        return :TwoWindingTransformer
    end
    return :Line
end

function get_branch_type(::Float64, is_transformer::Bool)
    if is_transformer
        return :TwoWindingTransformer
    end
    return :Line
end

"""
Return the id of the `Arc` between two buses, creating it on first sight.

Parallel circuits share one arc: RTS has 12 bus pairs carrying two branches each.
"""
function _add_arc!(sys::OpenAPISystem, from_id::Int, to_id::Int)
    id, created = arc_id!(get_registry(sys), from_id, to_id)
    if created
        arc = stage(PC.Arc)
        set_value!(arc, :id, id)
        set_value!(arc, :from_id, from_id)
        set_value!(arc, :to_id, to_id)
        add_component!(sys, arc)
    end
    return id
end

"""
Tap band a transformer keeps when the tables state no control block.

This is the schemas' declared default for `control_limits` (PSS/E RMA/RMI) and
the same band PowerSystems gives a tap changer. Table data has no COD/RMA/RMI
columns, so the alternative is leaving the range unset and losing it entirely.
"""
const DEFAULT_TAP_CONTROL_BAND = (min = 0.9, max = 1.1)

"""
Voltage band a transformer holds to, in pu, when the tables state no other target.

PSS/E states the controlled quantity as a band (VMA/VMI) rather than a setpoint,
and a setpoint is the band whose ends coincide: hold nominal voltage exactly.
Nothing achieves that in practice, but it is what a setpoint asks for, and it is
how a target survives into a model that only speaks in bands.
"""
const NOMINAL_VOLTAGE_BAND = (min = 1.0, max = 1.0)

"""Assign a property the data may not state."""
function _set_optional!(component, prop::Symbol, value, unit::AbstractString)
    if isnothing(value)
        return
    end
    set_value!(component, prop, value, unit)
    return
end

function _add_line!(sys::OpenAPISystem, branch, arc::Int)
    line = stage(PO.Line)
    set_value!(line, :id, register!(get_registry(sys), "Line", branch.name))
    set_value!(line, :name, branch.name)
    set_value!(line, :available, true)
    set_value!(line, :arc, arc)
    set_value!(line, :active_power_flow, branch.active_power_flow, "MW")
    set_value!(line, :reactive_power_flow, branch.reactive_power_flow, "MVAr")
    set_value!(line, :r, branch.r, "pu")
    set_value!(line, :x, branch.x, "pu")
    set_value!(line, :base_power, get_base_power(sys), "MVA")
    set_value!(line, :rating, branch.rate, "MVA")
    _set_optional!(line, :rating_b, branch.rating_b, "MVA")
    _set_optional!(line, :rating_c, branch.rating_c, "MVA")
    # The table states the total charging susceptance; the schema wants it split
    # across the two ends.
    half_shunt = branch.primary_shunt / 2
    set_value!(line, :b, (from = half_shunt, to = half_shunt), "pu")
    set_value!(line, :g, (from = 0.0, to = 0.0), "pu")
    set_value!(
        line,
        :angle_limits,
        (min = branch.min_angle_limits, max = branch.max_angle_limits),
        "rad",
    )
    add_component!(sys, line)
    return
end

function _add_transformer!(sys::OpenAPISystem, branch, arc::Int, from_kv, to_kv)
    reg = get_registry(sys)
    circuit = stage(PO.TransformerCircuit)
    set_value!(circuit, :id, next_id!(reg))
    set_value!(circuit, :available, true)
    set_value!(circuit, :arc, arc)
    set_value!(circuit, :tap, branch.tap, "1")
    set_value!(circuit, :r, branch.r, "pu")
    set_value!(circuit, :x, branch.x, "pu")
    set_value!(circuit, :rating, branch.rate, "MVA")
    _set_optional!(circuit, :rating_b, branch.rating_b, "MVA")
    _set_optional!(circuit, :rating_c, branch.rating_c, "MVA")
    # The tables state a tap ratio and no control block, which is PSS/E COD 0: a
    # fixed tap. The band takes the schemas' declared default and the controlled
    # quantity is the nominal voltage, stated as a band with coincident ends.
    # control_objective sets the unit of both bands, so it is assigned first.
    set_value!(circuit, :control_objective, "FIXED")
    set_value!(circuit, :control_limits, DEFAULT_TAP_CONTROL_BAND, "1")
    set_value!(circuit, :controlled_quantity_limits, NOMINAL_VOLTAGE_BAND, "pu")
    set_value!(circuit, :active_power_flow, branch.active_power_flow, "MW")
    set_value!(circuit, :reactive_power_flow, branch.reactive_power_flow, "MVAr")
    set_value!(circuit, :base_power, get_base_power(sys), "MVA")
    set_value!(circuit, :base_voltage_primary, from_kv, "kV")
    set_value!(circuit, :base_voltage_secondary, to_kv, "kV")
    add_component!(sys, circuit)

    xfmr = stage(PO.TwoWindingTransformer)
    set_value!(xfmr, :id, register!(reg, "TwoWindingTransformer", branch.name))
    set_value!(xfmr, :name, branch.name)
    set_value!(xfmr, :circuit, get_value(circuit, :id))
    # The column is a susceptance, so it is the imaginary part of the admittance. RTS
    # states 0 for every transformer, so this choice doesn't affect any current dataset.
    set_value!(xfmr, :magnetizing_shunt, (real = 0.0, imag = branch.primary_shunt), "pu")
    add_component!(sys, xfmr)
    return
end

function branch_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    kv = Dict(
        get_value(bus, :id) => get_value(bus, :base_voltage) for
        bus in get_components(sys, "ACBus")
    )
    for branch in iterate_rows(data, InputCategory.BRANCH; per_unit = uses_per_unit(sys))
        from_id = get_bus_id(reg, Int(branch.connection_points_from))
        to_id = get_bus_id(reg, Int(branch.connection_points_to))
        arc = _add_arc!(sys, from_id, to_id)
        kind = get_branch_type(branch.tap, get(branch, :is_transformer, nothing))
        if kind == :Line
            _add_line!(sys, branch, arc)
        else
            _add_transformer!(sys, branch, arc, kv[from_id], kv[to_id])
        end
    end
    return
end
