ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using Dates
using DBInterface
using DataFrames
using Logging
using QuansiftMarketData

function parse_int_env(name::String, default::Int)::Int
    raw = strip(get(ENV, name, string(default)))
    try
        return parse(Int, raw)
    catch
        throw(ArgumentError("Invalid integer value for $name: '$raw'"))
    end
end

function _staging_ticker_counts(tickers)::Dict{String,Int}
    counts = Dict{String,Int}()
    for ticker in tickers
        label = String(ticker)
        counts[label] = get(counts, label, 0) + 1
    end
    return counts
end

"""
    validate_staging_historical!(result, historical_row_count; sampled_active_tickers=result.attempted)

Validate a completed staging historical collection before any publication.
Collection is deliberately non-strict so every sampled ticker is attempted;
this gate then rejects partial results, unavailable sampled active tickers, an
empty sample, malformed terminal classifications, or a DuckDB with no persisted
historical rows. A fully unchanged sample is valid when DuckDB already contains
historical rows.
"""
function validate_staging_historical!(
    result::HistoricalCollectionResult,
    historical_row_count::Integer;
    sampled_active_tickers::AbstractVector{<:AbstractString}=result.attempted,
)::HistoricalCollectionResult
    isempty(result.attempted) && error("Staging historical collection attempted zero tickers")
    isempty(result.failed) || error(
        "Staging historical collection failed for $(length(result.failed)) ticker(s): $(join(result.failed, ", "))",
    )

    attempted_counts = _staging_ticker_counts(result.attempted)
    missing_attempts = [
        String(ticker) for ticker in sampled_active_tickers
        if !haskey(attempted_counts, String(ticker))
    ]
    isempty(missing_attempts) || error(
        "Staging historical collection did not attempt sampled active ticker(s): $(join(unique(missing_attempts), ", "))",
    )
    classified_counts = _staging_ticker_counts((
        result.updated...,
        result.unchanged...,
        result.unavailable...,
        result.failed...,
    ))
    attempted_counts == classified_counts || error(
        "Staging historical collection classifications do not partition attempted tickers",
    )

    required = Set(String.(sampled_active_tickers))
    unavailable_active = [ticker for ticker in result.unavailable if ticker in required]
    isempty(unavailable_active) || error(
        "Staging historical collection returned no data for sampled active ticker(s): $(join(unavailable_active, ", "))",
    )
    historical_row_count > 0 || error("Staging DuckDB contains no persisted historical rows")
    return result
end

function publish_after_staging_gate!(
    result::HistoricalCollectionResult,
    historical_row_count::Integer,
    publish::Function;
    sampled_active_tickers::AbstractVector{<:AbstractString}=result.attempted,
)
    validate_staging_historical!(
        result,
        historical_row_count;
        sampled_active_tickers,
    )
    return publish()
end

function staging_smoke_main()
    # Canonical: OHLCV_DUCKDB_PATH; legacy aliases: DUCKDB_PATH, TIINGO_DUCKDB_PATH, TIINGO_DB_PATH
    db_path = abspath(get(ENV, "OHLCV_DUCKDB_PATH",
        get(ENV, "DUCKDB_PATH",
            get(ENV, "TIINGO_DUCKDB_PATH",
                get(ENV, "TIINGO_DB_PATH", joinpath(pwd(), "data", "staging_smoke.duckdb"))))))
    ticker_limit = parse_int_env("TIINGO_SMOKE_TICKER_LIMIT", 25)
    if ticker_limit < 1
        throw(ArgumentError("TIINGO_SMOKE_TICKER_LIMIT must be >= 1"))
    end

    mkpath(dirname(db_path))

    conn = nothing

    try
        @info "Starting staging smoke test" date=string(today()) db_path ticker_limit

        conn = connect_duckdb(db_path)
        optimize_database(conn)
        create_indexes(conn)
        universe = collect_ticker_universe()
        stocks = filter(row -> row.asset_type == "Stock", universe.filtered)
        if nrow(stocks) == 0
            error("The collected ticker universe contains no active stocks")
        end

        smoke_count = min(ticker_limit, nrow(stocks))
        smoke_tickers = stocks[1:smoke_count, :]
        latest_dates = DBInterface.execute(conn, """
            SELECT ticker, MAX(date) AS latest_date
            FROM historical_data
            GROUP BY ticker
        """) |> DataFrame
        collection_result = collect_historical(
            smoke_tickers;
            latest_dates,
            add_missing=true,
            writer=(ticker, frame) -> upsert_stock_data_bulk(conn, frame, ticker),
            continue_on_error=true,
            strict=false,
        )

        historical_rows = DBInterface.execute(conn, "SELECT COUNT(*) AS row_count FROM historical_data") |> DataFrame
        historical_row_count = Int(historical_rows[1, :row_count])
        latest_rows = DBInterface.execute(conn, """
            SELECT ticker, MAX(date) AS latest_date
            FROM historical_data
            GROUP BY ticker
            ORDER BY ticker
            LIMIT 5
        """) |> DataFrame

        @info "Staging smoke sync completed" smoke_count attempted_count=length(collection_result.attempted) updated_count=length(collection_result.updated) unchanged_count=length(collection_result.unchanged) unavailable_count=length(collection_result.unavailable) failed_count=length(collection_result.failed) written_rows=collection_result.written_rows historical_rows=historical_row_count
        @info "Sample latest dates" latest_rows

        sampled_active_tickers = String.(smoke_tickers.ticker)
        publish_after_staging_gate!(
            collection_result,
            historical_row_count,
            () -> begin
                @info "Staging collection gate passed"
            end;
            sampled_active_tickers,
        )
    finally
        if conn !== nothing
            close_duckdb(conn)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    staging_smoke_main()
end
