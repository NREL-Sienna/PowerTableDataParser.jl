# Cost objects are Core value types rather than components, so they are built with
# keyword arguments. The empty-construct rule applies to components entering the
# container, not to the value objects nested inside them.

"""Heat-rate columns paired with the output points they apply at."""
struct HeatRateColumns
    columns::Vector{Tuple{Symbol, Symbol}}
end

"""Cost-point columns paired with the output points they apply at."""
struct CostPointColumns
    columns::Vector{Tuple{Symbol, Symbol}}
end

"""
The full heat-rate pairing the input descriptors define.

Every pair the descriptors know about is listed, not just the ones a given
dataset populates: absent columns read as `nothing` and `get_cost_pairs` drops
them, so no per-dataset narrowing is needed.
"""
const COST_COLUMN_NAMES = HeatRateColumns([
    (:heat_rate_avg_0, :output_point_0),
    [(Symbol("heat_rate_incr_$i"), Symbol("output_point_$i")) for i in 1:12]...,
])

const COST_POINT_COLUMN_NAMES = CostPointColumns([
    (Symbol("cost_point_$i"), Symbol("output_point_$i")) for i in 0:12
])

"""
Choose between the heat-rate and cost-point representations for a dataset.

The two are mutually exclusive, and a table declaring neither is a data error rather than
a zero-cost system.
"""
function cost_columns(data::PowerSystemTableData)
    fields = get_user_fields(data, InputCategory.GENERATOR)
    has_heat_rate = any(f -> occursin("heat_rate_", f), fields)
    has_cost_point = any(f -> occursin("cost_point_", f), fields)
    if has_heat_rate && has_cost_point
        throw(IS.ConflictingInputsError("Heat rate and cost points are both defined"))
    end
    if has_heat_rate
        return COST_COLUMN_NAMES
    end
    if has_cost_point
        return COST_POINT_COLUMN_NAMES
    end
    throw(IS.DataFormatError("Configuration for cost terms not recognized"))
end

"""
The active power maximum in MW, whichever convention the row arrived in.

Cost curve x coordinates are MW in both conventions — PowerSystems stores them
that way too — so this is the one place that has to undo a per-unit reading
rather than pass it through.
"""
function active_power_max_mw(gen::NamedTuple, per_unit::Bool)
    if per_unit
        return gen.base_mva * gen.active_power_limits_max
    end
    return gen.active_power_limits_max
end

"""
Return the `(x, y)` cost points, with `x` in MW.

Output points are fractions of the unit's active power maximum, so scaling by
that maximum yields MW.

Pairs whose column is empty are skipped: the descriptors declare 13 possible
points and a curve uses as many as it needs. The series is then truncated at the
first non-increasing x, since a repeated or falling point marks the end of the
curve rather than a segment.
"""
function get_cost_pairs(gen::NamedTuple, cost_colnames; per_unit::Bool = false)
    scale = active_power_max_mw(gen, per_unit)
    pairs = Tuple{Float64, Float64}[]
    for (y_name, x_name) in cost_colnames.columns
        x = getproperty(gen, x_name)
        y = getproperty(gen, y_name)
        if isnothing(x) || isnothing(y)
            continue
        end
        push!(pairs, (_as_float(x) * scale, _as_float(y)))
    end
    if isempty(pairs)
        return pairs
    end
    steps = diff([first(p) for p in pairs])
    last_increasing = findfirst(step -> step < 0.0, [steps..., -Inf])
    return pairs[1:last_increasing]
end

function _as_float(value::Real)
    return Float64(value)
end

function _as_float(value::AbstractString)
    parsed = tryparse(Float64, value)
    if isnothing(parsed)
        throw(IS.DataFormatError("expected a number, got \"$value\""))
    end
    return parsed
end

"""A `LinearFunctionData` wrapped as an input-output value curve."""
function linear_curve(proportional_term::Float64, constant_term::Float64 = 0.0)
    return PC.InputOutputCurve(;
        curve_type = "INPUT_OUTPUT",
        function_data = PC.InputOutputCurveFunctionData(
            IC.LinearFunctionData(;
                function_type = "LINEAR",
                proportional_term = proportional_term,
                constant_term = constant_term,
            ),
        ),
    )
end

function quadratic_curve(quadratic_term, proportional_term, constant_term)
    return PC.InputOutputCurve(;
        curve_type = "INPUT_OUTPUT",
        function_data = PC.InputOutputCurveFunctionData(
            IC.QuadraticFunctionData(;
                function_type = "QUADRATIC",
                quadratic_term = quadratic_term,
                proportional_term = proportional_term,
                constant_term = constant_term,
            ),
        ),
    )
end

"""The piecewise input-output data for a set of cost points."""
function create_pwl_cost(cost_pairs)
    points = [IC.XYCoords(; x = first(p), y = last(p)) for p in cost_pairs]
    return IC.PiecewiseLinearData(; function_type = "PIECEWISE_LINEAR", points = points)
end

