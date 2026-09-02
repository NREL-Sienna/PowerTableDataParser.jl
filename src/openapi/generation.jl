# Two deliberate choices:
#   * dispatch is on `Val{type_name}` rather than an if/elseif chain over PSY
#     DataTypes, since the mapping file resolves to a name here, not a type;
#   * prime mover and fuel are enum strings, so the PSY enum lookups become
#     alias tables over the generated enum values.

"""
Table spellings that are not the schema's enum value for a prime mover.

Anything absent is uppercased and left to the generated `validate_property` to
accept or reject, so this table only carries the genuine renamings.
"""
const PRIME_MOVER_ALIASES = Dict(
    "w2" => "WT",
    "wind" => "WT",
    "pv" => "PVe",
    "pve" => "PVe",
    "solar" => "PVe",
    "rtpv" => "PVe",
    "nb" => "ST",
    "steam" => "ST",
    "hydro" => "HY",
    "ror" => "HY",
    "pump" => "PS",
    "pumped_hydro" => "PS",
    "nuclear" => "ST",
    "sync_cond" => "OT",
    "csp" => "CP",
    "un" => "OT",
    "storage" => "BA",
    "ice" => "IC",
)

"""Table spellings that are not the schema's enum value for a thermal fuel."""
const THERMAL_FUEL_ALIASES = Dict(
    "ng" => "NATURAL_GAS",
    "gas" => "NATURAL_GAS",
    "nuc" => "NUCLEAR",
    "oil" => "DISTILLATE_FUEL_OIL",
    "dfo" => "DISTILLATE_FUEL_OIL",
    "sync_cond" => "OTHER",
)

function _enum_value(aliases::Dict{String, String}, value::AbstractString)
    key = normalize(value; casefold = true)
    if haskey(aliases, key)
        return aliases[key]
    end
    return uppercase(value)
end

prime_mover_type(unit_type::AbstractString) =
    _enum_value(PRIME_MOVER_ALIASES, unit_type)
thermal_fuel(fuel::AbstractString) = _enum_value(THERMAL_FUEL_ALIASES, fuel)

"""
Group the storage rows by position and generator name.

Always returns the `Dict` shape, even with no storage table, so callers have one thing to
handle.
"""
function cache_storage(data::PowerSystemTableData; per_unit::Bool = false)
    storage = Dict(
        "head" => Dict{String, NamedTuple}(),
        "tail" => Dict{String, NamedTuple}(),
    )
    if !haskey(data.category_to_df, _category_key(InputCategory.STORAGE))
        return storage
    end
    for row in iterate_rows(data, InputCategory.STORAGE; per_unit = per_unit)
        position = normalize(row.position; casefold = true)
        for key in ("head", "tail")
            if !occursin(key, position)
                continue
            end
            if haskey(storage[key], row.generator_name)
                throw(
                    IS.DataFormatError(
                        "duplicate $key storage for generator $(row.generator_name)",
                    ),
                )
            end
            storage[key][row.generator_name] = row
        end
    end
    return storage
end

"""
Reactive power and its limits.

A stated maximum with no minimum is read as a zero floor, which is how the tables
express a unit that only injects.
"""
function make_reactive_params(
    gen;
    powerfield = :reactive_power,
    minfield = :reactive_power_limits_min,
    maxfield = :reactive_power_limits_max,
)
    reactive_power = get(gen, powerfield, 0.0)
    min_limit = get(gen, minfield, nothing)
    max_limit = get(gen, maxfield, nothing)
    if isnothing(min_limit) && isnothing(max_limit)
        return reactive_power, nothing
    end
    if isnothing(min_limit)
        return reactive_power, (min = 0.0, max = max_limit)
    end
    return reactive_power, (min = min_limit, max = max_limit)
end

"""
Apparent power rating implied by the active and reactive maxima.

A unit with neither is rated 1.0 rather than 0.0: a zero rating divides through the
per-unit conversions downstream.
"""
function calculate_gen_rating(active_power_max::Real, reactive_power_max::Real)
    rating = sqrt(Float64(active_power_max)^2 + Float64(reactive_power_max)^2)
    if iszero(rating)
        @warn "Rating calculation returned 0.0; using 1.0" maxlog = 5
        return 1.0
    end
    return rating
