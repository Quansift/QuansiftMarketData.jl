module QuansiftMarketData

using CSV
using DataFrames
using Dates
using DBInterface
using DotEnv
using DuckDB
using HTTP
using JSON3
using LibPQ
using Tables
using ZipFile
using Logging
using LoggingExtras
using TimeSeries

# Logger configuration
const NULL_LOGGER = LoggingExtras.NullLogger()

build_console_logger() = ConsoleLogger(stderr, Logging.Info)

function __init__()
    logger_type = lowercase(get(ENV, "TIINGO_LOGGER", "console"))
    if logger_type == "console"
        global_logger(build_console_logger())
    elseif logger_type == "tee"
        global_logger(LoggingExtras.TeeLogger(NULL_LOGGER, build_console_logger()))
    elseif logger_type == "file"
        DB.setup_logging()
    elseif logger_type == "tee-file"
        DB.setup_logging(tee_console=true)
    else
        global_logger(NULL_LOGGER)
    end
end

# Include configuration module first
include("config.jl")
using .Config

# Include database modules
module DB
    using DataFrames
    using DBInterface
    using DuckDB
    using LibPQ
    using Logging
    using Base: @kwdef

    # Import parent module's Config
    using ..Config

    # Include all DB submodules
    include("db/core.jl")
    using .Core

    include("db/schema.jl")
    using .Schema

    include("db/operations.jl")
    using .Operations

    include("db/postgres.jl")
    using .Postgres

    include("db/parquet.jl")
    using .Parquet

    # Re-export core database functionality
    export connect_duckdb, close_duckdb, optimize_database
    export create_tables, create_indexes, list_tables
    export upsert_stock_data, upsert_stock_data_bulk
    export get_tickers_all, get_tickers_etf, get_tickers_stock
    export connect_postgres, close_postgres, export_to_postgres
    export create_or_replace_table
    export write_parquet, ParquetWriteResult


    # Custom error types and aliases are imported from submodules

    # Global reference to log file handle for cleanup
    const TIINGO_LOG_FILE_HANDLE = Ref{Union{IO,Nothing}}(nothing)
    const LOG_FILE = Config.DB.LOG_FILE

    # Set up logging to file
    function setup_logging(; tee_console::Bool=false)
        io = open(LOG_FILE, "a")
        TIINGO_LOG_FILE_HANDLE[] = io
        logger = SimpleLogger(io)
        if tee_console
            logger = LoggingExtras.TeeLogger(logger, QuansiftMarketData.build_console_logger())
        end
        global_logger(logger)
    end

    # Cleanup logging resources
    function cleanup_logging()
        if TIINGO_LOG_FILE_HANDLE[] !== nothing
            try
                close(TIINGO_LOG_FILE_HANDLE[])
                TIINGO_LOG_FILE_HANDLE[] = nothing
                @info "QuansiftMarketData log file handle closed successfully"
            catch e
                @warn "Error closing QuansiftMarketData log file" exception=e
            end
        end
    end

    # Register cleanup to run on exit
    atexit(cleanup_logging)

    # Wrapper functions that call Schema.create_tables with proper connection
    function initialize_owned_duckdb(
        path::String;
        connector::Function=Core.connect_duckdb,
        initializer::Function=Schema.create_tables,
        closer::Function=Core.close_duckdb,
    )
        conn = connector(path)
        try
            initializer(conn)
            return conn
        catch
            try
                closer(conn)
            catch close_error
                @warn "Failed to close DuckDB after initialization error" exception=(close_error, catch_backtrace())
            end
            rethrow()
        end
    end

    connect_duckdb(path::String = Config.DB.DEFAULT_DUCKDB_PATH) =
        initialize_owned_duckdb(path)

    # Re-export all functions from submodules
    for name in names(Core, all=false)
        name == :Core && continue
        @eval export $name
    end
    for name in names(Schema, all=false)
        name == :Schema && continue
        @eval export $name
    end
    for name in names(Operations, all=false)
        name == :Operations && continue
        @eval export $name
    end
    for name in names(Postgres, all=false)
        name == :Postgres && continue
        @eval export $name
    end
    for name in names(Parquet, all=false)
        name == :Parquet && continue
        @eval export $name
    end
end

using .DB

# Include API module
module API
    using HTTP
    using JSON3
    using DataFrames
    using TimeSeries
    using Dates
    using DotEnv
    using Random

    using ..Config

    include("api.jl")

    export get_api_key, get_ticker_data, fetch_api_data, load_env_file
end

using .API

# Include typed collection results after API redaction helpers are available
include("results.jl")

# Include Sync module for data synchronization
module Sync
    using CSV
    using Dates
    using DataFrames
    using DBInterface
    using DuckDB
    using Logging
    using ZipFile
    using HTTP

    using ..Config
    using ..DB
    using ..API

    include("sync.jl")

    export download_tickers_duckdb, download_latest_tickers
    export process_tickers_csv, generate_filtered_tickers
    export collect_ticker_universe, collect_historical, normalize_eod_prices
    export find_split_refresh_targets
    export update_historical, update_historical_parallel, update_historical_sequential
    export update_split_ticker, add_historical_data, update_us_tickers
end

using .Sync

# Include fundamental data module
include("fundamental.jl")
include("fundamental_sync.jl")

# Export all public functions to maintain backward compatibility
export get_api_key
export get_ticker_data
export download_tickers_duckdb, download_latest_tickers, process_tickers_csv, generate_filtered_tickers
export collect_ticker_universe, collect_historical, normalize_eod_prices, collect_fundamentals
export find_split_refresh_targets
export connect_duckdb, close_duckdb, update_us_tickers
export upsert_stock_data, upsert_stock_data_bulk
export upsert_security_observations, upsert_fundamental_daily_metrics
export replace_ticker_universe
export add_historical_data, update_historical, update_historical_parallel, update_historical_sequential, update_split_ticker
export get_tickers_all, get_tickers_etf, get_tickers_stock
export connect_postgres, close_postgres, export_to_postgres
export write_parquet, ParquetWriteResult
export list_tables
export get_daily_fundamental, get_fundamental_meta
export normalize_security_observations, normalize_fundamental_daily_metrics
export get_fundamental_watermarks, sync_fundamentals!
export create_or_replace_table, create_tables, create_indexes, optimize_database
export POSTGRES_SCHEMA_VERSION, PostgresMigrationResult, PostgresMigrationError
export postgres_schema_version, migrate_postgres!
# Export types and errors
export DatabaseConnectionError, DatabaseQueryError, DuckDBConnection, PostgreSQLConnection
export SyncFailure, HistoricalCollectionResult, FundamentalCollectionResult, SyncIncompleteError

end # module QuansiftMarketData
