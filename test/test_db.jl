using Test
using DataFrames
using Dates
using DuckDB
using DBInterface
using TiingoJulia
using TiingoJulia:
    DatabaseConnectionError,
    DatabaseQueryError,
    DuckDBConnection,
    PostgreSQLConnection,
    verify_duckdb_integrity,
    get_tickers_all,
    upsert_stock_data,
    upsert_stock_data_bulk,
    close_duckdb,
    connect_duckdb,
    connect_postgres,
    close_postgres,
    optimize_database
using TiingoJulia.DB.Postgres: connection_options_map, normalize_postgres_connection_string, postgres_env_vars

# Define mock function for fetch_single_ticker_data that works without Mocking
function mock_fetch_single_ticker_data(row, latest_dates_dict, latest_market_date, api_key)
    ticker = row.ticker

    # Create mock data
    mock_data = DataFrame(
        date = [
            latest_market_date - Day(5),
            latest_market_date - Day(4),
            latest_market_date - Day(3),
        ],
        close = [100.0, 101.0, 102.0],
        high = [105.0, 106.0, 107.0],
        low = [95.0, 96.0, 97.0],
        open = [98.0, 99.0, 100.0],
        volume = [1000000, 1100000, 1200000],
        adjClose = [100.0, 101.0, 102.0],
        adjHigh = [105.0, 106.0, 107.0],
        adjLow = [95.0, 96.0, 97.0],
        adjOpen = [98.0, 99.0, 100.0],
        adjVolume = [1000000, 1100000, 1200000],
        divCash = [0.0, 0.0, 0.0],
        splitFactor = [1.0, 1.0, 1.0],
    )

    if haskey(latest_dates_dict, ticker)
        status = :success
    else
        status = :missing
    end

    return (ticker, mock_data, status)
end