end

function calculate_gen_rating(
    active_power_limits::NamedTuple,
    reactive_power_limits::NamedTuple,
)
    return calculate_gen_rating(active_power_limits.max, reactive_power_limits.max)
end

"""A unit with no stated reactive limits is rated on active power alone."""
function calculate_gen_rating(active_power_limits::NamedTuple, ::Nothing)
    return calculate_gen_rating(active_power_limits.max, 0.0)
end

function make_ramplimits(
    gen;
    ramplimcol = :ramp_limits,
    rampupcol = :ramp_up,
    rampdncol = :ramp_down,
)
    ramp = get(gen, ramplimcol, nothing)
    if !isnothing(ramp)
        return (up = _as_float(ramp), down = _as_float(ramp))
    end
    up = get(gen, rampupcol, nothing)
    down = get(gen, rampdncol, nothing)
    if isnothing(up) && isnothing(down)
        return nothing
    end
    return (up = _maybe_float(up), down = _maybe_float(down))
end

"""
Minimum up/down times in minutes.

The source columns are hours (RTS names them `Min Up Time Hr` / `Min Down Time Hr`)
but the schema declares `min`, and `UNIT_VOCABULARY` carries no hour, so the
conversion cannot be delegated to `set_value!` and happens here instead.
"""
function make_timelimits(gen, up_column::Symbol, down_column::Symbol)
    up_time = _maybe_float(get(gen, up_column, nothing))
    down_time = _maybe_float(get(gen, down_column, nothing))
    if isnothing(up_time) && isnothing(down_time)
        return nothing
    end
    return (up = _hours_to_minutes(up_time), down = _hours_to_minutes(down_time))
end

_hours_to_minutes(::Nothing) = nothing
_hours_to_minutes(hours::Real) = 60.0 * hours

"""
Device base power, substituting the system base for a unit that states none.

The three RTS synchronous condensers carry `Base MVA = 0` upstream while injecting
over 100 MVAr, and a zero base divides through every per-unit conversion
downstream, so the system base is substituted instead.
"""
function device_base_power(sys::OpenAPISystem, gen::NamedTuple)
    base = _as_float(gen.base_mva)
    if abs(base) <= 1e-6
        @warn "$(gen.name) states a zero base power; using the system base" maxlog = 5
        return get_base_power(sys)
    end
    return base
end

function _active_power_limits(gen::NamedTuple)
    return (min = gen.active_power_limits_min, max = gen.active_power_limits_max)
end

"""Schema enum values for `status` on `ThermalStandard` / `ThermalMultiStart`."""
const THERMAL_STATUS_ENUM_VALUES = ("OFFLINE", "STARTUP", "ONLINE", "SHUTDOWN")

function _thermal_status(gen_name::AbstractString, value::Bool)
    if value
        return "ONLINE"
    end
    return "OFFLINE"
end

function _thermal_status(gen_name::AbstractString, value::Integer)
    if isone(value)
        return "ONLINE"
    elseif iszero(value)
        return "OFFLINE"
    end
    throw(
        IS.DataFormatError(
            "invalid status_at_start=$value for generator $gen_name in make_thermal_generator",
        ),
    )
end

function _thermal_status(gen_name::AbstractString, value::AbstractString)
    upper = uppercase(value)
    if upper in THERMAL_STATUS_ENUM_VALUES
        return upper
    end
    lowered = lowercase(value)
    if lowered == "true"
        return "ONLINE"
    elseif lowered == "false"
        return "OFFLINE"
    end
    throw(
        IS.DataFormatError(
            "invalid status_at_start=\"$value\" for generator $gen_name in make_thermal_generator",
        ),
    )
end

function _thermal_status(gen_name::AbstractString, value)
    throw(
        IS.DataFormatError(
            "invalid status_at_start=$value for generator $gen_name in make_thermal_generator",
        ),
    )
end

"""Schema enum values for `commitment_mode` on `ThermalStandard` / `ThermalMultiStart` / `HydroPumpTurbine`."""
const COMMITMENT_MODE_ENUM_VALUES =
    ("UNCOMMITTED", "COMMITTED", "SELF_SCHEDULED", "RELIABILITY", "MUST_RUN")

