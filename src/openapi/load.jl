# RTS has no load.csv — its load lives on the bus rows and is emitted by
# bus_csv_parser! — so this path exists for datasets that state loads separately.

"""
Return a `PowerLoad` name that is free within the registry.

`bus_csv_parser!` already registers a `PowerLoad` per loaded bus, and a separate
load table may name a load after its bus. The prefixed name is registered
normally, so a second collision still throws rather than being papered over.
"""
function _load_name(reg::IdRegistry, name::AbstractString)
    if !has_id(reg, "PowerLoad", name)
        return String(name)
    end
    return string("load_", name)
end

function load_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for row in iterate_rows(data, InputCategory.LOAD; per_unit = uses_per_unit(sys))
        bus_id = get_bus_id(reg, Int(row.bus_id))
        name = _load_name(reg, row.name)

        load = stage(PO.PowerLoad)
        set_value!(load, :id, register!(reg, "PowerLoad", name))
        set_value!(load, :name, name)
        set_value!(load, :available, row.available)
        set_value!(load, :bus, bus_id)
        set_value!(load, :active_power, row.active_power, "MW")
        set_value!(load, :reactive_power, row.reactive_power, "MVAr")
        set_value!(load, :base_power, row.base_power, "MVA")
        set_value!(load, :max_active_power, row.max_active_power, "MW")
        set_value!(load, :max_reactive_power, row.max_reactive_power, "MVAr")
        add_component!(sys, load)
    end
    return
end
