#!/usr/bin/env julia

"""
Resumable Tiingo Fundamentals market-cap backfill.

Required:
  FUNDAMENTALS_DUCKDB_PATH=/absolute/path/to/fundamentals-backfill.duckdb

Optional:
  OHLCV_PG_CONNECTION=postgresql://...
  FUNDAMENTALS_HISTORY_YEARS=3
  FUNDAMENTALS_AS_OF=YYYY-MM-DD
  FUNDAMENTALS_EXPORT=true   # default false

The local DuckDB is intentionally retained after partial failures. PostgreSQL
export is limited to security_observations and fundamental_daily_metrics and is
allowed only after every eligible request succeeds.
"""

ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using QuansiftMarketData
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

function configured_backfill_as_of()::Date
    raw = strip(get(ENV, "FUNDAMENTALS_AS_OF", ""))
    isempty(raw) && return today()
    try
        return Date(raw, dateformat"yyyy-mm-dd")
    catch
        error("FUNDAMENTALS_AS_OF must use YYYY-MM-DD")
    end
end

function hydrate_existing_fundamentals!(conn, pg_conn_str::String)::Nothing
    with_pg_src(conn, pg_conn_str) do
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
    as_of = configured_backfill_as_of()
    observed_at = now(UTC)

    conn = connect_duckdb(duckdb_path)
    try
        # connect_duckdb only opens the file — configure_database is a no-op, so
        # without this call DuckDB runs untuned: no memory_limit sized to the
        # host, no thread caps, and crucially no temp_directory, which is what
        # lets it spill to disk instead of dying. On 2026-08-13 this backfill
        # OOM'd twice on a 3.8 GiB droplet ("Out of Memory Error: failed to
        # allocate data of size 4.0 KiB (1.5 GiB/1.5 GiB used)"), leaving market
        # caps 19 days stale. The OHLCV pipeline has always called this; the
        # fundamentals path never did.
        optimize_database(conn)
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
        failed_count = length(result.failed)

        # Tolerate a small number of per-security failures. The export REPLACES the
        # PostgreSQL tables (staging + atomic swap), so a widespread failure — an API
        # outage — must NOT export: it would clobber good market caps with a nearly
        # empty snapshot. But a handful of persistently-bad securities (delisted, no
        # data, one-off API quirks) must not block caps for the other thousands, which
        # is exactly what the old all-or-nothing gate did (one failure in ~5,300 left
        # security_observations uncreated and every cap-dependent screener empty).
        # Above the threshold we skip the export and keep yesterday's snapshot intact.
        max_export_failures = parse(Int, get(ENV, "FUNDAMENTALS_MAX_EXPORT_FAILURES", "100"))
        within_tolerance = failed_count <= max_export_failures

        counts = validate_backfill!(conn, as_of)
        exported = false
        if do_export && within_tolerance
            pg_conn = connect_postgres(pg_conn_str)
            try
                export_to_postgres(
                    conn,
                    pg_conn,
                    ["security_observations", "fundamental_daily_metrics"];
                    pg_connection_string=pg_conn_str,
                )
                exported = true
            finally
                close_postgres(pg_conn)
            end
        end

        if failed_count > 0
            # exit 2 = partial but the good rows WERE exported (alert, not data loss);
            # exit 3 = failures exceeded tolerance so the export was withheld to protect
            # the existing snapshot (more urgent). Both keep the DuckDB for watermark
            # resume on the next run.
            println("FUNDAMENTALS_BACKFILL_PARTIAL failed=$(failed_count) completed=$(length(result.requested)) unchanged=$(length(result.unchanged)) unavailable=$(length(result.unavailable)) exported=$(exported) resume_path=$duckdb_path")
            exit(within_tolerance ? 2 : 3)
        end
        println("FUNDAMENTALS_BACKFILL_OK requested=$(length(result.requested)) skipped=$(length(result.skipped)) unchanged=$(length(result.unchanged)) unavailable=$(length(result.unavailable)) observations=$(counts.observations) metrics=$(counts.metrics) exported=$exported")
    finally
        close_duckdb(conn)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