function _commitment_mode(gen_name::AbstractString, value::Bool)
    if value
        return "MUST_RUN"
    end
    return "COMMITTED"
end

function _commitment_mode(gen_name::AbstractString, value::Integer)
    if isone(value)
        return "MUST_RUN"
    elseif iszero(value)
        return "COMMITTED"
    end
    throw(
        IS.DataFormatError(
            "invalid must_run=$value for generator $gen_name in make_thermal_generator",
        ),
    )
end

function _commitment_mode(gen_name::AbstractString, value::AbstractString)
    upper = uppercase(value)
    if upper in COMMITMENT_MODE_ENUM_VALUES
        return upper
    end
    lowered = lowercase(value)
    if lowered == "true"
        return "MUST_RUN"
    elseif lowered == "false"
        return "COMMITTED"
    end
    throw(
        IS.DataFormatError(
            "invalid must_run=\"$value\" for generator $gen_name in make_thermal_generator",
        ),
    )
end

function _commitment_mode(gen_name::AbstractString, value)
    throw(
        IS.DataFormatError(
            "invalid must_run=$value for generator $gen_name in make_thermal_generator",
        ),
    )
end

function make_thermal_generator(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    cols,
)
    active_power_limits = _active_power_limits(gen)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    component = PO.ThermalStandard()
    set_value!(component, :id, register!(get_registry(sys), "ThermalStandard", gen.name))
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :status, _thermal_status(gen.name, gen.status_at_start))
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power, gen.active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(active_power_limits, reactive_power_limits),
        "MVA",
    )
    set_value!(component, :active_power_limits, active_power_limits, "MW")
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    _set_optional!(component, :ramp_limits, make_ramplimits(gen), "MW/min")
    _set_optional!(
        component,
        :time_limits,
        make_timelimits(gen, :min_up_time, :min_down_time),
        "min",
    )
    set_value!(
        component,
        :operation_cost,
        make_thermal_cost(data, gen, cols; per_unit = uses_per_unit(sys)),
    )
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    set_value!(component, :commitment_mode, _commitment_mode(gen.name, gen.must_run))
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    set_value!(component, :fuel, thermal_fuel(gen.fuel))
    return component
end

function make_synchronous_condenser(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    component = PO.SynchronousCondenser()
    set_value!(
        component,
        :id,
        register!(get_registry(sys), "SynchronousCondenser", gen.name),
    )
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(_active_power_limits(gen), reactive_power_limits),
        "MVA",
    )
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    return component
end

function make_renewable_generator(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    ::Val{:RenewableDispatch},
    cols,
)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    component = PO.RenewableDispatch()
    set_value!(component, :id, register!(get_registry(sys), "RenewableDispatch", gen.name))
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power, gen.active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(_active_power_limits(gen), reactive_power_limits),
        "MVA",
    )
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    set_value!(component, :power_factor, gen.power_factor, "1")
    set_value!(
        component,
        :operation_cost,
        make_renewable_cost(data, gen, cols; per_unit = uses_per_unit(sys)),
    )
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    return component
end

function make_renewable_generator(
    sys::OpenAPISystem,
    ::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    ::Val{:RenewableNonDispatch},
    ::Any,
)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    component = PO.RenewableNonDispatch()
    set_value!(
        component,
        :id,
        register!(get_registry(sys), "RenewableNonDispatch", gen.name),
    )
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power, gen.active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(_active_power_limits(gen), reactive_power_limits),
        "MVA",
    )
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    set_value!(component, :power_factor, gen.power_factor, "1")
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    return component
end

function make_hydro_dispatch(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    cols,
)
    active_power_limits = _active_power_limits(gen)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    component = PO.HydroDispatch()
    set_value!(component, :id, register!(get_registry(sys), "HydroDispatch", gen.name))
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power, gen.active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(active_power_limits, reactive_power_limits),
        "MVA",
    )
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    set_value!(component, :active_power_limits, active_power_limits, "MW")
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    _set_optional!(component, :ramp_limits, make_ramplimits(gen), "MW/min")
    _set_optional!(
        component,
        :time_limits,
        make_timelimits(gen, :min_up_time, :min_down_time),
        "min",
    )
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    set_value!(
        component,
        :operation_cost,
        make_hydro_cost(data, gen, cols; per_unit = uses_per_unit(sys)),
    )
    return component