@testset "Database Operations" begin
    # Use a temporary database file so tests don't rely on any existing DuckDB
    test_db_path = tempname() * ".duckdb"

    # Clean up any existing test database
    isfile(test_db_path) && rm(test_db_path)

    @testset "Database Connection" begin
        # Test database connection
        conn = nothing
        @test_nowarn conn = connect_duckdb(test_db_path)
        @test conn isa DuckDBConnection

        # Test database verification
        is_valid, error_msg = verify_duckdb_integrity(test_db_path)
        @test is_valid == true
        @test error_msg === nothing

        # Test invalid database path (use a path that definitely can't be created)
        @test_throws DatabaseConnectionError connect_duckdb("/dev/null/invalid.duckdb")

        # Clean up
        close_duckdb(conn)
    end

    @testset "Table Operations" begin
        conn = connect_duckdb(test_db_path)

        # Test if tables were created
        tables_query = """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_name IN ('us_tickers', 'us_tickers_filtered', 'historical_data')
        """
        tables = DBInterface.execute(conn, tables_query) |> DataFrame
        @test nrow(tables) == 3

        # Test table schemas
        historical_schema =
            DBInterface.execute(conn, "DESCRIBE historical_data") |> DataFrame
        @test "ticker" in historical_schema.column_name
        @test "date" in historical_schema.column_name
        @test "close" in historical_schema.column_name

        close_duckdb(conn)
    end

    @testset "Data Operations" begin
        conn = connect_duckdb(test_db_path)

        # Test data for us_tickers - match the actual schema
        # First, let's check the actual schema
        schema = DBInterface.execute(conn, "DESCRIBE us_tickers") |> DataFrame
        @info "us_tickers schema: $schema"

        # Test updating us_tickers with correct schema
        DBInterface.execute(
            conn,
            """
    INSERT INTO us_tickers (ticker, exchange, assetType, priceCurrency, startDate, endDate)
    VALUES ('AAPL', 'NASDAQ', 'Stock', 'USD', '2000-01-01', '2023-12-31'),
        ('GOOGL', 'NASDAQ', 'Stock', 'USD', '2004-08-19', '2023-12-31')
""",
        )

        # Refresh filtered tickers table after inserting
        DBInterface.execute(
            conn,
            """
CREATE OR REPLACE TABLE us_tickers_filtered AS
SELECT * FROM us_tickers
WHERE exchange IN ('NYSE', 'NASDAQ', 'NYSE ARCA', 'AMEX', 'ASX')
  AND assetType IN ('Stock', 'ETF')
  AND ticker NOT LIKE '%/%'
""",
        )

        # Test retrieving tickers
        all_tickers = get_tickers_all(conn)
        @test nrow(all_tickers) > 0
        @test "AAPL" in all_tickers.ticker

        # Test stock data operations
        test_data = DataFrame(
            date = [Date("2023-01-01"), Date("2023-01-02")],
            close = [150.0, 151.0],
            high = [152.0, 153.0],
            low = [149.0, 150.0],
            open = [150.0, 151.0],
            volume = [1000000, 1100000],
            adjClose = [150.0, 151.0],
            adjHigh = [152.0, 153.0],
            adjLow = [149.0, 150.0],
            adjOpen = [150.0, 151.0],
            adjVolume = [1000000, 1100000],
            divCash = [0.0, 0.0],
            splitFactor = [1.0, 1.0],
        )

        # Test upserting stock data
        original_chunk_size = get(ENV, "TIINGO_DUCKDB_UPSERT_CHUNK_SIZE", nothing)
        ENV["TIINGO_DUCKDB_UPSERT_CHUNK_SIZE"] = "1"
        try
            rows_updated = upsert_stock_data(conn, test_data, "AAPL")
            @test rows_updated == 2

            updated_data = copy(test_data)
            updated_data.close .= [155.0, 156.0]
            rows_updated = upsert_stock_data(conn, updated_data, "AAPL")
            @test rows_updated == 2
        finally
            if original_chunk_size === nothing
                delete!(ENV, "TIINGO_DUCKDB_UPSERT_CHUNK_SIZE")
            else
                ENV["TIINGO_DUCKDB_UPSERT_CHUNK_SIZE"] = original_chunk_size
            end
        end

        # Verify inserted data
        result = DBInterface.execute(
            conn,
            """
    SELECT * FROM historical_data
    WHERE ticker = 'AAPL'
    ORDER BY date
""",
        ) |> DataFrame
        @test nrow(result) == 2
        @test result[1, :close] ≈ 155.0
        @test result[2, :close] ≈ 156.0

        close_duckdb(conn)
    end

    @testset "Error Handling" begin
        conn = connect_duckdb(test_db_path)

        # Test invalid SQL
        @test_throws Exception DBInterface.execute(conn, "SELECT * FROM nonexistent_table")

        # Test data type mismatch
        @test_throws Exception DBInterface.execute(
            conn,
            """
    INSERT INTO historical_data (ticker, date, close)
    VALUES ('AAPL', 'invalid_date', 'invalid_price')
""",
        )

        close_duckdb(conn)
    end

    # Clean up test database
    rm(test_db_path; force=true)
end

@testset "PostgreSQL Export Operations" begin
    # Note: These tests would require a running PostgreSQL instance
    # They should be skipped if PostgreSQL is not available
    @test_skip begin
        # Test PostgreSQL connection
        pg_conn = connect_postgres("dbname=test_db user=test_user")
        @test pg_conn isa PostgreSQLConnection
        close_postgres(pg_conn)
    end
end

@testset "PostgreSQL Connection Helpers" begin
    normalized_uri = normalize_postgres_connection_string(
        "postgresql://alice:secret@db.example.com:5432/tiingo?sslmode=require";
        timeout_seconds=15,
    )
    normalized_uri_options = connection_options_map(normalized_uri)

    @test normalized_uri_options["host"] == "db.example.com"
    @test normalized_uri_options["port"] == "5432"
    @test normalized_uri_options["dbname"] == "tiingo"
    @test normalized_uri_options["user"] == "alice"
    @test normalized_uri_options["password"] == "secret"
    @test normalized_uri_options["sslmode"] == "require"
    @test normalized_uri_options["connect_timeout"] == "15"

    normalized_kv = normalize_postgres_connection_string(
        "host=localhost dbname=tiingo user=alice connect_timeout=7";
        timeout_seconds=15,
    )
    normalized_kv_options = connection_options_map(normalized_kv)
    @test normalized_kv_options["connect_timeout"] == "7"

    env_vars = postgres_env_vars(normalized_uri_options)
    @test env_vars["PGHOST"] == "db.example.com"
    @test env_vars["PGPORT"] == "5432"
    @test env_vars["PGDATABASE"] == "tiingo"
    @test env_vars["PGUSER"] == "alice"
    @test env_vars["PGPASSWORD"] == "secret"
    @test env_vars["PGSSLMODE"] == "require"
