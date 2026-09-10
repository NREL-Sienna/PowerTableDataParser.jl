# Reserve-to-device contribution is a many-to-many relation, emitted as rows in the unified
# `supplemental_attribute_associations` table: one row per pair, `attribute_type` naming
# the service's own type. There is no built `System` yet at this stage, so it is resolved
# against the tables and the id registry, which is why the eligibility rules are re-evaluated
# rather than read off components.

"""Reserve direction as the schema's enum value."""
function get_reserve_direction(direction::AbstractString)
    normalized = uppercase(strip(direction))
    if normalized == "UP"
        return "UP"
    end
    if normalized == "DOWN"
        return "DOWN"
    end
    throw(IS.DataFormatError("invalid reserve direction=$direction"))
end

"""
Reserve time frame in minutes.

The table states seconds (RTS names the column `Timeframe (sec)`) but the schema
declares `min`, and `UNIT_VOCABULARY` carries no second for OperationalDuration,
so the conversion happens here rather than in the unit layer.
"""
_seconds_to_minutes(seconds::Real) = Float64(seconds) / 60.0

"""
Requirement absent in the table means no stated requirement, which is `0.0`.

Constant-vs-variable is no longer a type distinction: one `OnlineReserve` carries the
requirement as a field, and whether it is scaled by a `"requirement"` time series is
decided downstream from time series presence. The table's `timeframe` is in seconds
while the schema declares `time_frame` in minutes, so the conversion runs on the way in.
"""
function _add_reserve!(sys::OpenAPISystem, reserve)
    component = stage(PO.OnlineReserve)
    service_id = register!(get_registry(sys), "OnlineReserve", reserve.name)
    set_value!(component, :id, service_id)
    set_value!(component, :name, reserve.name)
    set_value!(component, :available, true)
    # Staged before any power-family field: `reserve_direction` is required and has no
    # generic placeholder a shadow instance could stand in with, so it must already be
    # staged by the time a discriminated sibling field's declared unit is resolved.
    set_value!(component, :reserve_direction, get_reserve_direction(reserve.direction))
    set_value!(component, :time_frame, _seconds_to_minutes(reserve.timeframe), "min")
    set_value!(component, :requirement, get(reserve, :requirement, 0.0), "MW")
    add_component!(sys, component)
    return service_id
end

"""
Parse a `"(a,b,c)"` tuple column into its members, or an empty vector when absent.

The tables wrap these lists in parentheses and pad after commas.
"""
function _tuple_column(value)
    if value === nothing
        return String[]
    end
    text = strip(String(value), ['(', ')'])
    if isempty(text)
        return String[]
    end
    return [strip(part) for part in split(text, ",")]
end

"""
Bus id to area label, for matching `eligible_regions`.

The reserve tables state regions as area labels while a generator row names only its bus,
so the bus table is the join. Built once per `services_csv_parser!` call rather than
filtered per generator, since a reserve's eligibility check runs it once per generator.
"""
function _bus_areas(data::PowerSystemTableData)
    buses = get_dataframe(data, InputCategory.BUS)
    id_column = get_user_field(data, InputCategory.BUS, "bus_id")
    area_column = get_user_field(data, InputCategory.BUS, "area")
    return Dict(
        Int(row[id_column]) => string(row[area_column]) for
        row in DataFrames.eachrow(buses)
    )
end

function _generator_area(bus_areas::Dict{Int, String}, bus_number::Int)
    haskey(bus_areas, bus_number) ||
        throw(IS.DataFormatError("no bus row for bus_id=$bus_number"))
    return bus_areas[bus_number]
end

"""
One generator's type category and its bus's area, keyed for the fallback eligibility
check (`_add_reserve_membership!` with no explicit `contributing_devices`).

Built once per `services_csv_parser!` call. That fallback rule re-evaluates `category
in eligible_device_subcategories` and `area in eligible_regions` per reserve, and
several RTS reserves take this path; rescanning the GENERATOR table (and re-deriving
its field infos, re-emitting its "column not in dataframe" warnings) once per such
reserve is redundant when the generator set doesn't change between reserves.
"""
struct _GeneratorMembership
    name::String
    category::String
    area::String
end

function _generator_memberships(
    data::PowerSystemTableData,
    bus_areas::Dict{Int, String},
    per_unit::Bool,
)
    return [
        _GeneratorMembership(
            string(gen.name),
            string(gen.category),
            _generator_area(bus_areas, Int(gen.bus_id)),
        ) for gen in iterate_rows(data, InputCategory.GENERATOR; per_unit = per_unit)
    ]
end

"""Resolve `device_name` to its registered id, or error if it isn't registered yet."""
function _contributing_device_id(reg::IdRegistry, device_types, device_name, reserve_name)
    try
        _, entity_id = find_by_name(reg, device_types, device_name)
        return entity_id
    catch e
        e isa IS.DataFormatError || rethrow()
        throw(
            IS.DataFormatError(
                "reserve $reserve_name matched contributing device $device_name, but no " *
                "component is registered under that name; device components must be " *
                "parsed before services",
            ),
        )
    end
end

"""
Emit one service-association row per (reserve, contributing device) pair.

An explicit `contributing_devices` list wins, and otherwise a generator contributes when
its `category` is in `eligible_device_subcategories` **and** its bus's area is in
`eligible_regions`. Both are re-evaluated from the tables because at this stage there is no
`System` to read membership off.
"""
function _add_reserve_membership!(
    sys::OpenAPISystem,
    generator_memberships::Vector{_GeneratorMembership},
    reserve,
    service_id::Int,
)
    reg = get_registry(sys)
    device_types = category_to_type_names("Generator")
    subcategories = _tuple_column(get(reserve, :eligible_device_subcategories, nothing))
    named_devices = _tuple_column(get(reserve, :contributing_devices, nothing))

    if isempty(subcategories)
        for device_name in named_devices
            entity_id =
                _contributing_device_id(reg, device_types, device_name, reserve.name)
            add_service_association!(sys, service_id, entity_id)
        end
        return
    end

    regions = _tuple_column(reserve.eligible_regions)
    for gen in generator_memberships
        if !(gen.category in subcategories)
            continue
        end
        if !(gen.area in regions)
            continue
        end
        entity_id = _contributing_device_id(reg, device_types, gen.name, reserve.name)
        add_service_association!(sys, service_id, entity_id)
    end
    return
end

function services_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    bus_areas = _bus_areas(data)
    generator_memberships = _generator_memberships(data, bus_areas, uses_per_unit(sys))
    for reserve in iterate_rows(data, InputCategory.RESERVE; per_unit = uses_per_unit(sys))
        service_id = _add_reserve!(sys, reserve)
        _add_reserve_membership!(sys, generator_memberships, reserve, service_id)
    end
    return
end