end

"""
Create the reservoirs a hydro turbine draws on and link them to it.

A head reservoir is required; a tail reservoir is optional and only present for
units that discharge into a managed pool. Levels are energy, not volume, because
the tables state the pool in GWh.
"""
function make_hydro_reservoirs!(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    storage,
    turbine_id::Int,
)
    if !haskey(data.category_to_df, _category_key(InputCategory.STORAGE))
        throw(IS.DataFormatError("storage information must be defined in storage.csv"))
    end
    if !haskey(storage["head"], gen.name)
        throw(
            IS.DataFormatError("cannot find head storage for $(gen.name) in storage.csv"),
        )
    end

    ids = Int[]
    push!(
        ids,
        _add_reservoir!(sys, storage["head"][gen.name], "head", :downstream_turbines,
            turbine_id),
    )
    if haskey(storage["tail"], gen.name)
        push!(
            ids,
            _add_reservoir!(sys, storage["tail"][gen.name], "tail", :upstream_turbines,
                turbine_id),
        )
    end
    return ids
end

function _add_reservoir!(
    sys::OpenAPISystem,
    row::NamedTuple,
    position::AbstractString,
    link::Symbol,
    turbine_id::Int,
)
    name = string(row.name, "_", position)
    reservoir = PO.HydroReservoir()
    set_value!(reservoir, :id, register!(get_registry(sys), "HydroReservoir", name))
    set_value!(reservoir, :name, name)
    set_value!(reservoir, :available, row.available)
    # level_data_type discriminates the unit of every level quantity below, so it
    # must be set first: left at its USABLE_VOLUME default they would be read as
    # cubic metres.
    set_value!(reservoir, :level_data_type, "ENERGY")
    set_value!(
        reservoir,
        :storage_level_limits,
        (min = row.min_storage_capacity, max = row.storage_capacity),
        "MWh",
    )
    set_value!(reservoir, :initial_level, row.energy_level, "MWh")
    set_value!(reservoir, :inflow, 1.0, "MW")
    set_value!(reservoir, :outflow, 1.0, "MW")
    set_value!(reservoir, :level_targets, row.storage_target, "MWh")
    set_value!(reservoir, :intake_elevation, 0.0, "m")
    set_value!(
        reservoir,
        :head_to_volume_factor,
        IC.LinearFunctionData(; proportional_term = 1.0, constant_term = 0.0),
    )
    set_value!(reservoir, :operation_cost, PC.HydroReservoirCost())
    set_value!(reservoir, link, [turbine_id])
    add_component!(sys, reservoir)
    return get_value(reservoir, :id)
end

