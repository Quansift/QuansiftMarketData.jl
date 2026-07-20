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
using Dates

# Reuse the package's postgres ATTACH mechanism (src/db/postgres.jl:525-556)
import TiingoJulia.DB.Postgres: connection_options_map, postgres_env_vars, with_temporary_env
import TiingoJulia.DB.Core: validate_identifier

const DEFAULT_PG_CONN_STR = "postgresql://postgres@127.0.0.1:5432/tiingo?sslmode=disable"
const DEFAULT_DUCKDB_PATH = "data/tiingo_local.duckdb"
const TABLES_TO_HYDRATE = [
    "historical_data",
    "security_observations",
    "fundamental_daily_metrics",
]
const TABLES_TO_EXPORT = [
    "historical_data",
    "us_tickers_filtered",
    "security_observations",
    "fundamental_daily_metrics",
]

const DOW30_TICKERS = Set([
    "AAPL", "AMGN", "AMZN", "AXP", "BA", "CAT", "CRM", "CSCO", "CVX", "DIS",
    "GS", "HD", "HON", "IBM", "JNJ", "JPM", "KO", "MCD", "MMM", "MRK", "MSFT",
    "NKE", "NVDA", "PG", "SHW", "TRV", "UNH", "V", "VZ", "WMT",
])

function verify_fundamentals_entitlement!(observations::DataFrame, api_key::String; as_of::Date=today())
    candidates = filter(observations) do row
        row.join_status == "matched" && row.is_active &&
            !ismissing(row.asset_type) && lowercase(String(row.asset_type)) == "stock" &&
            !(String(row.ticker) in DOW30_TICKERS)
    end
    nrow(candidates) > 0 || error("no non-DOW matched stock available for entitlement probe")
    probe = first(candidates)
    payload = get_daily_fundamental(
        String(probe.perma_ticker);
        api_key,
        start_date=as_of - Day(7),
        end_date=as_of,
        columns=["marketCap"],
        return_type="original",
    )
    rows = isempty(payload) ? DataFrame() : DataFrame(payload)
    has_market_cap = "marketCap" in names(rows) && any(
        value -> !ismissing(value) && !isnothing(value),
        rows.marketCap,
    )
    has_market_cap || error("Fundamentals entitlement probe returned no marketCap data")
    @info "Fundamentals entitlement probe passed" ticker=String(probe.ticker)
    return nothing
end

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
    hydrate_from_postgres!(conn, pg_conn_str) -> Dict{String,Int}

Copy persisted source tables from PostgreSQL into an empty DuckDB. The ticker
filter is deliberately rebuilt from Tiingo so its `endDate` stays current.
Historical data is required; fundamentals tables are optional during their
first deployment and are exported after the refresh creates them.
"""
function hydrate_from_postgres!(
    conn::DBInterface.Connection,
    pg_conn_str::String,
)::Dict{String,Int}
    attach_postgres_readonly!(conn, pg_conn_str)
    counts = Dict{String,Int}()
    try
        counts["historical_data"] = hydrate_attached_table!(
            conn,
            "historical_data",
            [
                "ticker", "date", "close", "high", "low", "open", "volume",
                "adjClose", "adjHigh", "adjLow", "adjOpen", "adjVolume",
                "divCash", "splitFactor",
            ],
            [
                "ticker", "date", "close", "high", "low", "open", "volume",
                "adjclose", "adjhigh", "adjlow", "adjopen", "adjvolume",
                "divcash", "splitfactor",
            ];
            required = true,
        )
        counts["security_observations"] = hydrate_attached_table!(
            conn,
            "security_observations",
            [
                "perma_ticker", "observed_at", "ticker", "is_active", "is_adr",
                "daily_last_updated", "exchange", "asset_type",
                "price_coverage_start", "price_coverage_end", "is_leveraged",
                "join_status",
            ],
        )
        counts["fundamental_daily_metrics"] = hydrate_attached_table!(
            conn,
            "fundamental_daily_metrics",
            [
                "perma_ticker", "metric_date", "market_cap", "enterprise_value",
                "pe_ratio", "available_at", "fetched_at", "source_revision",
            ],
        )
    finally
        DBInterface.execute(conn, "DETACH pg_src;")
    end

    @info "Hydration verified" counts
    return counts
end

function attached_postgres_table_exists(
    conn::DBInterface.Connection,
    table_name::String,
)::Bool
    safe_name = validate_identifier(table_name)
    result = DBInterface.execute(
        conn,
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_catalog = 'pg_src' AND table_name = ?
        """,
        (safe_name,),
    ) |> DataFrame
    return nrow(result) == 1
end

function hydrate_attached_table!(
    conn::DBInterface.Connection,
    table_name::String,
    target_columns::Vector{String},
    source_columns::Vector{String} = lowercase.(target_columns);
    required::Bool = false,
)::Int
    safe_name = validate_identifier(table_name)
    if !attached_postgres_table_exists(conn, safe_name)
        required && error("Required PostgreSQL table is missing: $safe_name")
        @info "Skipping absent PostgreSQL table during first deployment" table=safe_name
        return 0
    end

    pg_count = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM pg_src.$safe_name") |> DataFrame
    )[1, 1])
    @info "Hydrating table" table=safe_name rows=pg_count
    DBInterface.execute(conn, """
        INSERT INTO $safe_name ($(join(target_columns, ", ")))
        SELECT $(join(source_columns, ", "))
        FROM pg_src.$safe_name
    """)

    duck_count = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM $safe_name") |> DataFrame
    )[1, 1])
    duck_count == pg_count || error(
        "Hydration mismatch: $safe_name DuckDB=$duck_count PG=$pg_count",
    )
    return duck_count
