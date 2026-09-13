"""
One series against the component that owns it, staged for the time series store.

A fanned-out series shares one `series` object across its owners; the store
dedups the array by content hash, so it lands once regardless.
"""
struct StagedTimeSeries
    owner_type::String
    owner_id::Int
    series::IS.SingleTimeSeries
end

"""
The document PTDP emits, as a thin wrapper over `PD.SystemDocument`.

`document` carries the components, the supplemental-attribute association table, and
`ext`. `base_power` is the system MVA base readers scale against; it is not part of the
serialized document — each component states its own `base_power`. `power_units` is this
run's chosen basis, stamped onto every emitted component whose PO type declares the field
(see [`add_component!`](@ref)); it too is not carried on the document itself.

`registry` is build-time scaffolding and is not serialized: it keeps the lookup
indices (by name, by bus number, by arc) the document has no use for once built.

`time_series` is the payload written to the InfraStore sidecar pair by
`write_time_series`; the store's own catalog is the association table, so the
document only names the store file.
"""
struct OpenAPISystem
    document::PD.SystemDocument
    registry::IdRegistry
    time_series::Vector{StagedTimeSeries}
    base_power::Float64
    power_units::String
end

"""
Unit conventions a component's `power_units` field may take, from the schemas' enum.

The schemas offer no system-base option: per-unit data historically on the system
base records that base in the component's own `base_power` and rides as
`COMPONENT_BASE`.
"""
const UNIT_SYSTEMS = ("NATURAL_UNITS", "COMPONENT_BASE")

function OpenAPISystem(
    base_power::Float64;
    power_units::AbstractString = "NATURAL_UNITS",
)
    if !(power_units in UNIT_SYSTEMS)
        throw(
            IS.DataFormatError(
                "power_units must be one of $(join(UNIT_SYSTEMS, ", ")); got $power_units",
            ),
        )
    end
    document = PD.SystemDocument()
    return OpenAPISystem(
        document,
        IdRegistry(document),
        Vector{StagedTimeSeries}(),
        base_power,
        String(power_units),
    )
end

get_document(sys::OpenAPISystem) = sys.document

get_supplemental_attribute_associations(sys::OpenAPISystem) =
    get_document(sys).supplemental_attribute_associations
get_service_associations(sys::OpenAPISystem) = get_document(sys).service_associations

"""Record the table columns the data model has no field for, against a component."""
function set_ext!(sys::OpenAPISystem, component_id::Int, extras::Dict{String, Any})
    PD.set_ext!(get_document(sys), component_id, extras)
    return
end

get_ext(sys::OpenAPISystem, component_id::Int) = PD.get_ext(get_document(sys), component_id)

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

get_power_units(sys::OpenAPISystem) = sys.power_units

"""
Whether values are stored per unit rather than in the schemas' natural units.

`COMPONENT_BASE` reproduces PowerSystems' storage convention: the descriptors' own
per-unit targets, which is device base for injectors and system base where the
descriptors say so. The `x-unit` annotations still name the natural unit, so a
per-unit document is for comparison against PowerSystems rather than for a
consumer that reads the annotations — which is why each component states the
convention it was written in.
"""
uses_per_unit(sys::OpenAPISystem) = sys.power_units == "COMPONENT_BASE"

"""
Materialize `staged` into the document, first stamping this run's `power_units` onto it when
its PO type declares the field — the per-component wire-contract requirement every
power-bearing type carries (a component with none, e.g. a pure topology row, is
untouched).
"""
function add_component!(sys::OpenAPISystem, staged::Staged{T}) where {T}
    if hasfield(T, :power_units)
        set_value!(staged, :power_units, sys.power_units)
    end
    PD.add_component!(get_document(sys), materialize(staged))
    return
end

"""
Record a supplemental attribute and the entity it describes.

This parser emits no plant-family attributes, so it never writes a `plant_associations` or
`combined_cycle_associations` row; reserve membership goes through
`add_service_association!` below, which uses its own table.
"""
function add_supplemental_attribute!(
    sys::OpenAPISystem,
    attribute::Staged,
    entity_id::Int,
)
    PD.add_supplemental_attribute!(get_document(sys), materialize(attribute), entity_id)
    return
end

"""
Record that `entity_id` contributes to the service `service_id`.

A service membership is a row in its own `service_associations` table, not in
`supplemental_attribute_associations`: a service is a component rather than a supplemental
attribute, so the two ends of the link resolve against different id sets and the document
validates each accordingly. The service's own type is already on the component, and
`entity_id` may name a Device, a Branch, or another Service, so no type discriminator is
needed here.

One row per pair, so each membership is individually addressable. Duplicate pairs are
rejected: the tables express membership as overlapping eligibility rules, so the same
device can match one reserve twice, and silently collapsing that would hide a malformed
rule set. The rejection itself is `PD.add_service_association!`'s job — it holds the O(1)
membership check against `service_membership`, so this wrapper does not rescan
`service_associations` before delegating.
"""
function add_service_association!(sys::OpenAPISystem, service_id::Int, entity_id::Int)
    PD.add_service_association!(
        get_document(sys),
        PO.ServiceAssociation(; service_id = service_id, entity_id = entity_id),
    )
    return
end

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_supplemental_attributes(get_document(sys), type_name)
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_components(get_document(sys), type_name)
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = PD.component_type_names(get_document(sys))
