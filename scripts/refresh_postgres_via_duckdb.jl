#!/usr/bin/env julia
#
# Refresh local PostgreSQL historical_data table via DuckDB incremental update.
# Flow: Hydrate DuckDB from PG -> incremental API fetch -> safety gate -> export.
#
# Environment variables:
#   OHLCV_DUCKDB_PATH      DuckDB file path       (default: data/tiingo_local.duckdb)
#   OHLCV_PG_CONNECTION     PostgreSQL conn string  (default: see below)
#   TIINGO_API_KEY          Tiingo API key          (or via .env)
#   DO_EXPORT               "true" to export back   (default: "false")

ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using TiingoJulia
using DBInterface
using DuckDB
using DataFrames
using Logging

# Reuse the package's postgres ATTACH mechanism (src/db/postgres.jl:525-556)
import TiingoJulia.DB.Postgres: connection_options_map, postgres_env_vars, with_temporary_env

const DEFAULT_PG_CONN_STR = "postgresql://postgres@127.0.0.1:5432/tiingo?sslmode=disable"
const DEFAULT_DUCKDB_PATH = "data/tiingo_local.duckdb"
const TABLES_TO_EXPORT = ["historical_data", "us_tickers_filtered"]

"""
    attach_postgres_readonly!(conn, pg_conn_str) -> Nothing

Attach PostgreSQL as a read-only source in DuckDB using the same env-var
mechanism as `setup_postgres_connection` (src/db/postgres.jl:525-556).
"""
function attach_postgres_readonly!(conn::DBInterface.Connection, pg_conn_str::String)::Nothing
    options = connection_options_map(pg_conn_str)
    env_vars = postgres_env_vars(options)
    with_temporary_env(env_vars) do
        DBInterface.execute(conn, "INSTALL postgres;")
        DBInterface.execute(conn, "LOAD postgres;")
        DBInterface.execute(conn, "ATTACH '' AS pg_src (TYPE POSTGRES, READ_ONLY);")
    end
    @info "Attached PostgreSQL as pg_src (read-only)"
    return nothing
end

"""
    hydrate_from_postgres!(conn, pg_conn_str) -> Int

Copy historical_data from PG into an empty DuckDB. This seeds the per-ticker
latest dates that drive incremental fetching. `us_tickers_filtered` is NOT
hydrated here: it is rebuilt fresh from Tiingo via `download_tickers_duckdb`
so that each ticker's `endDate` reflects the current trading day (a stale
endDate makes `update_historical` treat every ticker as up to date).
Returns the historical_data row count. Errors on count mismatch.
"""
function hydrate_from_postgres!(conn::DBInterface.Connection, pg_conn_str::String)::Int
    attach_postgres_readonly!(conn, pg_conn_str)

    # Read PG count before hydration
    pg_hist = (DBInterface.execute(conn, "SELECT count(*) FROM pg_src.historical_data") |> DataFrame)[1, 1]
    @info "PostgreSQL source count" historical_data=pg_hist

    # Explicit column mapping: DuckDB camelCase <- Postgres lowercase (same positional order)
    @info "Hydrating historical_data ($pg_hist rows)..."
    DBInterface.execute(conn, """
        INSERT INTO historical_data (ticker, date, close, high, low, open, volume,
            adjClose, adjHigh, adjLow, adjOpen, adjVolume, divCash, splitFactor)
        SELECT ticker, date, close, high, low, open, volume,
            adjclose, adjhigh, adjlow, adjopen, adjvolume, divcash, splitfactor
        FROM pg_src.historical_data
    """)

    DBInterface.execute(conn, "DETACH pg_src;")

    # Verify DuckDB count matches PG
    duck_hist = (DBInterface.execute(conn, "SELECT count(*) FROM historical_data") |> DataFrame)[1, 1]
    @info "DuckDB post-hydration" historical_data=duck_hist

    duck_hist != pg_hist && error("Hydration mismatch: historical_data DuckDB=$duck_hist PG=$pg_hist")
    @info "Hydration verified"
    return duck_hist
end

function main()
    # 1. Load configuration
    api_key = get_api_key()
    duckdb_path = get(ENV, "OHLCV_DUCKDB_PATH", DEFAULT_DUCKDB_PATH)
    pg_conn_str = get(ENV, "OHLCV_PG_CONNECTION", DEFAULT_PG_CONN_STR)
    do_export = lowercase(get(ENV, "DO_EXPORT", "false")) == "true"
    @info "Config" duckdb_path do_export

    # The DuckDB is a throwaway working file: Postgres is the source of record
    # and we re-hydrate from it every run. A leftover file would make the
    # hydration INSERT double up (UNIQUE conflict), so start fresh each time.
    if isfile(duckdb_path)
        @warn "Removing stale working DuckDB (rebuilt fresh from Postgres each run)" duckdb_path
        rm(duckdb_path; force=true)
        rm(duckdb_path * ".wal"; force=true)
    end

    # 2. Connect DuckDB and create the schema (connect_duckdb only connects;
    #    table creation lives in Schema.create_tables -- see src/db/core.jl:148)
    conn = connect_duckdb(duckdb_path)
    try
        create_tables(conn)

        # 3. Hydrate from PostgreSQL into DuckDB
        hydrated_count = hydrate_from_postgres!(conn, pg_conn_str)

        # Create indexes after bulk insert for better performance
        create_indexes(conn)

        # 3b. Refresh ticker metadata from Tiingo so endDate reflects the current
        #     trading day (rebuilds us_tickers_filtered via CREATE OR REPLACE).
        #     Without this, hydrated stale endDates make every ticker look up to date.
        @info "Refreshing ticker metadata from Tiingo..."
        download_tickers_duckdb(conn)

        # 4. Incremental update from Tiingo API
        tickers = get_tickers_all(conn)
        # Optional cap for a cheap end-to-end validation run (0 = no limit)
        ticker_limit = parse(Int, get(ENV, "REFRESH_TICKER_LIMIT", "0"))
        if ticker_limit > 0 && nrow(tickers) > ticker_limit
            tickers = tickers[1:ticker_limit, :]
            @info "Ticker list capped for validation" limit=ticker_limit
        end
        @info "Loaded tickers" count=nrow(tickers)
        updated, missing_t = update_historical(conn, tickers, api_key;
            use_parallel=true, batch_size=100, max_concurrent=10, add_missing=false)
        @info "Incremental update done" updated=length(updated) skipped=length(missing_t)

        # 5. Safety gate: never export a subset
        post_count = (DBInterface.execute(conn, "SELECT count(*) FROM historical_data") |> DataFrame)[1, 1]
        post_count < hydrated_count && error("ABORT: count dropped ($post_count < $hydrated_count)")
        @info "READY TO EXPORT" count=post_count added=(post_count - hydrated_count)

        if !do_export
            @info "Export skipped (DO_EXPORT != \"true\"). Re-run with DO_EXPORT=true to push to PostgreSQL."
            return
        end

        # 6. Export to PostgreSQL (drop+rename for tables without FK dependents)
        @info "Exporting to PostgreSQL..."
        pg_conn = connect_postgres(pg_conn_str)
        try
            export_to_postgres(conn, pg_conn, TABLES_TO_EXPORT; pg_connection_string=pg_conn_str)
            @info "Export complete"
        finally
            close_postgres(pg_conn)
        end
    finally
        close_duckdb(conn)
    end
    @info "Done."
end

main()
