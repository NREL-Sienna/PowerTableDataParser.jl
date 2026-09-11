"""
Unit-checked assignment onto generated OpenAPI components.

Generated component types are immutable `Base.@kwdef struct`s with no common supertype, so a
builder cannot allocate one empty and mutate it field by field the way the pre-1.0 OpenAPI.jl
runtime allowed. [`stage`](@ref) opens a mutable scratch dict typed to the target type instead;
`set_value!`/`get_value` read and write that dict, resolving unit and compound-type
information from `fieldtype` and the generated unit metadata; [`materialize`](@ref) (called
from `add_component!`/`add_supplemental_attribute!` in `container.jl`) builds the real
immutable struct once, from every field accumulated so far.

The two `set_value!` arities are the enforcement, as before: a property that declares a unit
can only be written by the 4-argument form, and one that does not can only be written by the
3-argument form, so the check cannot be skipped by choosing the shorter call.
"""

"""
Mutable staging for a to-be-immutable OpenAPI model type `T`.

`stage(T)` opens one of these with an empty field dict; `set_value!`/`get_value` accumulate
into it; `materialize` builds the real `T` in one kwarg call once every field the caller means
to set has been staged. Fields are stored already coerced to the exact concrete type `T`
declares (see [`_coerce`](@ref)), so materialization is a plain, conversion-free
`T(; fields...)`.
"""
struct Staged{T}
    fields::Dict{Symbol, Any}
end

"""Open a staging area for `T`. Replaces the old empty-construct `T()`."""
stage(::Type{T}) where {T} = Staged{T}(Dict{Symbol, Any}())

"""Build the real, immutable `T` from every field staged so far."""
materialize(s::Staged{T}) where {T} = T(; s.fields...)

"""
A value already of the target type is a no-op; otherwise call the target type's own
constructor on it.

This is how a raw `String` such as `"ONLINE"` becomes the validating enum wrapper a
generated field actually declares (`ThermalStandardStatus`, `UnitSystem`, ...): there is no
generic `convert` fallback for these types, and assignment must run the same validation the
old mutable `setproperty!` path did.
"""
_coerce(::Type{T}, value::T) where {T} = value
_coerce(::Type{T}, value) where {T} = T(value)

"""Whether `Absent` is one of `u`'s member types."""
_has_absent(u::Union) = Absent in Base.uniontypes(u)
_has_absent(::Type) = false

"""Whether `value` is `Absent`."""
is_absent(::Absent) = true
is_absent(_) = false

"""The member types of `t`; a non-`Union` type is its own sole member."""
_concrete_types(u::Union) = Base.uniontypes(u)
_concrete_types(t::Type) = (t,)

"""
The single concrete type a field can actually hold, with the `Absent`/`Nothing` arms the
generator adds to every optional field stripped off.

Used both to build a compound value (`MinMax`, `UpDown`, `FromTo`, ...) and to know what
[`_coerce`](@ref) should convert a plain value into.
"""
function _concrete_field_type(::Type{T}, prop::Symbol) where {T}
    ftype = fieldtype(T, prop)
    concrete = filter(t -> t !== Nothing && t !== Absent, collect(_concrete_types(ftype)))
    if length(concrete) != 1
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is not a single concrete type: $ftype",
            ),
        )
    end
    return only(concrete)
end

"""A placeholder value for a required field this object has not staged yet.

Only used to complete a [`_shadow`](@ref) instance so the generated per-instance
`declared_unit`/`declared_quantity` methods have something to dispatch on; the discriminated
field they actually read is always staged first (by convention, before its dependent
fields), so a placeholder is never the value such a method consults.
"""
_placeholder(::Type{T}) where {T <: Integer} = zero(T)
_placeholder(::Type{T}) where {T <: AbstractFloat} = zero(T)
_placeholder(::Type{Bool}) = false
_placeholder(::Type{String}) = ""
_placeholder(::Type{Dict{K, V}}) where {K, V} = Dict{K, V}()
_placeholder(::Type{Vector{T}}) where {T} = T[]

"""
A placeholder for a required oneOf-wrapper field (`FunctionData`, `*OperationCost`, ...):
the first declared variant, itself placeholder-built recursively.

A shadow only needs *some* valid instance to satisfy the outer struct's required kwarg —
the generated `declared_unit`/`declared_quantity` methods it stands in for never read a
oneOf field's own contents, only a plain sibling discriminator's — so which variant is
picked is immaterial. `EnumAPIModel` gets no such case: unlike a oneOf member, an enum's
inner constructor validates against a fixed string whitelist this package cannot enumerate,
so a required enum field still falls through to the generic fallback below.
"""
function _placeholder(::Type{T}) where {T <: IC.OneOfAPIModel}
    variant = first(Base.uniontypes(fieldtype(T, :value)))
    return T(_placeholder(variant))
