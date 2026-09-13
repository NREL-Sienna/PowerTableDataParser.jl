# Supplemental attributes: data the tables state about a component that is not
# part of the component itself. None of this reaches a PowerSystems System from
# table data today — the columns are read and dropped — but the schemas carry all
# three, so the parser emits them.
#
# Each attribute is linked to its entity through the association table, the same
# separation the time series associations use.

"""
Emission columns paired with the pollutant each one reports.

Only particulates take `CUSTOM`: the enum splits them into PM25 and PM10 by a
particle size the table does not state, so choosing one would assert something
the data does not. The attribute name carries the pollutant either way.
"""
const EMISSION_COLUMNS = [
    (:emissions_so2, "SO2", "SO2"),
    (:emissions_nox, "NOX", "NOX"),
    (:emissions_co2, "CO2", "CO2"),
    (:emissions_ch4, "CH4", "CH4"),
    (:emissions_n2o, "N2O", "N2O"),
    (:emissions_co, "CO", "CO"),
    (:emissions_vocs, "VOC", "VOCs"),
    (:emissions_particulates, "CUSTOM", "particulates"),
]

"""Minutes in a year, for turning a per-year outage rate into a per-minute probability."""
const MINUTES_PER_YEAR = 8760.0 * 60.0

"""
A constant emission rate as a value curve.

The rate is mass per unit of fuel input and does not vary with output, so the
incremental curve is a constant function: the marginal rate is the rate.
"""
function emission_rate_curve(rate::Float64)
    return PC.IncrementalCurve(;
        curve_type = "INCREMENTAL",
        initial_input = 0.0,
        function_data = PC.IncrementalCurveFunctionData(
            IC.LinearFunctionData(;
                function_type = "LINEAR",
                proportional_term = 0.0,
                constant_term = rate,
            ),
        ),
    )
end

"""
The stated emission rate, or nothing where the table states something else.

RTS writes "Unit-specific" for the coal and oil steam units whose sulfur and
nitrogen rates depend on the fuel they burn. That is a marker, not a rate: there
is no number to record, so the attribute is not emitted and the unit is named in
a warning rather than passed over in silence.
"""
function _emission_rate(value::Real, gen_name, label)
    return Float64(value)
end

function _emission_rate(value::AbstractString, gen_name, label)
    parsed = tryparse(Float64, value)
    if isnothing(parsed)
        @warn "$gen_name states \"$value\" for $label rather than a rate; " *
              "no emissions attribute emitted" maxlog = 5
        return nothing
    end
    return parsed
end

function _emission_rate(::Nothing, gen_name, label)
    return nothing
end

"""
Emit one `EmissionsData` attribute per pollutant a generator reports.

A zero rate is not an emission and is skipped, which is why the count is well
under one attribute per pollutant per unit.
"""
function emissions_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for gen in iterate_rows(data, InputCategory.GENERATOR; per_unit = uses_per_unit(sys))
        entity_id = _generator_entity(reg, gen)
        for (column, pollutant, label) in EMISSION_COLUMNS
            rate = _emission_rate(getproperty(gen, column), gen.name, label)
            if isnothing(rate) || iszero(rate)
                continue
            end
            name = string(gen.name, "_", label)
            attribute = stage(PC.EmissionsData)
            set_value!(attribute, :id, register!(reg, "EmissionsData", name))
            set_value!(attribute, :name, name)
            set_value!(attribute, :pollutant, pollutant)
            set_value!(attribute, :emission_rate, emission_rate_curve(rate))
            set_value!(attribute, :basis, "FUEL_INPUT")
            set_value!(attribute, :mass_unit, "LB")
            set_value!(attribute, :energy_unit, "MMBTU")
            set_value!(attribute, :available, true)
            add_supplemental_attribute!(sys, attribute, entity_id)
        end
    end
    return
end

