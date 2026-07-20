using Test
using DataFrames
using DuckDB
using DBInterface
using TiingoJulia

refresh_script = joinpath(@__DIR__, "..", "scripts", "refresh_postgres_via_duckdb.jl")
include(refresh_script)

@testset "Refresh table contract" begin
    @test TABLES_TO_HYDRATE == [
        "historical_data",
        "security_observations",
        "fundamental_daily_metrics",
    ]
    @test TABLES_TO_EXPORT == [
        "historical_data",
        "us_tickers_filtered",
        "security_observations",
        "fundamental_daily_metrics",
    ]

    conn = connect_duckdb(":memory:")
    try
        DBInterface.execute(
            conn,
            "INSERT INTO historical_data (ticker, date) VALUES ('AAPL', '2024-01-31')",
        )
        DBInterface.execute(conn, """
            INSERT INTO security_observations (
                perma_ticker, observed_at, ticker, is_active, join_status
            ) VALUES (
                'perm-aapl', '2026-07-19 12:00:00', 'AAPL', true, 'matched'
            )
        """)
        DBInterface.execute(conn, """
            INSERT INTO fundamental_daily_metrics (
                perma_ticker, metric_date, fetched_at
            ) VALUES (
                'perm-aapl', '2024-01-31', '2026-07-19 12:00:00'
            )
        """)

        hydrated_counts = Dict(table => 1 for table in TABLES_TO_HYDRATE)
        @test verify_hydrated_row_counts!(conn, hydrated_counts) == hydrated_counts

        dropped_counts = copy(hydrated_counts)
        dropped_counts["security_observations"] = 2
        @test_throws ErrorException verify_hydrated_row_counts!(conn, dropped_counts)
    finally
        close_duckdb(conn)
    end
end

@testset "Attached source fundamentals hydrate deterministically" begin
    source_path = tempname() * ".duckdb"
    source = DBInterface.connect(DuckDB.DB, source_path)
    try
        DBInterface.execute(source, """
            CREATE TABLE security_observations (
                perma_ticker VARCHAR,
                observed_at TIMESTAMP,
                ticker VARCHAR,
                is_active BOOLEAN,
                is_adr BOOLEAN,
                daily_last_updated TIMESTAMP,
                exchange VARCHAR,
                asset_type VARCHAR,
                price_coverage_start DATE,
                price_coverage_end DATE,
                is_leveraged BOOLEAN,
                join_status VARCHAR
            )
        """)
        DBInterface.execute(source, """
            INSERT INTO security_observations VALUES (
                'perm-aapl', '2026-07-19 12:00:00', 'AAPL', true, false,
                '2026-07-18 12:00:00', 'NASDAQ', 'Stock', '1980-12-12',
                '2026-07-19', NULL, 'matched'
            )
        """)
        DBInterface.execute(source, """
            CREATE TABLE fundamental_daily_metrics (
                perma_ticker VARCHAR,
                metric_date DATE,
                market_cap DOUBLE,
                enterprise_value DOUBLE,
                pe_ratio DOUBLE,
                available_at TIMESTAMP,
                fetched_at TIMESTAMP,
                source_revision VARCHAR
            )
        """)
        DBInterface.execute(source, """
            INSERT INTO fundamental_daily_metrics VALUES (
                'perm-aapl', '2024-01-31', 1.0e10, NULL, NULL,
                NULL, '2026-07-19 12:00:00', 'rev-1'
            )
        """)
    finally
        DBInterface.close!(source)
    end

    conn = connect_duckdb(":memory:")
    try
        DBInterface.execute(conn, "ATTACH '$source_path' AS pg_src (READ_ONLY)")
        security_count = hydrate_attached_table!(
            conn,
            "security_observations",
            [
                "perma_ticker", "observed_at", "ticker", "is_active", "is_adr",
                "daily_last_updated", "exchange", "asset_type",
                "price_coverage_start", "price_coverage_end", "is_leveraged",
                "join_status",
            ],
        )
        metrics_count = hydrate_attached_table!(
            conn,
            "fundamental_daily_metrics",
            [
                "perma_ticker", "metric_date", "market_cap", "enterprise_value",
                "pe_ratio", "available_at", "fetched_at", "source_revision",
            ],
        )

        @test security_count == 1
        @test metrics_count == 1
        @test (DBInterface.execute(conn, "SELECT count(*) FROM security_observations") |> DataFrame)[1, 1] == 1
        @test (
            DBInterface.execute(conn, "SELECT count(*) FROM fundamental_daily_metrics") |>
            DataFrame
        )[1, 1] == 1
    finally
        try
            DBInterface.execute(conn, "DETACH pg_src")
        catch
        end
        close_duckdb(conn)
        rm(source_path; force=true)
    end