end

"""
Recursive fallback: a required compound "shape" type (`MinMax`, `UpDown`, `FromTo`, ...) is
plain numbers with no validation, so a zeroed instance is always constructible. A field
named for one of the [`_DEFAULT_BASIS`](@ref) discriminators (`power_units`, ...) uses that
same default, whatever struct it turns up nested in — a oneOf variant's own basis field
(`CostCurve.power_units`, say) is exactly as placeholder-able as the top-level one
`_default_bases!` defaults. A required field with no such shape and no case above (an enum
wrapper outside that known set) means a caller staged a discriminated numeric field before
the enum field its shadow needs — a genuine ordering bug, so this fails loudly rather than
guessing a value.
"""
function _placeholder(::Type{T}) where {T}
    kwargs = Dict{Symbol, Any}()
    for name in fieldnames(T)
        name === :additional_properties && continue
        ftype = fieldtype(T, name)
        _has_absent(ftype) && continue
        concrete = _concrete_field_type(T, name)
        kwargs[name] = if haskey(_DEFAULT_BASIS, name)
            _coerce(concrete, _DEFAULT_BASIS[name])
        else
            _placeholder(concrete)
        end
    end
    return T(; kwargs...)
end

"""
A throw-away, fully valid `T` built from this object's fields staged so far, standing in for
the real (not-yet-complete) component so the generated per-instance `declared_unit`/
`declared_quantity` methods — which resolve a discriminated field's unit by reading a sibling
basis field via `getproperty` — have a real `T` to dispatch on. Every field not yet staged
gets a [`_placeholder`](@ref).
"""
function _shadow(s::Staged{T}) where {T}
    kwargs = Dict{Symbol, Any}()
    for name in fieldnames(T)
        name === :additional_properties && continue
        if haskey(s.fields, name)
            kwargs[name] = s.fields[name]
        else
            ftype = fieldtype(T, name)
            _has_absent(ftype) && continue
            kwargs[name] = _placeholder(_concrete_field_type(T, name))
        end
    end
    return T(; kwargs...)
end

"""
Basis-selector fields this package leaves optional, defaulted the first time a
declared-unit lookup needs one — mirroring `add_component!`'s later restamp of `power_units`
to the run's real convention. The default per field matches the literal source-unit label
every reader in this package already passes for that field's dependents: `power_units`
defaults to `"NATURAL_UNITS"` because readers always pass natural-unit labels (`"MW"`, ...);
`parameter_units` and `admittance_units` default to `"COMPONENT_BASE"` because the impedance
and admittance columns readers pass are always already per unit (`"pu"`); `energy_units`
(which names the energy unit directly, `"MWH"`/`"MWMIN"`, rather than choosing a natural-vs-
per-unit basis) defaults to `"MWH"` because readers always pass `"MWh"`.
"""
const _DEFAULT_BASIS = Dict{Symbol, String}(
    :power_units => "NATURAL_UNITS",
    :energy_units => "MWH",
    :parameter_units => "COMPONENT_BASE",
    :admittance_units => "COMPONENT_BASE",
)

function _default_bases!(s::Staged{T}) where {T}
    for (name, default) in _DEFAULT_BASIS
        if hasfield(T, name) && !haskey(s.fields, name)
            s.fields[name] = _coerce(_concrete_field_type(T, name), default)
        end
    end
    return
end

"""
Constructor for a compound property, e.g. `MinMax` for `ACBus.voltage_limits`.
"""
_compound_type(::Type{T}, prop::Symbol) where {T} = _concrete_field_type(T, prop)

function _declared(s::Staged{T}, prop::Symbol) where {T}
    if !IC.has_declared_unit(T, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares no unit; use the 3-argument set_value!",
            ),
        )
    end
    # Most properties declare a fixed unit resolvable from the type alone; only a
    # discriminated one needs an instance (a shadow stands in for the real, incomplete
    # object) to read the sibling basis field its unit depends on. Trying the type-level
    # form first avoids building a shadow — and the required-field placeholders that would
    # need — for the common, non-discriminated case.
    try
        return IC.declared_unit(T, Val(prop)), IC.declared_quantity(T, Val(prop))
    catch e
        e isa ErrorException || rethrow()
    end
    _default_bases!(s)
    shadow = _shadow(s)
    return IC.declared_unit(shadow, Val(prop)), IC.declared_quantity(shadow, Val(prop))
end

function _reject_declared(s::Staged{T}, prop::Symbol) where {T}
    if IC.has_declared_unit(T, Val(prop))
        unit = declared_unit_label(s, prop)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares unit \"$unit\"; use the 4-argument set_value!",
            ),
        )
    end
    return
