ENV["TIINGO_LOGGER"] = get(ENV, "TIINGO_LOGGER", "console")

using Dates
using DBInterface
using DataFrames
using Logging
using TiingoJulia

function parse_bool_env(name::String, default::Bool)::Bool
    raw = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    if raw in ("1", "true", "yes", "on")
        return true
    elseif raw in ("0", "false", "no", "off")
        return false
    end

    throw(ArgumentError("Invalid boolean value for $name: '$raw'"))
end

function parse_int_env(name::String, default::Int)::Int
    raw = strip(get(ENV, name, string(default)))
    try
        return parse(Int, raw)
    catch
        throw(ArgumentError("Invalid integer value for $name: '$raw'"))
    end
end

function main()
    db_path = abspath(get(ENV, "TIINGO_DB_PATH", joinpath(pwd(), "data", "staging_smoke.duckdb")))
    ticker_limit = parse_int_env("TIINGO_SMOKE_TICKER_LIMIT", 25)
    batch_size = parse_int_env("TIINGO_SMOKE_BATCH_SIZE", min(ticker_limit, 25))
    max_concurrent = parse_int_env("TIINGO_SMOKE_MAX_CONCURRENT", 5)
    use_parallel = parse_bool_env("TIINGO_SMOKE_USE_PARALLEL", false)
    export_postgres = parse_bool_env("TIINGO_SMOKE_EXPORT_POSTGRES", false)
    pg_connection_string = String(strip(get(ENV, "TIINGO_PG_CONNECTION", "")))

    if ticker_limit < 1
        throw(ArgumentError("TIINGO_SMOKE_TICKER_LIMIT must be >= 1"))
    end
    if batch_size < 1
        throw(ArgumentError("TIINGO_SMOKE_BATCH_SIZE must be >= 1"))
    end
    if max_concurrent < 1
        throw(ArgumentError("TIINGO_SMOKE_MAX_CONCURRENT must be >= 1"))
    end
    if export_postgres && isempty(pg_connection_string)
        throw(ArgumentError("TIINGO_PG_CONNECTION is required when TIINGO_SMOKE_EXPORT_POSTGRES=true"))
    end

    mkpath(dirname(db_path))

    conn = nothing
    pg_conn = nothing

    try
        @info "Starting staging smoke test" date=string(today()) db_path ticker_limit batch_size max_concurrent use_parallel export_postgres

        conn = connect_duckdb(db_path)
        optimize_database(conn)
        create_indexes(conn)
        download_tickers_duckdb(conn)

        stocks = get_tickers_stock(conn)
        if nrow(stocks) == 0
            error("No stock tickers were loaded into us_tickers_filtered")
        end

        smoke_count = min(ticker_limit, nrow(stocks))
        smoke_tickers = stocks[1:smoke_count, :]
        updated_tickers, missing_tickers = update_historical(
            conn,
            smoke_tickers;
            use_parallel=use_parallel,
            batch_size=min(batch_size, smoke_count),
            max_concurrent=max_concurrent,
            add_missing=true,
        )

        historical_rows = DBInterface.execute(conn, "SELECT COUNT(*) AS row_count FROM historical_data") |> DataFrame
        latest_rows = DBInterface.execute(conn, """
            SELECT ticker, MAX(date) AS latest_date
            FROM historical_data
            GROUP BY ticker
            ORDER BY ticker
            LIMIT 5
        """) |> DataFrame

        @info "Staging smoke sync completed" smoke_count updated_count=length(updated_tickers) missing_count=length(missing_tickers) historical_rows=historical_rows[1, :row_count]
        @info "Sample latest dates" latest_rows

        if export_postgres
            pg_conn = connect_postgres(pg_connection_string)
            export_to_postgres(
                conn,
                pg_conn,
                ["historical_data", "us_tickers_filtered"];
                pg_connection_string=pg_connection_string,
            )
            @info "Staging PostgreSQL export completed" tables=["historical_data", "us_tickers_filtered"]
        else
            @info "Skipping PostgreSQL export" reason="TIINGO_SMOKE_EXPORT_POSTGRES=false"
        end
    finally
        if pg_conn !== nothing
            close_postgres(pg_conn)
        end
        if conn !== nothing
            close_duckdb(conn)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