end

@testset "Resumable Fundamentals merge preserves local and PostgreSQL keys" begin
    source_path = tempname() * ".duckdb"
    source = connect_duckdb(source_path)
    try
        DBInterface.execute(source, """
            INSERT INTO security_observations (
                perma_ticker, observed_at, ticker, is_active, exchange, join_status
            ) VALUES
                ('perm-existing', '2026-07-19 12:00:00', 'OLD', true, 'PG', 'matched'),
                ('perm-new', '2026-07-20 12:00:00', 'NEW', true, 'PG', 'matched')
        """)
        DBInterface.execute(source, """
            INSERT INTO fundamental_daily_metrics (
                perma_ticker, metric_date, market_cap, fetched_at
            ) VALUES
                ('perm-existing', '2026-07-18', 10.0, '2026-07-19 12:00:00'),
                ('perm-new', '2026-07-19', 20.0, '2026-07-20 12:00:00')
        """)
    finally
        close_duckdb(source)
    end

    conn = connect_duckdb(":memory:")
    try
        DBInterface.execute(conn, """
            INSERT INTO security_observations (
                perma_ticker, observed_at, ticker, is_active, exchange, join_status
            ) VALUES (
                'perm-existing', '2026-07-19 12:00:00', 'LOCAL', true, 'LOCAL', 'matched'
            )
        """)
        DBInterface.execute(conn, """
            INSERT INTO fundamental_daily_metrics (
                perma_ticker, metric_date, market_cap, fetched_at
            ) VALUES (
                'perm-existing', '2026-07-18', 99.0, '2026-07-20 12:00:00'
            )
        """)
        DBInterface.execute(conn, "ATTACH '$source_path' AS pg_src (READ_ONLY)")

        security_count = merge_attached_table!(
            conn,
            "security_observations",
            [
                "perma_ticker", "observed_at", "ticker", "is_active", "is_adr",
                "daily_last_updated", "exchange", "asset_type",
                "price_coverage_start", "price_coverage_end", "is_leveraged",
                "join_status",
            ],
            ["perma_ticker", "observed_at"],
        )
        metrics_count = merge_attached_table!(
            conn,
            "fundamental_daily_metrics",
            [
                "perma_ticker", "metric_date", "market_cap", "enterprise_value",
                "pe_ratio", "available_at", "fetched_at", "source_revision",
            ],
            ["perma_ticker", "metric_date"],
        )

        @test security_count == 2
        @test metrics_count == 2
        securities = DBInterface.execute(
            conn,
            "SELECT ticker, exchange FROM security_observations ORDER BY perma_ticker",
        ) |> DataFrame
        @test securities.ticker == ["LOCAL", "NEW"]
        @test securities.exchange == ["LOCAL", "PG"]
        metrics = DBInterface.execute(
            conn,
            "SELECT market_cap FROM fundamental_daily_metrics ORDER BY perma_ticker",
        ) |> DataFrame
        @test metrics.market_cap == [99.0, 20.0]
    finally
        try
            DBInterface.execute(conn, "DETACH pg_src")
        catch
        end
        close_duckdb(conn)
        rm(source_path; force=true)
    end
end
