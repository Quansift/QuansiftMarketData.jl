using Test
using DataFrames
using TiingoJulia
using TiingoJulia.DB.Schema:
    generate_create_table_query,
    map_duckdb_to_postgres_type,
    quote_postgres_identifier
using TiingoJulia.DB.Postgres:
    generate_dataframe_insert_query,
    generate_refresh_upsert_query

@testset "Legacy PostgreSQL SQL generation quotes identifiers" begin
    @test quote_postgres_identifier("Price") == "\"Price\""
    @test quote_postgres_identifier("close\"; DROP TABLE audit; --") ==
          "\"close\"\"; DROP TABLE audit; --\""
    @test_throws ArgumentError quote_postgres_identifier("bad\0name")

    schema = DataFrame(
        column_name=["Ticker", "close\"; DROP TABLE audit; --"],
        column_type=["VARCHAR", "DOUBLE"],
    )
    create_query = generate_create_table_query("Prices\"; DROP TABLE audit; --", schema)
    @test create_query ==
          "CREATE TABLE IF NOT EXISTS \"public\".\"prices\"\"; drop table audit; --\" " *
          "(\"ticker\" VARCHAR, \"close\"\"; drop table audit; --\" DOUBLE PRECISION)"

    insert_query = generate_dataframe_insert_query(
        "Historical_Data_Staging",
        ["Ticker", "close\"; DROP TABLE audit; --"],
    )
    @test insert_query ==
          "INSERT INTO \"public\".\"historical_data_staging\" " *
          "(\"ticker\", \"close\"\"; drop table audit; --\") VALUES (\$1, \$2)"

    refresh_query = generate_refresh_upsert_query(
        "Historical_Data",
        "Historical_Data_Staging",
        ["Ticker", "close\"; DROP TABLE audit; --"],
        ["Ticker"],
    )
    @test refresh_query ==
          "INSERT INTO \"public\".\"historical_data\" " *
          "(\"ticker\", \"close\"\"; drop table audit; --\") " *
          "SELECT \"ticker\", \"close\"\"; drop table audit; --\" " *
          "FROM \"public\".\"historical_data_staging\" ON CONFLICT (\"ticker\") " *
          "DO UPDATE SET \"close\"\"; drop table audit; --\" = " *
          "EXCLUDED.\"close\"\"; drop table audit; --\""
    @test generate_refresh_upsert_query("Keys", "Keys_Staging", ["Id"], ["Id"]) ==
          "INSERT INTO \"public\".\"keys\" (\"id\") SELECT \"id\" " *
          "FROM \"public\".\"keys_staging\" " *
          "ON CONFLICT (\"id\") DO NOTHING"

    historical_schema = DataFrame(
        column_name=["Ticker", "Date"],
        column_type=["VARCHAR", "DATE"],
    )
    historical_query = generate_create_table_query(
        "Historical_Data_Staging",
        historical_schema,
    )
    @test occursin("PRIMARY KEY (\"ticker\", \"date\")", historical_query)
end

@testset "Legacy PostgreSQL type mapping is allowlisted" begin
    expected_types = Dict(
        " varchar " => "VARCHAR",
        "integer" => "INTEGER",
        "BIGINT" => "BIGINT",
        "FLOAT" => "REAL",
        "DOUBLE" => "DOUBLE PRECISION",
        "BOOLEAN" => "BOOLEAN",
        "DATE" => "DATE",
        "TIMESTAMP" => "TIMESTAMP",
    )
    for (duckdb_type, postgres_type) in expected_types
        @test map_duckdb_to_postgres_type(duckdb_type) == postgres_type
    end

    @test_throws ArgumentError map_duckdb_to_postgres_type("DECIMAL(18, 2)")
    @test_throws ArgumentError map_duckdb_to_postgres_type("INTEGER[]")
    @test_throws ArgumentError map_duckdb_to_postgres_type("UBIGINT")
    @test_throws ArgumentError map_duckdb_to_postgres_type(
        "TEXT); DROP TABLE historical_data; --",
    )
end
