#!/usr/bin/env julia

"""
Resumable Tiingo Fundamentals market-cap backfill.

Required:
  FUNDAMENTALS_DUCKDB_PATH=/absolute/path/to/fundamentals-backfill.duckdb

Optional:
  OHLCV_PG_CONNECTION=postgresql://...
  FUNDAMENTALS_HISTORY_YEARS=3
  FUNDAMENTALS_EXPORT=true   # default false

The local DuckDB is intentionally retained after partial failures. PostgreSQL
export is limited to security_observations and fundamental_daily_metrics and is
allowed only after every eligible request succeeds.
"""

ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using TiingoJulia
using Dates
using DataFrames
using DBInterface
using Logging

include(joinpath(@__DIR__, "refresh_postgres_via_duckdb.jl"))

function required_backfill_path()::String
    raw = strip(get(ENV, "FUNDAMENTALS_DUCKDB_PATH", ""))
    isempty(raw) && error("FUNDAMENTALS_DUCKDB_PATH must be set")
    isabspath(raw) || error("FUNDAMENTALS_DUCKDB_PATH must be absolute")
    mkpath(dirname(raw))
    return normpath(raw)
end

function hydrate_existing_fundamentals!(conn, pg_conn_str::String)::Nothing
    attach_postgres_readonly!(conn, pg_conn_str)
    try
        merge_attached_table!(
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
        merge_attached_table!(
            conn,
            "fundamental_daily_metrics",
            [
                "perma_ticker", "metric_date", "market_cap", "enterprise_value",
                "pe_ratio", "available_at", "fetched_at", "source_revision",
            ],
            ["perma_ticker", "metric_date"],
        )
    finally
        DBInterface.execute(conn, "DETACH pg_src")
    end
    return nothing
end

function validate_backfill!(conn, as_of::Date)::NamedTuple
    duplicate_metrics = Int((DBInterface.execute(conn, """
        SELECT COUNT(*) FROM (
            SELECT perma_ticker, metric_date
            FROM fundamental_daily_metrics
            GROUP BY perma_ticker, metric_date
            HAVING COUNT(*) > 1
        ) duplicates
    """) |> DataFrame)[1, 1])
    future_metrics = Int((DBInterface.execute(
        conn,
        "SELECT COUNT(*) FROM fundamental_daily_metrics WHERE metric_date > ?",
        Any[as_of],
    ) |> DataFrame)[1, 1])
    duplicate_metrics == 0 || error("duplicate fundamental metric keys detected")
    future_metrics == 0 || error("future-dated fundamental metrics detected")

    observations = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM security_observations") |> DataFrame
    )[1, 1])
    metrics = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM fundamental_daily_metrics") |> DataFrame
    )[1, 1])
    return (; observations, metrics)
end

function main()
    api_key = get_api_key()
    duckdb_path = required_backfill_path()
    pg_conn_str = get(ENV, "OHLCV_PG_CONNECTION", DEFAULT_PG_CONN_STR)
    history_years = parse(Int, get(ENV, "FUNDAMENTALS_HISTORY_YEARS", "3"))
    history_years > 0 || error("FUNDAMENTALS_HISTORY_YEARS must be positive")
    do_export = lowercase(get(ENV, "FUNDAMENTALS_EXPORT", "false")) == "true"
    as_of = today()
    observed_at = now(UTC)

    conn = connect_duckdb(duckdb_path)
    try
        create_tables(conn)
        hydrate_existing_fundamentals!(conn, pg_conn_str)
        download_tickers_duckdb(conn)
        universe_payload = get_tickers_all(conn)
        meta_payload = get_fundamental_meta(api_key=api_key)
        observations = normalize_security_observations(
            meta_payload,
            universe_payload;
            observed_at,
        )
        verify_fundamentals_entitlement!(observations, api_key; as_of)

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key,
            as_of,
            history_years,
            observed_at,
            fetched_at=observed_at,
        )
        if !isempty(result.failed)
            println("FUNDAMENTALS_BACKFILL_PARTIAL failed=$(length(result.failed)) completed=$(length(result.requested)) resume_path=$duckdb_path")
            exit(2)
        end

        counts = validate_backfill!(conn, as_of)
        if do_export
            pg_conn = connect_postgres(pg_conn_str)
            try
                export_to_postgres(
                    conn,
                    pg_conn,
                    ["security_observations", "fundamental_daily_metrics"];
                    pg_connection_string=pg_conn_str,
                )
            finally
                close_postgres(pg_conn)
            end
        end
        println("FUNDAMENTALS_BACKFILL_OK requested=$(length(result.requested)) skipped=$(length(result.skipped)) observations=$(counts.observations) metrics=$(counts.metrics) exported=$do_export")
    finally
        close_duckdb(conn)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