"""
The piecewise step data for a set of incremental cost points.

The first y is the average rate at the first point and becomes the curve's
initial input, so only the remaining y values are slopes.
"""
function create_pwinc_cost(cost_pairs)
    return IC.PiecewiseStepData(;
        function_type = "PIECEWISE_STEP",
        x_coords = [first(p) for p in cost_pairs],
        y_coords = [last(p) for p in cost_pairs[2:end]],
    )
end

"""
Read the polynomial heat-rate coefficients into a value curve.

Three shapes are supported: all of `a2, a1, a0`; `a1` and `a0`; or `a1` alone. A
quadratic term without the lower coefficients is a data error. Returns an
input-output curve rather than bare `QuadraticFunctionData`, since two of the
three shapes are linear.
"""
function create_poly_cost(gen::NamedTuple)
    a2 = _maybe_float(gen.heat_rate_a2)
    a1 = _maybe_float(gen.heat_rate_a1)
    a0 = _maybe_float(gen.heat_rate_a0)

    if !isnothing(a2) && (isnothing(a1) || isnothing(a0))
        throw(
            IS.DataFormatError(
                "$(gen.name): all coefficients must be passed if the quadratic term is",
            ),
        )
    end
    if !isnothing(a2)
        return quadratic_curve(a2, a1, a0)
    end
    if isnothing(a0)
        return linear_curve(a1)
    end
    return linear_curve(a1, a0)
end

function _maybe_float(value::Nothing)
    return nothing
end

function _maybe_float(value)
    return _as_float(value)
end

"""Value curve for a piecewise input-output cost, with fallbacks for a short series."""
function _pwl_value_curve(gen::NamedTuple, cost_pairs)
    if length(cost_pairs) > 1
        return PC.InputOutputCurve(;
            curve_type = "INPUT_OUTPUT",
            function_data = PC.InputOutputCurveFunctionData(create_pwl_cost(cost_pairs)),
        )
    end
    if length(cost_pairs) == 1
        # A single point fixes a constant rate per MW.
        return linear_curve(last(only(cost_pairs)) / first(only(cost_pairs)))
    end
    @warn "$(gen.name) has no costs defined, using 0.0" maxlog = 5
    return linear_curve(0.0)
end

"""Value curve for a piecewise incremental cost, with fallbacks for a short series."""
function _pwinc_value_curve(gen::NamedTuple, cost_pairs)
    if length(cost_pairs) > 1
        first_pair = first(cost_pairs)
        return PC.IncrementalCurve(;
            curve_type = "INCREMENTAL",
            initial_input = last(first_pair) * first(first_pair),
            function_data = PC.IncrementalCurveFunctionData(create_pwinc_cost(cost_pairs)),
        )
    end
    if length(cost_pairs) == 1
        return linear_curve(last(only(cost_pairs)))
    end
    @warn "Unable to calculate variable cost for $(gen.name), using 0.0" maxlog = 5
    return linear_curve(0.0)
end

"""Fuel price per MBtu; the tables state it per MMBtu."""
function fuel_price(gen::NamedTuple)
    return _as_float(gen.fuel_price) / 1000.0
end

function _vom_curve(gen::NamedTuple)
    vom = gen.variable_cost
    if isnothing(vom)
        return linear_curve(0.0)
    end
    return linear_curve(_as_float(vom))
end

"""
Start-up and shut-down costs.

Where the data states a total start cost it is used as given. Otherwise the cost
is built from what a start consumes: the cold-start fuel requirement priced at
the unit's fuel price, plus any non-fuel start cost the table states separately.

A missing shut-down cost is zero.
"""
function calculate_uc_cost(gen::NamedTuple, price::Float64)
    start_up = _maybe_float(get(gen, :startup_cost, nothing))
    if isnothing(start_up)
        fuel_cost = 0.0
        if !isnothing(gen.startup_heat_cold_cost)
            fuel_cost = _as_float(gen.startup_heat_cold_cost) * price * 1000
        end
        non_fuel_cost = _maybe_float(get(gen, :non_fuel_startup_cost, nothing))
        if isnothing(non_fuel_cost)
            non_fuel_cost = 0.0
        end
        start_up = fuel_cost + non_fuel_cost
        if iszero(start_up)
            @warn "No start cost defined for $(gen.name), setting to 0.0" maxlog = 5
        end
    end

    shut_down = get(gen, :shutdown_cost, nothing)
    if isnothing(shut_down)
        @warn "No shutdown_cost defined for $(gen.name), setting to 0.0" maxlog = 1
        shut_down = 0.0
    end
    return _as_float(start_up), _as_float(shut_down)
end

"""
Thermal operation cost from heat-rate columns.

Heat rates make this a `FuelCurve`: the value curve is in fuel per MW and the
price converts it to money. `fixed` is on the same footing, hence the scaling.
"""
function make_thermal_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::HeatRateColumns;
    per_unit::Bool = false,
)
    price = fuel_price(gen)
    fixed = 0.0
    if isnothing(gen.heat_rate_a0) &&
       isnothing(gen.heat_rate_a1) &&
       isnothing(gen.heat_rate_a2)
        value_curve =
            _pwinc_value_curve(gen, get_cost_pairs(gen, cols; per_unit = per_unit))
    else
        value_curve = create_poly_cost(gen)
    end
    start_up, shut_down = calculate_uc_cost(gen, price)
    return PC.ThermalGenerationCost(;
        cost_type = "THERMAL",
        variable_operation_cost = PC.ProductionVariableCostCurve(
            PC.FuelCurve(;
                value_curve = PC.ValueCurve(value_curve),
                power_units = IC.UnitSystem("NATURAL_UNITS"),
                variable_cost_type = "FUEL",
                fuel_cost = price,
                vom_cost = _vom_curve(gen),
            ),
        ),
        fixed = fixed * price,
        start_up = _coerce(PC.ThermalGenerationCostStartUp, start_up),
        shut_down = shut_down,
    )