function make_hydro_turbine(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    storage,
    cols,
)
    active_power_limits = _active_power_limits(gen)
    reactive_power, reactive_power_limits = make_reactive_params(gen)

    # The reservoirs reference the turbine, so its id is allocated first.
    turbine_id = register!(get_registry(sys), "HydroTurbine", gen.name)
    make_hydro_reservoirs!(sys, data, gen, storage, turbine_id)

    component = PO.HydroTurbine()
    set_value!(component, :id, turbine_id)
    set_value!(component, :name, gen.name)
    set_value!(component, :available, gen.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power, gen.active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(
        component,
        :rating,
        calculate_gen_rating(active_power_limits, reactive_power_limits),
        "MVA",
    )
    set_value!(component, :active_power_limits, active_power_limits, "MW")
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    set_value!(component, :base_power, device_base_power(sys, gen), "MVA")
    set_value!(
        component,
        :operation_cost,
        make_hydro_cost(data, gen, cols; per_unit = uses_per_unit(sys)),
    )
    _set_optional!(component, :ramp_limits, make_ramplimits(gen), "MW/min")
    _set_optional!(
        component,
        :time_limits,
        make_timelimits(gen, :min_up_time, :min_down_time),
        "min",
    )
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    return component
end

function make_storage(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    gen::NamedTuple,
    bus_id::Int,
    storage,
)
    if !haskey(storage["head"], gen.name)
        throw(IS.DataFormatError("cannot find storage for $(gen.name) in storage.csv"))
    end
    row = storage["head"][gen.name]

    output_max = row.output_active_power_limit_max
    if isnothing(output_max)
        output_max = gen.active_power_limits_max
    end
    reactive_power, reactive_power_limits = make_reactive_params(row)

    component = PO.EnergyReservoirStorage()
    set_value!(
        component,
        :id,
        register!(get_registry(sys), "EnergyReservoirStorage", gen.name),
    )
    set_value!(component, :name, gen.name)
    set_value!(component, :available, row.available)
    set_value!(component, :bus, bus_id)
    set_value!(component, :prime_mover_type, prime_mover_type(gen.unit_type))
    set_value!(component, :storage_technology_type, "OTHER_CHEM")
    set_value!(component, :storage_capacity, row.storage_capacity, "MWh")
    set_value!(
        component,
        :storage_level_limits,
        IC.MinMax(; min = row.min_storage_capacity / row.storage_capacity, max = 1.0),
    )
    set_value!(
        component,
        :initial_storage_capacity_level,
        row.energy_level / row.storage_capacity,
        "1",
    )
    set_value!(component, :rating, row.rating, "MVA")
    set_value!(component, :active_power, row.active_power, "MW")
    set_value!(
        component,
        :input_active_power_limits,
        (min = row.input_active_power_limit_min, max = row.input_active_power_limit_max),
        "MW",
    )
    set_value!(
        component,
        :output_active_power_limits,
        (min = row.output_active_power_limit_min, max = output_max),
        "MW",
    )
    set_value!(
        component,
        :efficiency,
        IC.InOut(; in = row.input_efficiency, out = row.output_efficiency),
    )
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    _set_optional!(component, :reactive_power_limits, reactive_power_limits, "MVAr")
    set_value!(component, :base_power, row.base_power, "MVA")
    set_value!(component, :operation_cost, PC.StorageCost(; start_up = 0.0))
    return component
end

function _make_generator(::Val{T}, sys, data, gen, bus_id, storage, cols) where {T}
    throw(
        IS.DataFormatError(
            "no OpenAPI mapping for generator type $T (name=$(gen.name), " *
            "fuel=$(gen.fuel), unit_type=$(gen.unit_type))",
        ),
    )
end

function _make_generator(::Val{:ThermalStandard}, sys, data, gen, bus_id, storage, cols)
    return make_thermal_generator(sys, data, gen, bus_id, cols)
end

function _make_generator(::Val{:RenewableDispatch}, sys, data, gen, bus_id, storage, cols)
    return make_renewable_generator(
        sys,
        data,
        gen,
        bus_id,
        Val(:RenewableDispatch),
        cols,
    )
end

function _make_generator(
    ::Val{:RenewableNonDispatch},
    sys,
    data,
    gen,
    bus_id,
    storage,
    cols,
)
    return make_renewable_generator(
        sys,
        data,
        gen,
        bus_id,
        Val(:RenewableNonDispatch),
        cols,
    )
end

function _make_generator(::Val{:HydroTurbine}, sys, data, gen, bus_id, storage, cols)
    return make_hydro_turbine(sys, data, gen, bus_id, storage, cols)
end

function _make_generator(::Val{:HydroDispatch}, sys, data, gen, bus_id, storage, cols)
    return make_hydro_dispatch(sys, data, gen, bus_id, cols)
end

function _make_generator(
    ::Val{:SynchronousCondenser},
    sys,
    data,
    gen,
    bus_id,
    storage,
    cols,
)
    return make_synchronous_condenser(sys, data, gen, bus_id)
end

function _make_generator(
    ::Val{:EnergyReservoirStorage},
    sys,
    data,
    gen,
    bus_id,
    storage,
    cols,
)
    return make_storage(sys, data, gen, bus_id, storage)
end

function gen_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    storage = cache_storage(data; per_unit = uses_per_unit(sys))
    cols = cost_columns(data)
    for gen in iterate_rows(data, InputCategory.GENERATOR; per_unit = uses_per_unit(sys))
        bus_id = get_bus_id(reg, Int(gen.bus_id))
        type_name = get_generator_type(gen.fuel, gen.unit_type, data.generator_mapping)
        component = _make_generator(
            Val(Symbol(type_name)),
            sys,
            data,
            gen,
            bus_id,
            storage,
            cols,
        )
        add_component!(sys, component)
    end
    return
end