end

"""
    merge_attached_table!(conn, table_name, target_columns, key_columns; source_columns=lowercase.(target_columns)) -> Int

Merge rows from the read-only `pg_src` attachment into an existing local table
without replacing local rows that have the same primary key. This preserves all
PostgreSQL keys when a resumable DuckDB already contains partial backfill data.
"""
function merge_attached_table!(
    conn::DBInterface.Connection,
    table_name::String,
    target_columns::Vector{String},
    key_columns::Vector{String},
    source_columns::Vector{String} = lowercase.(target_columns),
)::Int
    safe_name = validate_identifier(table_name)
    isempty(key_columns) && error("key_columns must not be empty")
    validated_keys = validate_identifier.(key_columns)
    if !attached_postgres_table_exists(conn, safe_name)
        @info "Skipping absent PostgreSQL table during first deployment" table=safe_name
        return 0
    end

    pg_count = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM pg_src.$safe_name") |> DataFrame
    )[1, 1])
    DBInterface.execute(conn, """
        INSERT INTO $safe_name ($(join(target_columns, ", ")))
        SELECT $(join(source_columns, ", "))
        FROM pg_src.$safe_name
        ON CONFLICT ($(join(validated_keys, ", "))) DO NOTHING
    """)

    local_count = Int((
        DBInterface.execute(conn, "SELECT count(*) FROM $safe_name") |> DataFrame
    )[1, 1])
    key_match = join(
        ["local_row.$key = source_row.$key" for key in validated_keys],
        " AND ",
    )
    missing_source_keys = Int((DBInterface.execute(conn, """
        SELECT count(*)
        FROM pg_src.$safe_name AS source_row
        WHERE NOT EXISTS (
            SELECT 1
            FROM $safe_name AS local_row
            WHERE $key_match
        )
    """) |> DataFrame)[1, 1])
    missing_source_keys == 0 || error(
        "PostgreSQL merge lost $missing_source_keys keys from $safe_name",
    )
    @info "Merged PostgreSQL source into resumable DuckDB" table=safe_name pg_rows=pg_count local_rows=local_count
    return local_count
end

function verify_hydrated_row_counts!(
    conn::DBInterface.Connection,
    hydrated_counts::AbstractDict{String,<:Integer},
)::Dict{String,Int}
    post_counts = Dict{String,Int}()
    for table_name in TABLES_TO_HYDRATE
        safe_name = validate_identifier(table_name)
        post_count = Int((
            DBInterface.execute(conn, "SELECT count(*) FROM $safe_name") |> DataFrame
        )[1, 1])
        hydrated_count = Int(get(hydrated_counts, safe_name, 0))
        post_count < hydrated_count && error(
            "ABORT: $safe_name count dropped ($post_count < $hydrated_count)",
        )
        post_counts[safe_name] = post_count
    end
    return post_counts
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
        hydrated_counts = hydrate_from_postgres!(conn, pg_conn_str)

        # Create indexes after bulk insert for better performance
        create_indexes(conn)

        # 3b. Refresh ticker metadata from Tiingo so endDate reflects the current
        #     trading day (rebuilds us_tickers_filtered via CREATE OR REPLACE).
        #     Without this, hydrated stale endDates make every ticker look up to date.
        @info "Refreshing ticker metadata from Tiingo..."
        download_tickers_duckdb(conn)

        do_fundamentals_sync = lowercase(get(ENV, "DO_FUNDAMENTALS_SYNC", "false")) == "true"
        if do_fundamentals_sync
            @info "Fetching current Fundamentals identity metadata"
            meta_payload = get_fundamental_meta(api_key=api_key)
            universe_payload = get_tickers_all(conn)
            observed_at = now(UTC)
            observations = normalize_security_observations(
                meta_payload,
                universe_payload;
                observed_at,
            )
            verify_fundamentals_entitlement!(observations, api_key)
            sync_result = sync_fundamentals!(
                conn,
                meta_payload,
                universe_payload;
                api_key,
                observed_at,
                fetched_at=observed_at,
            )
            isempty(sync_result.failed) || error(
                "Fundamentals sync incomplete for $(length(sync_result.failed)) securities; refusing export",
            )
            @info "Fundamentals sync complete" observations=sync_result.observation_rows metrics=sync_result.metric_rows requested=length(sync_result.requested) skipped=length(sync_result.skipped) statuses=sync_result.status_counts
        end

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
        post_counts = verify_hydrated_row_counts!(conn, hydrated_counts)
        added_counts = Dict(
            table => post_counts[table] - hydrated_counts[table]
            for table in TABLES_TO_HYDRATE
        )
        @info "READY TO EXPORT" counts=post_counts added=added_counts

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

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