end

@testset "Parallel Processing Features" begin
    # Test database file path
    test_db_path_parallel = tempname() * "_parallel.duckdb"

    # Clean up any existing test database
    isfile(test_db_path_parallel) && rm(test_db_path_parallel)

    # Create mock test data
    test_data = DataFrame(
        ticker = repeat(["AAPL", "GOOGL"], outer = 10),
        date = repeat([Date("2023-01-01"), Date("2023-01-02")], outer = 10),
        close = rand(100.0:200.0, 20),
        high = rand(150.0:250.0, 20),
        low = rand(50.0:150.0, 20),
        open = rand(100.0:200.0, 20),
        volume = rand(1000000:5000000, 20),
        adjClose = rand(100.0:200.0, 20),
        adjHigh = rand(150.0:250.0, 20),
        adjLow = rand(50.0:150.0, 20),
        adjOpen = rand(100.0:200.0, 20),
        adjVolume = rand(1000000:5000000, 20),
        divCash = zeros(20),
        splitFactor = ones(20),
    )

    # Create the test database
    conn = connect_duckdb(test_db_path_parallel)

    # Test database optimization
    original_threads = get(ENV, "TIINGO_DUCKDB_THREADS", nothing)
    original_worker_threads = get(ENV, "TIINGO_DUCKDB_WORKER_THREADS", nothing)
    original_memory_limit = get(ENV, "TIINGO_DUCKDB_MEMORY_LIMIT_GB", nothing)
    original_preserve_order = get(ENV, "TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER", nothing)

    ENV["TIINGO_DUCKDB_THREADS"] = "1"
    ENV["TIINGO_DUCKDB_WORKER_THREADS"] = "1"
    ENV["TIINGO_DUCKDB_MEMORY_LIMIT_GB"] = "1"
    ENV["TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER"] = "false"

    try
        @test_nowarn optimize_database(conn)
        settings = DBInterface.execute(
            conn,
            """
        SELECT name, value
        FROM duckdb_settings()
        WHERE name IN ('threads', 'worker_threads', 'preserve_insertion_order')
        """,
        ) |> DataFrame
        @test settings[settings.name .== "threads", :value][1] == "1"
        @test settings[settings.name .== "worker_threads", :value][1] == "1"
        @test settings[settings.name .== "preserve_insertion_order", :value][1] == "false"
    finally
        if original_threads === nothing
            delete!(ENV, "TIINGO_DUCKDB_THREADS")
        else
            ENV["TIINGO_DUCKDB_THREADS"] = original_threads
        end
        if original_worker_threads === nothing
            delete!(ENV, "TIINGO_DUCKDB_WORKER_THREADS")
        else
            ENV["TIINGO_DUCKDB_WORKER_THREADS"] = original_worker_threads
        end
        if original_memory_limit === nothing
            delete!(ENV, "TIINGO_DUCKDB_MEMORY_LIMIT_GB")
        else
            ENV["TIINGO_DUCKDB_MEMORY_LIMIT_GB"] = original_memory_limit
        end
        if original_preserve_order === nothing
            delete!(ENV, "TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER")
        else
            ENV["TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER"] = original_preserve_order
        end
    end

    # Test parallel data insertion
    @test_nowarn upsert_stock_data_bulk(conn, test_data, "AAPL")

    # Verify data was inserted
    result = DBInterface.execute(
        conn,
        """
    SELECT COUNT(*) FROM historical_data
    WHERE ticker = 'AAPL'
""",
    ) |> DataFrame
    @test result[1, 1] > 0

    # Clean up test database
    close_duckdb(conn)
    rm(test_db_path_parallel; force=true)
end
