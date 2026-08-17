#!/usr/bin/env julia
#
# Validate a PostgreSQL-backed historical snapshot through a local DuckDB refresh.
# Production publication belongs to quansift_scheduler.
#
# Environment variables:
#   OHLCV_DUCKDB_PATH      DuckDB file path       (default: data/tiingo_local.duckdb)
#   OHLCV_PG_CONNECTION     PostgreSQL conn string  (default: see below)
#   TIINGO_API_KEY          Tiingo API key          (or via .env)
#   DO_EXPORT               unsupported in v4; must remain "false"

ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using QuansiftMarketData
using DBInterface
using DuckDB
using DataFrames
using Logging
using Dates

# Reuse the package's PostgreSQL extension and ATTACH mechanisms.
import QuansiftMarketData.DB.Postgres: with_attached_postgres
import QuansiftMarketData.DB.Core: validate_identifier

const DEFAULT_PG_CONN_STR = "postgresql://postgres@127.0.0.1:5432/tiingo?sslmode=disable"
const DEFAULT_DUCKDB_PATH = "data/tiingo_local.duckdb"
const TABLES_TO_HYDRATE = [
    "historical_data",
    "security_observations",
    "fundamental_daily_metrics",
]
const DOW30_TICKERS = Set([
    "AAPL", "AMGN", "AMZN", "AXP", "BA", "CAT", "CRM", "CSCO", "CVX", "DIS",
    "GS", "HD", "HON", "IBM", "JNJ", "JPM", "KO", "MCD", "MMM", "MRK", "MSFT",
    "NKE", "NVDA", "PG", "SHW", "TRV", "UNH", "V", "VZ", "WMT",
])