end

"""Best-effort unit label for an error message: resolves through a shadow instance for a
discriminated property (mirroring `_declared`), falling back to `"?"` only if that also
fails because some other required field has no default and is not yet staged — building
its placeholder then raises a `MethodError`, since a plain (non-`@kwdef`) enum type has no
keyword constructor for `_placeholder`'s generic fallback to call."""
_placeholder_gap_label(::MethodError) = "?"
_placeholder_gap_label(e) = rethrow(e)

function declared_unit_label(s::Staged{T}, prop::Symbol) where {T}
    return try
        first(_declared(s, prop))
    catch e
        _placeholder_gap_label(e)
    end
end

function _convert(
    ::Type{T},
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
) where {T}
    if source_unit == target
        return value
    end
    if !IC.has_conversion_factor(quantity, source_unit)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\"; " *
                "\"$source_unit\" is not a convertible $quantity unit",
            ),
        )
    end
    if !IC.has_conversion_factor(quantity, target)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop: the unit vocabulary records no conversion factor " *
                "for $quantity in \"$target\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source_unit) /
           IC.conversion_factor(quantity, target)
end

"""Convert `value` from `source_unit` into the unit `prop` declares."""
function convert_to_declared(
    s::Staged{T},
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
) where {T}
    target, quantity = _declared(s, prop)
    return _convert(T, prop, Float64(value), source_unit, target, quantity)
end

"""Assign a numeric property, converting from `source_unit` to the declared unit."""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
) where {T}
    converted = convert_to_declared(s, prop, value, source_unit)
    s.fields[prop] = _coerce(_concrete_field_type(T, prop), converted)
    return
end

"""
Assign a compound property such as `MinMax`, `UpDown`, `FromTo` or `InOut`.

The schemas annotate these at the object level rather than per member, so one unit applies to
every field of the tuple.
"""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value::NamedTuple,
    source_unit::AbstractString,
) where {T}
    target, quantity = _declared(s, prop)
    converted = map(
        v -> _convert(T, prop, Float64(v), source_unit, target, quantity),
        values(value),
    )
    ctor = _compound_type(T, prop)
    s.fields[prop] = ctor(; NamedTuple{keys(value)}(converted)...)
    return
end

"""
Reject a unit supplied for something that cannot carry one.

Either the property declares no unit, or the value is neither a number nor a compound tuple.
Both are caller mistakes worth naming precisely rather than surfacing as a MethodError.
"""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value,
    source_unit::AbstractString,
) where {T}
    _reject_declared(s, prop)
    throw(
        IS.DataFormatError(
            "$(nameof(T)).$prop: a unit applies only to a number or a compound " *
            "tuple, got $(typeof(value))",
        ),
    )
end

"""Assign a property that declares no unit: names, ids, flags, enum strings."""
function set_value!(s::Staged{T}, prop::Symbol, value) where {T}
    _reject_declared(s, prop)
    s.fields[prop] = _coerce(_concrete_field_type(T, prop), value)
    return
end

"""
The plain value inside an enum wrapper (`OperationalStates`, `PrimeMovers`, `UnitSystem`,
...); anything else is returned unchanged.

`get_value` reads through this rather than returning the wrapper: every comparison in this
package and its tests is against the schema's bare string constants (`"ONLINE"`, `"FIXED"`,
...), and an `EnumAPIModel` does not compare equal to the string it wraps. `OneOfAPIModel`
(a oneOf wrapper over concrete struct variants, not a string) is deliberately excluded — a
caller reading one of those wants the concrete variant, not a string.
"""
_unwrap(value::IC.EnumAPIModel) = value.value
_unwrap(value) = value

"""Return the staged value of `prop`."""
get_value(s::Staged, prop::Symbol) = _unwrap(s.fields[prop])

"""Return the stored value of `prop` on an already-materialized component."""
get_value(o, prop::Symbol) = _unwrap(getproperty(o, prop))

_declared_read(s::Staged, prop::Symbol) = _declared(s, prop)
_declared_read(o::T, prop::Symbol) where {T} =
    (IC.declared_unit(o, Val(prop)), IC.declared_quantity(o, Val(prop)))

"""Return the value of `prop` expressed in `unit`."""
function get_value(o, prop::Symbol, unit::AbstractString)
    source, quantity = _declared_read(o, prop)
    value = get_value(o, prop)
    if source == unit
        return value
    end
    if !IC.has_conversion_factor(quantity, unit) ||
       !IC.has_conversion_factor(quantity, source)
        throw(
            IS.DataFormatError(
                "$prop is $quantity in \"$source\"; cannot express in \"$unit\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source) /
           IC.conversion_factor(quantity, unit)
end
