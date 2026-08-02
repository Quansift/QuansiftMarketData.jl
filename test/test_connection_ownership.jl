using Test
using TiingoJulia

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

    @test TiingoJulia.DB.initialize_owned_duckdb(
        "offline.duckdb";
        connector,
        initializer = _ -> push!(events, :initialize),
        closer,
    ) === connection
    @test events == [:open, :initialize]

    empty!(events)
    @test_throws ErrorException TiingoJulia.DB.initialize_owned_duckdb(
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
    opener = _ -> begin
        push!(events, :open)
        connection
    end
    closer = conn -> begin
        @test conn === connection
        push!(events, :close)
    end

    @test TiingoJulia.DB.Postgres.open_validated_postgres_connection(
        "offline";
        opener,
        validator = _ -> push!(events, :validate),
        closer,
    ) === connection
    @test events == [:open, :validate]

    empty!(events)
    @test_throws ErrorException TiingoJulia.DB.Postgres.open_validated_postgres_connection(
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