function verify_fundamentals_entitlement!(
    observations::DataFrame,
    api_key::String;
    as_of::Date=today(),
    daily_fetcher::Function=get_daily_fundamental,
    max_candidates::Int=25,
)
    max_candidates > 0 || throw(ArgumentError("max_candidates must be positive"))
    candidates = filter(observations) do row
        row.join_status == "matched" && row.is_active &&
            !ismissing(row.asset_type) && lowercase(String(row.asset_type)) == "stock" &&
            !(String(row.ticker) in DOW30_TICKERS)
    end
    nrow(candidates) > 0 || error("no non-DOW matched stock available for entitlement probe")
    if :daily_last_updated in propertynames(candidates)
        sort!(
            candidates,
            :daily_last_updated;
            by=value -> ismissing(value) ? DateTime(1) : DateTime(value),
            rev=true,
        )
    end

    attempted = 0
    failures = 0
    for probe in eachrow(first(candidates, min(max_candidates, nrow(candidates))))
        attempted += 1
        try
            payload = daily_fetcher(
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
            has_market_cap || continue
            @info "Fundamentals entitlement probe passed" ticker=String(probe.ticker)
            return nothing
        catch probe_error
            probe_error isa InterruptException && rethrow()
            failures += 1
            # At @debug these were invisible, so an outage or an expired key
            # reported as "no marketCap data" — an entitlement problem — and
            # pointed the diagnosis at the Tiingo account rather than the
            # network. Only the first few are logged in full; the rest would
            # be the same stacktrace repeated.
            if failures <= 3
                @warn "Fundamentals entitlement candidate failed" ticker=String(probe.ticker) exception=(probe_error, catch_backtrace())
            else
                @warn "Fundamentals entitlement candidate failed" ticker=String(probe.ticker) error=sprint(showerror, probe_error)
            end
        end
    end
    error(
        "Fundamentals entitlement probe returned no marketCap data across " *
        "$attempted candidates ($failures errored, " *
        "$(attempted - failures) returned no marketCap)",
    )
end

"""
    with_pg_src(f, conn, pg_conn_str)

Attach PostgreSQL as the read-only `pg_src` source, run `f()`, and detach.

Delegates to `with_attached_postgres` so the libpq environment stays set for
the attachment's whole lifetime. An earlier version restored it immediately
after `ATTACH`, which left the scanner's later pooled connections resolving
against ambient defaults; hydration then failed part-way through, naming a
socket path and an OS-username database that appeared in no connection string.
"""
function with_pg_src(f::Function, conn, pg_conn_str::String)
    return with_attached_postgres(
        f,
        conn,
        pg_conn_str;
        alias="pg_src",
        read_only=true,
    )
end

"""
    hydrate_from_postgres!(conn, pg_conn_str) -> Dict{String,Int}

Copy persisted source tables from PostgreSQL into an empty DuckDB. Historical
data is required; fundamentals tables are optional during their first
deployment. Publication after validation belongs to quansift_scheduler.
"""
function hydrate_from_postgres!(
    conn::DBInterface.Connection,
    pg_conn_str::String,
)::Dict{String,Int}
    counts = Dict{String,Int}()
    with_pg_src(conn, pg_conn_str) do
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
        WHERE table_catalog = 'pg_src'
          AND table_schema = 'public'
          AND table_name = ?
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
        DBInterface.execute(conn, "SELECT count(*) FROM pg_src.public.$safe_name") |> DataFrame
    )[1, 1])
    @info "Hydrating table" table=safe_name rows=pg_count
    DBInterface.execute(conn, """
        INSERT INTO $safe_name ($(join(target_columns, ", ")))
        SELECT $(join(source_columns, ", "))
        FROM pg_src.public.$safe_name
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
        DBInterface.execute(conn, "SELECT count(*) FROM pg_src.public.$safe_name") |> DataFrame
    )[1, 1])
    DBInterface.execute(conn, """
        INSERT INTO $safe_name ($(join(target_columns, ", ")))
        SELECT $(join(source_columns, ", "))
        FROM pg_src.public.$safe_name
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
        FROM pg_src.public.$safe_name AS source_row
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
    do_export && error(
        "DO_EXPORT is unsupported in QuansiftMarketData v4; publish through quansift_scheduler",
    )
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

        # 3b. Collect current ticker metadata without coupling collection to a sink.
        @info "Refreshing ticker metadata from Tiingo..."
        universe = collect_ticker_universe()

        do_fundamentals_sync = lowercase(get(ENV, "DO_FUNDAMENTALS_SYNC", "false")) == "true"
        if do_fundamentals_sync
            @info "Fetching current Fundamentals identity metadata"
            meta_payload = get_fundamental_meta(api_key=api_key)
            universe_payload = universe.filtered
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
                "Fundamentals sync incomplete for $(length(sync_result.failed)) securities",
            )
            @info "Fundamentals sync complete" observations=sync_result.observation_rows metrics=sync_result.metric_rows requested=length(sync_result.requested) skipped=length(sync_result.skipped) unchanged=length(sync_result.unchanged) unavailable=length(sync_result.unavailable) statuses=sync_result.status_counts
        end

        # 4. Incremental update from Tiingo API
        tickers = universe.filtered
        # Optional cap for a cheap end-to-end validation run (0 = no limit)
        ticker_limit = parse(Int, get(ENV, "REFRESH_TICKER_LIMIT", "0"))
        if ticker_limit > 0 && nrow(tickers) > ticker_limit
            tickers = tickers[1:ticker_limit, :]
            @info "Ticker list capped for validation" limit=ticker_limit
        end
        @info "Loaded tickers" count=nrow(tickers)
        latest_dates = DBInterface.execute(conn, """
            SELECT ticker, MAX(date) AS latest_date
            FROM historical_data
            GROUP BY ticker
        """) |> DataFrame
        collection = collect_historical(
            tickers,
            api_key;
            latest_dates,
            add_missing=false,
            writer=(ticker, frame) -> upsert_stock_data_bulk(conn, frame, ticker),
            continue_on_error=true,
            strict=false,
        )
        failed_tickers = collection.failed
        @info "Incremental update done" updated=length(collection.updated) skipped=length(collection.unchanged) unavailable=length(collection.unavailable) failed=length(failed_tickers)

        # 5. Safety gate: never report a shrinking snapshot as ready
        post_counts = verify_hydrated_row_counts!(conn, hydrated_counts)

        # The count gate above only catches a SHRINKING table. A widespread API
        # failure leaves counts intact and could make stale data look ready,
        # because every ticker that failed simply added no rows.
        #
        # `missing_t` is deliberately not what is measured: with
        # add_missing=false it also holds every ticker intentionally skipped for
        # not being in historical_data yet, which is normal operation.
        max_export_failures = parse(
            Int, get(ENV, "OHLCV_MAX_EXPORT_FAILURES", "100"),
        )
        max_export_failures >= 0 ||
            error("OHLCV_MAX_EXPORT_FAILURES must be non-negative")
        if length(failed_tickers) > max_export_failures
            error(
                "Validation failed: $(length(failed_tickers)) ticker(s) failed to " *
                "update, over the OHLCV_MAX_EXPORT_FAILURES limit of " *
                "$max_export_failures. The existing PostgreSQL snapshot is left " *
                "untouched. First failures: " *
                join(first(failed_tickers, 10), ", "),
            )
        end
        added_counts = Dict(
            table => post_counts[table] - hydrated_counts[table]
            for table in TABLES_TO_HYDRATE
        )
        @info "READY TO EXPORT" counts=post_counts added=added_counts

        @info "Validation complete; publication is intentionally not performed"
    finally
        close_duckdb(conn)
    end
    @info "Done."
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