end

"""Thermal operation cost from money-per-hour cost points."""
function make_thermal_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::CostPointColumns;
    per_unit::Bool = false,
)
    price = fuel_price(gen)
    start_up, shut_down = calculate_uc_cost(gen, price)
    return PC.ThermalGenerationCost(;
        cost_type = "THERMAL",
        variable_operation_cost = PC.ProductionVariableCostCurve(
            PC.CostCurve(;
                value_curve = PC.ValueCurve(
                    _pwl_value_curve(gen, get_cost_pairs(gen, cols; per_unit = per_unit)),
                ),
                power_units = IC.UnitSystem("NATURAL_UNITS"),
                variable_cost_type = "COST",
                vom_cost = _vom_curve(gen),
            ),
        ),
        fixed = _fixed_cost(gen),
        start_up = _coerce(PC.ThermalGenerationCostStartUp, start_up),
        shut_down = shut_down,
    )
end

function make_thermal_cost(
    data::PowerSystemTableData,
    gen::NamedTuple;
    per_unit::Bool = false,
)
    return make_thermal_cost(data, gen, cost_columns(data); per_unit = per_unit)
end

function make_hydro_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::HeatRateColumns;
    per_unit::Bool = false,
)
    price = fuel_price(gen)
    return PC.HydroGenerationCost(;
        cost_type = "HYDRO_GEN",
        variable_operation_cost = PC.ProductionVariableCostCurve(
            PC.FuelCurve(;
                value_curve = PC.ValueCurve(
                    _pwinc_value_curve(gen, get_cost_pairs(gen, cols; per_unit = per_unit)),
                ),
                power_units = IC.UnitSystem("NATURAL_UNITS"),
                variable_cost_type = "FUEL",
                fuel_cost = price,
                vom_cost = _vom_curve(gen),
            ),
        ),
        fixed = 0.0,
    )
end

function make_hydro_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::CostPointColumns;
    per_unit::Bool = false,
)
    return PC.HydroGenerationCost(;
        cost_type = "HYDRO_GEN",
        variable_operation_cost = PC.ProductionVariableCostCurve(
            PC.CostCurve(;
                value_curve = PC.ValueCurve(
                    _pwl_value_curve(gen, get_cost_pairs(gen, cols; per_unit = per_unit)),
                ),
                power_units = IC.UnitSystem("NATURAL_UNITS"),
                variable_cost_type = "COST",
                vom_cost = _vom_curve(gen),
            ),
        ),
        fixed = _fixed_cost(gen),
    )
end

function make_hydro_cost(
    data::PowerSystemTableData,
    gen::NamedTuple;
    per_unit::Bool = false,
)
    return make_hydro_cost(data, gen, cost_columns(data); per_unit = per_unit)
end

"""
Renewable operation cost.

Heat rates do not describe a renewable unit, so only the VOM term survives and
the value curve is zero.
"""
function make_renewable_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::HeatRateColumns;
    per_unit::Bool = false,
)
    @warn "Heat rate parsing is not valid for a renewable unit; using a zero cost curve" maxlog =
        5
    return PC.RenewableGenerationCost(;
        cost_type = "RENEWABLE",
        variable_operation_cost = PC.CostCurve(;
            value_curve = PC.ValueCurve(linear_curve(0.0)),
            power_units = IC.UnitSystem("NATURAL_UNITS"),
            variable_cost_type = "COST",
            vom_cost = _vom_curve(gen),
        ),
    )
end

function make_renewable_cost(
    data::PowerSystemTableData,
    gen::NamedTuple,
    cols::CostPointColumns;
    per_unit::Bool = false,
)
    return PC.RenewableGenerationCost(;
        cost_type = "RENEWABLE",
        variable_operation_cost = PC.CostCurve(;
            value_curve = PC.ValueCurve(
                _pwl_value_curve(gen, get_cost_pairs(gen, cols; per_unit = per_unit)),
            ),
            power_units = IC.UnitSystem("NATURAL_UNITS"),
            variable_cost_type = "COST",
            vom_cost = _vom_curve(gen),
        ),
    )
end

function make_renewable_cost(
    data::PowerSystemTableData,
    gen::NamedTuple;
    per_unit::Bool = false,
)
    return make_renewable_cost(data, gen, cost_columns(data); per_unit = per_unit)
end

function _fixed_cost(gen::NamedTuple)
    if isnothing(gen.fixed_cost)
        return 0.0
    end
    return _as_float(gen.fixed_cost)
end
