isdefined(Base, :__precompile__) && __precompile__()

module PowerTableDataParser

#################################################################################
# Exports

export PowerSystemTableData
export OpenAPISystem

#################################################################################
# Imports

import CSV
import DataFrames
import Dates
import JSON
import OpenAPI
import SQLite
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems
import InfrastructureSystems:
    DataFormatError

import OpenAPI.Runtime: Absent

import InfrastructureCoreOpenAPIModels
import PowerCoreOpenAPIModels
import PowerOperationsOpenAPIModels
import InfrastructureTimeSeriesOpenAPIModels
import PowerOpenAPIModels
const IC = InfrastructureCoreOpenAPIModels
const PC = PowerCoreOpenAPIModels
const PO = PowerOperationsOpenAPIModels
const PTS = InfrastructureTimeSeriesOpenAPIModels
const PD = PowerOpenAPIModels

#################################################################################
# Includes

include("common.jl")
include("enums.jl")
include("power_system_table_data.jl")
include("time_series_pointers.jl")
include("openapi/accessors.jl")
include("openapi/identity.jl")
include("openapi/units.jl")
include("openapi/container.jl")
include("openapi/topology.jl")
include("openapi/branch.jl")
include("openapi/cost.jl")
include("openapi/dc_branch.jl")
include("openapi/generation.jl")
include("openapi/load.jl")
include("openapi/service.jl")
include("openapi/attributes.jl")
include("openapi/time_series.jl")
include("openapi/build.jl")
include("openapi/serialize.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end
