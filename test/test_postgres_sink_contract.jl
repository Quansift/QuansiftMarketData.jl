using Test
using DataFrames
using Dates
using LibPQ
using TiingoJulia

@testset "PostgreSQL sink dispatch" begin
    postgres_module = TiingoJulia.DB.Postgres
    schema_module = TiingoJulia.DB.Schema

    @test PostgreSQLConnection === LibPQ.Connection

    persistence_methods = [
        (
            upsert_stock_data,
            Tuple{LibPQ.Connection,DataFrame,String},
        ),
        (
            upsert_stock_data_bulk,
            Tuple{LibPQ.Connection,DataFrame,String},
        ),
        (
            upsert_security_observations,
            Tuple{LibPQ.Connection,DataFrame},
        ),
        (
            upsert_fundamental_daily_metrics,
            Tuple{LibPQ.Connection,DataFrame},
        ),
        (
            postgres_module.replace_ticker_universe,
            Tuple{LibPQ.Connection,DataFrame,DataFrame},
        ),
    ]

    for (persistence_function, signature) in persistence_methods
        @test hasmethod(persistence_function, signature)
        @test which(persistence_function, signature).module === postgres_module
    end

    schema_signature = Tuple{LibPQ.Connection}
    @test hasmethod(create_tables, schema_signature)
    @test which(create_tables, schema_signature).module === schema_module
end

@testset "PostgreSQL temporary environment is serialized and restored" begin
    postgres_module = TiingoJulia.DB.Postgres
    variable = "TIINGO_TEST_TEMPORARY_ENV_LOCK"
    original = get(ENV, variable, nothing)
    pop!(ENV, variable, nothing)

    first_entered = Channel{Nothing}(1)
    release_first = Channel{Nothing}(1)
    second_entered = Ref(false)
    first = @async postgres_module.with_temporary_env(Dict(variable => "first")) do
        put!(first_entered, nothing)
        take!(release_first)
        @test ENV[variable] == "first"
    end
    take!(first_entered)
    second = @async postgres_module.with_temporary_env(Dict(variable => "second")) do
        second_entered[] = true
        @test ENV[variable] == "second"
    end

    yield()
    @test !second_entered[]
    @test ENV[variable] == "first"
    put!(release_first, nothing)
    wait(first)
    wait(second)
    @test second_entered[]
    @test !haskey(ENV, variable)

    if isnothing(original)
        pop!(ENV, variable, nothing)
    else
        ENV[variable] = original
    end
end

@testset "PostgreSQL upsert column mappings" begin
    postgres_module = TiingoJulia.DB.Postgres
    mapping_contracts = [
        postgres_module.STOCK_COLUMN_MAPPINGS,
        postgres_module.SECURITY_OBSERVATION_COLUMN_MAPPINGS,
        postgres_module.FUNDAMENTAL_METRIC_COLUMN_MAPPINGS,
        postgres_module.TICKER_UNIVERSE_COLUMN_MAPPINGS,
    ]

    for mappings in mapping_contracts
        source_values = Dict(
            source => index
            for (index, (source, _)) in enumerate(mappings)
        )
        input = DataFrame()
        for (source, _) in reverse(mappings)
            input[!, source] = [source_values[source]]
        end
        input[!, :ignored_extra_column] = [-1]

        mapped = postgres_module.select_upsert_columns(input, mappings)

        @test propertynames(mapped) == last.(mappings)
        @test nrow(mapped) == 1
        @test :ignored_extra_column ∉ propertynames(mapped)
        for (source, target) in mappings
            @test mapped[1, target] == source_values[source]
        end

        missing_source = first(first(mappings))
        incomplete = select(input, Not(missing_source))
        error = try
            postgres_module.select_upsert_columns(incomplete, mappings)
            nothing
        catch caught
            caught
        end
        @test error isa ArgumentError
        if error isa ArgumentError
            @test occursin(string(missing_source), sprint(showerror, error))
        end
    end
end
