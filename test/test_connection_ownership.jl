using Test
using QuansiftMarketData

struct CallablePostgresOpener
    connection
    events::Vector{Symbol}
end

function (opener::CallablePostgresOpener)(::String)
    push!(opener.events, :open)
    return opener.connection
end

@testset "Owned DuckDB initialization closes only on failure" begin
    events = Symbol[]
    connection = Ref(:duckdb_connection)
    connector = _ -> begin
        push!(events, :open)
        connection
    end
    closer = conn -> begin
        @test conn === connection
        push!(events, :close)
    end

    @test QuansiftMarketData.DB.initialize_owned_duckdb(
        "offline.duckdb";
        connector,
        initializer = _ -> push!(events, :initialize),
        closer,
    ) === connection
    @test events == [:open, :initialize]

    empty!(events)
    @test_throws ErrorException QuansiftMarketData.DB.initialize_owned_duckdb(
        "offline.duckdb";
        connector,
        initializer = _ -> begin
            push!(events, :initialize)
            error("injected schema failure")
        end,
        closer,
    )
    @test events == [:open, :initialize, :close]
end

@testset "Owned PostgreSQL validation closes failed attempts" begin
    events = Symbol[]
    connection = Ref(:postgres_connection)
    opener = CallablePostgresOpener(connection, events)
    closer = conn -> begin
        @test conn === connection
        push!(events, :close)
    end

    @test QuansiftMarketData.DB.Postgres.open_validated_postgres_connection(
        "offline";
        opener,
        validator = _ -> push!(events, :validate),
        closer,
    ) === connection
    @test events == [:open, :validate]

    empty!(events)
    @test_throws ErrorException QuansiftMarketData.DB.Postgres.open_validated_postgres_connection(
        "offline";
        opener,
        validator = _ -> begin
            push!(events, :validate)
            error("injected validation failure")
        end,
        closer,
    )
    @test events == [:open, :validate, :close]
end
