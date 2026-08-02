using Test
using DataFrames
using Logging
using TiingoJulia
using TiingoJulia.DB.Schema:
    generate_create_table_query,
    qualified_postgres_identifier
using TiingoJulia.DB.Postgres:
    generate_dataframe_insert_query,
    generate_refresh_upsert_query

@testset "PostgreSQL connection errors never expose credentials" begin
    postgres_module = TiingoJulia.DB.Postgres
    fake_user = "security-review-user"
    fake_secret = "security-review-password"
    malformed = "postgresql://$fake_user:$fake_secret@[invalid/database"

    caught = try
        postgres_module.normalize_postgres_connection_string(malformed)
        nothing
    catch error
        error
    end
    @test caught isa ArgumentError
    message = sprint(showerror, caught)
    @test occursin("Invalid PostgreSQL connection string", message)
    @test !occursin(fake_user, message)
    @test !occursin(fake_secret, message)

    log_buffer = IOBuffer()
    connection_error = with_logger(SimpleLogger(log_buffer, Logging.Warn)) do
        try
            connect_postgres(malformed; max_retries=1, retry_delay=0)
            nothing
        catch error
            error
        end
    end
    logged = String(take!(log_buffer))
    @test connection_error isa Exception
    @test !occursin(fake_user, sprint(showerror, connection_error))
    @test !occursin(fake_secret, sprint(showerror, connection_error))
    @test !occursin(fake_user, logged)
    @test !occursin(fake_secret, logged)

    synthetic = postgres_module.sanitize_postgres_connection_error(
        ErrorException(
            "connection failed for user='$fake_user' password='$fake_secret'",
        ),
    )
    synthetic_message = sprint(showerror, synthetic)
    @test !occursin(fake_user, synthetic_message)
    @test !occursin(fake_secret, synthetic_message)
    @test occursin("[REDACTED]", synthetic_message)
end

@testset "Canonical PostgreSQL SQL is public-schema qualified" begin
    postgres_module = TiingoJulia.DB.Postgres
    @test qualified_postgres_identifier("Historical_Data") ==
          "\"public\".\"historical_data\""
    @test qualified_postgres_identifier("stage"; schema="pg_temp") ==
          "\"pg_temp\".\"stage\""

    schema = DataFrame(
        column_name=["Ticker", "Date", "Close"],
        column_type=["VARCHAR", "DATE", "DOUBLE"],
    )
    @test startswith(
        generate_create_table_query("Historical_Data", schema),
        "CREATE TABLE IF NOT EXISTS \"public\".\"historical_data\"",
    )
    @test generate_dataframe_insert_query("Historical_Data", ["Ticker", "Close"]) ==
          "INSERT INTO \"public\".\"historical_data\" " *
          "(\"ticker\", \"close\") VALUES (\$1, \$2)"
    refresh = generate_refresh_upsert_query(
        "Historical_Data",
        "Historical_Data_Stage",
        ["Ticker", "Close"],
        ["Ticker"],
    )
    @test occursin("INSERT INTO \"public\".\"historical_data\"", refresh)
    @test occursin("FROM \"public\".\"historical_data_stage\"", refresh)
    @test postgres_module.generate_drop_postgres_table_query("Historical_Data") ==
          "DROP TABLE IF EXISTS \"public\".\"historical_data\";"
    @test postgres_module.generate_postgres_table_row_count_query("Historical_Data") ==
          "SELECT count(*) AS row_count FROM \"public\".\"historical_data\""
    @test postgres_module.POSTGRES_TRUNCATE_TICKER_UNIVERSE_SQL ==
          "TRUNCATE TABLE \"public\".\"us_tickers\", " *
          "\"public\".\"us_tickers_filtered\""

    postgres_source = read(
        joinpath(@__DIR__, "..", "src", "db", "postgres.jl"),
        String,
    )
    @test !occursin("DROP TABLE IF EXISTS \$safe_name", postgres_source)
    @test !occursin("TRUNCATE TABLE us_tickers", postgres_source)
    @test !occursin("COPY postgres_db.\$safe_staging", postgres_source)
end