"""
Forced outage statistics for generators and branches.

Both tables state a mean time to recovery and a failure frequency, which is what
the geometric model wants: the transition probability is the reciprocal of the
mean time to failure, per hour. Generators state that time directly; branches
state a rate per year instead, so it is converted.

The schemas state the recovery time as a whole number of minutes and the
transition probability over that same minute, so both are converted from the
hours and years the tables use.
"""
function outages_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for gen in iterate_rows(data, InputCategory.GENERATOR; per_unit = uses_per_unit(sys))
        mttf = _maybe_float(gen.mttf)
        mttr = _maybe_float(gen.mttr)
        if isnothing(mttf) || isnothing(mttr) || iszero(mttf)
            continue
        end
        entity_id = _generator_entity(reg, gen)
        _add_forced_outage!(
            sys,
            entity_id,
            mttr,
            1.0 / _hours_to_minutes(mttf),
        )
    end

    for branch in iterate_rows(data, InputCategory.BRANCH; per_unit = uses_per_unit(sys))
        rate = _maybe_float(branch.permanent_outage_rate)
        duration = _maybe_float(branch.permanent_outage_duration)
        if isnothing(rate) || isnothing(duration) || iszero(rate)
            continue
        end
        entity_id = _branch_entity(reg, branch)
        _add_forced_outage!(sys, entity_id, duration, rate / MINUTES_PER_YEAR)
    end
    return
end

function _add_forced_outage!(
    sys::OpenAPISystem,
    entity_id::Int,
    recovery_hours::Float64,
    transition_probability::Float64,
)
    attribute = stage(PO.GeometricDistributionForcedOutage)
    set_value!(attribute, :id, next_id!(get_registry(sys)))
    # The schema wants whole minutes, so the conversion is rounded before it is
    # assigned rather than left to a float with spurious sub-minute precision.
    minutes = round(_hours_to_minutes(recovery_hours))
    set_value!(attribute, :mean_time_to_recovery, minutes, "min")
    set_value!(attribute, :outage_transition_probability, transition_probability)
    set_value!(attribute, :monitored_components, Int[])
    add_supplemental_attribute!(sys, attribute, entity_id)
    return
end

"""
Bus positions as GeoJSON points.

The tables state a latitude and a longitude; GeoJSON orders a position longitude
first, which is the one place this is easy to get backwards.
"""
function geographic_info_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for bus in iterate_rows(data, InputCategory.BUS; per_unit = uses_per_unit(sys))
        latitude = _maybe_float(bus.latitude)
        longitude = _maybe_float(bus.longitude)
        if isnothing(latitude) || isnothing(longitude)
            continue
        end
        attribute = stage(IC.GeographicInfo)
        set_value!(attribute, :id, next_id!(reg))
        set_value!(
            attribute,
            :geo_json,
            Dict{String, Any}(
                "type" => "Point",
                "coordinates" => [longitude, latitude],
            ),
        )
        add_supplemental_attribute!(sys, attribute, get_bus_id(reg, Int(bus.bus_id)))
    end
    return
end

"""
Attach the columns the descriptors do not declare to the component each row made.

Nothing in the tables is dropped for want of a field: what the data model can
hold becomes a property, and the rest is recorded against the same component id.
"""
function ext_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for (category, resolve) in (
        (InputCategory.BUS, _bus_entity),
        (InputCategory.GENERATOR, _generator_entity),
        (InputCategory.BRANCH, _branch_entity),
        (InputCategory.DC_BRANCH, _dc_branch_entity),
    )
        if isempty(get_dataframe(data, category))
            continue
        end
        for row in iterate_rows(
            data,
            category;
            per_unit = uses_per_unit(sys),
            extras = true,
        )
            set_ext!(sys, resolve(reg, row), row.ext)
        end
    end
    return
end

_bus_entity(reg::IdRegistry, row) = get_bus_id(reg, Int(row.bus_id))

function _generator_entity(reg::IdRegistry, row)
    _, id = find_by_name(reg, category_to_type_names("Generator"), row.name)
    return id
end

function _branch_entity(reg::IdRegistry, row)
    type_name = get_branch_type(row.tap, get(row, :is_transformer, nothing))
    _, id = find_by_name(reg, [string(type_name)], row.name)
    return id
end

function _dc_branch_entity(reg::IdRegistry, row)
    _, id = find_by_name(reg, ["TwoTerminalGenericHVDCLine"], row.name)
    return id
end
