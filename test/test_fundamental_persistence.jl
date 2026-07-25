using Test
using Dates
using DataFrames
using DuckDB
using DBInterface
using TiingoJulia
using TiingoJulia.DB.Schema: generate_create_table_query

@testset "Fundamental persistence schema and keys" begin
    conn = connect_duckdb(":memory:")
    try
        tables = DBInterface.execute(conn, """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_name IN ('security_observations', 'fundamental_daily_metrics')
            ORDER BY table_name
        """) |> DataFrame
        @test tables.table_name == ["fundamental_daily_metrics", "security_observations"]

        security_schema = DBInterface.execute(conn, "DESCRIBE security_observations") |> DataFrame
        metrics_schema = DBInterface.execute(conn, "DESCRIBE fundamental_daily_metrics") |> DataFrame
        @test security_schema.column_name == [
            "perma_ticker",
            "observed_at",
            "ticker",
            "is_active",
            "is_adr",
            "daily_last_updated",
            "exchange",
            "asset_type",
            "price_coverage_start",
            "price_coverage_end",
            "is_leveraged",
            "join_status",
        ]
        @test metrics_schema.column_name == [
            "perma_ticker",
            "metric_date",
            "market_cap",
            "enterprise_value",
            "pe_ratio",
            "available_at",
            "fetched_at",
            "source_revision",
        ]
        @test security_schema[coalesce.(security_schema.key .== "PRI", false), :column_name] == [
            "perma_ticker",
            "observed_at",
        ]
        @test metrics_schema[coalesce.(metrics_schema.key .== "PRI", false), :column_name] == [
            "perma_ticker",
            "metric_date",
        ]

        historical_schema = DBInterface.execute(conn, "DESCRIBE historical_data") |> DataFrame
        historical_query = generate_create_table_query("historical_data_staging", historical_schema)
        security_query = generate_create_table_query("security_observations_staging", security_schema)
        metrics_query = generate_create_table_query("fundamental_daily_metrics_staging", metrics_schema)
        @test occursin("PRIMARY KEY (ticker, date)", historical_query)
        @test occursin("PRIMARY KEY (perma_ticker, observed_at)", security_query)
        @test occursin("PRIMARY KEY (perma_ticker, metric_date)", metrics_query)
    finally
        close_duckdb(conn)
    end
end

@testset "Security observation upsert is idempotent" begin
    conn = connect_duckdb(":memory:")
    try
        original = DataFrame(
            perma_ticker = ["perm-aapl"],
            observed_at = [DateTime(2026, 7, 19, 12)],
            ticker = ["AAPL"],
            is_active = [true],
            is_adr = Union{Missing,Bool}[false],
            daily_last_updated = Union{Missing,DateTime}[DateTime(2026, 7, 19, 10)],
            exchange = ["NASDAQ"],
            asset_type = ["Stock"],
            price_coverage_start = Union{Missing,Date}[Date(1980, 12, 12)],
            price_coverage_end = Union{Missing,Date}[Date(2026, 7, 19)],
            is_leveraged = Union{Missing,Bool}[missing],
            join_status = ["matched"],
        )
        @test upsert_security_observations(conn, original) == 1

        revised = copy(original)
        revised.exchange .= "NASDAQ GLOBAL SELECT"
        revised.is_leveraged .= false
        revised.daily_last_updated .= DateTime(2026, 7, 19, 11)
        @test upsert_security_observations(conn, revised) == 1

        stored = DBInterface.execute(conn, "SELECT * FROM security_observations") |> DataFrame
        @test nrow(stored) == 1
        @test stored.exchange == ["NASDAQ GLOBAL SELECT"]
        @test stored.is_leveraged == [false]
        @test stored.daily_last_updated == [DateTime(2026, 7, 19, 11)]
    finally
        close_duckdb(conn)
    end
end

@testset "Daily metrics upsert supports nullable and as-of-compatible facts" begin
    conn = connect_duckdb(":memory:")
    try
        rows = DataFrame(
            perma_ticker = fill("perm-aapl", 4),
            metric_date = [
                Date(2024, 1, 31),
                Date(2024, 2, 29),
                Date(2024, 3, 31),
                Date(2025, 1, 1),
            ],
            market_cap = Union{Missing,Float64}[10.0e9, 11.0e9, missing, 12.0e9],
            enterprise_value = Union{Missing,Float64}[9.0e9, missing, missing, 11.0e9],
            pe_ratio = Union{Missing,Float64}[20.0, 21.0, missing, 22.0],
            available_at = Union{Missing,DateTime}[
                DateTime(2024, 2, 1, 12),
                DateTime(2025, 1, 5, 12),
                missing,
                DateTime(2025, 1, 2, 12),
            ],
            fetched_at = fill(DateTime(2026, 7, 19, 12), 4),
            source_revision = Union{Missing,String}["rev-1", "rev-1", missing, "rev-1"],
        )
        @test upsert_fundamental_daily_metrics(conn, rows) == 4

        revised = copy(rows)
        revised.market_cap[1] = 10.5e9
        revised.pe_ratio[1] = 20.5
        revised.source_revision[1] = "rev-2"
        @test upsert_fundamental_daily_metrics(conn, revised) == 4

        stored = DBInterface.execute(
            conn,
            "SELECT * FROM fundamental_daily_metrics ORDER BY metric_date",
        ) |> DataFrame
        @test nrow(stored) == 4
        @test stored.market_cap[1] == 10.5e9
        @test stored.pe_ratio[1] == 20.5
        @test stored.source_revision[1] == "rev-2"
        @test ismissing(stored.market_cap[3])
        @test ismissing(stored.enterprise_value[3])
        @test ismissing(stored.pe_ratio[3])

        as_of = Date(2024, 12, 31)
        observable = DBInterface.execute(
            conn,
            """
            SELECT metric_date
            FROM fundamental_daily_metrics
            WHERE metric_date <= ?
              AND (available_at IS NULL OR available_at <= ?)
            ORDER BY metric_date
            """,
            (as_of, DateTime(2024, 12, 31, 23, 59, 59)),
        ) |> DataFrame
        @test observable.metric_date == [Date(2024, 1, 31), Date(2024, 3, 31)]
    finally
        close_duckdb(conn)
    end
end
