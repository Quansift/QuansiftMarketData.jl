module Schema
    using DBInterface
    using DuckDB
    using DataFrames
    using LibPQ
    using Logging

    using ..Config
    using ..Core: DuckDBConnection, DatabaseQueryError, validate_identifier

    """
        create_tables(conn::DuckDBConnection)

    Create necessary tables in the DuckDB database if they don't exist.
    """
    function create_tables(conn::DuckDBConnection)
        tables = [
            (Config.DB.Tables.US_TICKERS, """
            CREATE TABLE IF NOT EXISTS us_tickers (
                ticker VARCHAR,
                exchange VARCHAR,
                assetType VARCHAR,
                priceCurrency VARCHAR,
                startDate DATE,
                endDate DATE
            )
            """),
            (Config.DB.Tables.US_TICKERS_FILTERED, """
            CREATE TABLE IF NOT EXISTS us_tickers_filtered AS
            SELECT * FROM us_tickers
            WHERE exchange IN ('NYSE', 'NASDAQ', 'NYSE ARCA', 'AMEX', 'ASX')
            AND assetType IN ('Stock', 'ETF')
            AND ticker NOT LIKE '%/%'
            """),
            (Config.DB.Tables.HISTORICAL_DATA, """
            CREATE TABLE IF NOT EXISTS historical_data (
                ticker VARCHAR,
                date DATE,
                close FLOAT,
                high FLOAT,
                low FLOAT,
                open FLOAT,
                volume BIGINT,
                adjClose FLOAT,
                adjHigh FLOAT,
                adjLow FLOAT,
                adjOpen FLOAT,
                adjVolume BIGINT,
                divCash FLOAT,
                splitFactor FLOAT,
                UNIQUE (ticker, date)
            )
            """),
            (Config.DB.Tables.SECURITY_OBSERVATIONS, """
            CREATE TABLE IF NOT EXISTS security_observations (
                perma_ticker VARCHAR NOT NULL,
                observed_at TIMESTAMP NOT NULL,
                ticker VARCHAR NOT NULL,
                is_active BOOLEAN NOT NULL,
                is_adr BOOLEAN,
                daily_last_updated TIMESTAMP,
                exchange VARCHAR,
                asset_type VARCHAR,
                price_coverage_start DATE,
                price_coverage_end DATE,
                is_leveraged BOOLEAN,
                join_status VARCHAR NOT NULL,
                PRIMARY KEY (perma_ticker, observed_at)
            )
            """),
            (Config.DB.Tables.FUNDAMENTAL_DAILY_METRICS, """
            CREATE TABLE IF NOT EXISTS fundamental_daily_metrics (
                perma_ticker VARCHAR,
                metric_date DATE,
                market_cap DOUBLE,
                enterprise_value DOUBLE,
                pe_ratio DOUBLE,
                available_at TIMESTAMP,
                fetched_at TIMESTAMP NOT NULL,
                source_revision VARCHAR,
                PRIMARY KEY (perma_ticker, metric_date)
            )
            """)
        ]

        failures = DatabaseQueryError[]
        for (table_name, query) in tables
            try
                DBInterface.execute(conn, query)
                @info "Created table if not exists: $table_name"
            catch e
                @error "Failed to create table: $table_name" exception=(e, catch_backtrace())
                push!(failures, DatabaseQueryError("Failed to create table '$table_name': $e", query))
            end
        end

        if !isempty(failures)
            throw(first(failures))
        end
    end

    """
        create_tables(conn::LibPQ.Connection)

    Idempotently create the PostgreSQL tables and indexes used by TiingoJulia.
    Existing tables are preserved. Unique indexes provide the deterministic
    conflict targets used by the PostgreSQL DataFrame upsert methods.
    """
    function create_tables(conn::LibPQ.Connection)
        LibPQ.transaction_status(conn) == LibPQ.libpq_c.PQTRANS_IDLE ||
            throw(ArgumentError(
                "create_tables requires an idle PostgreSQL connection; " *
                "caller-owned transactions are not supported",
            ))

        statements = [
            """
            CREATE TABLE IF NOT EXISTS us_tickers (
                ticker VARCHAR,
                exchange VARCHAR,
                assettype VARCHAR,
                pricecurrency VARCHAR,
                startdate DATE,
                enddate DATE
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS us_tickers_filtered (
                ticker VARCHAR,
                exchange VARCHAR,
                assettype VARCHAR,
                pricecurrency VARCHAR,
                startdate DATE,
                enddate DATE
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS historical_data (
                ticker VARCHAR NOT NULL,
                date DATE NOT NULL,
                close DOUBLE PRECISION,
                high DOUBLE PRECISION,
                low DOUBLE PRECISION,
                open DOUBLE PRECISION,
                volume BIGINT,
                adjclose DOUBLE PRECISION,
                adjhigh DOUBLE PRECISION,
                adjlow DOUBLE PRECISION,
                adjopen DOUBLE PRECISION,
                adjvolume BIGINT,
                divcash DOUBLE PRECISION,
                splitfactor DOUBLE PRECISION,
                PRIMARY KEY (ticker, date)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS security_observations (
                perma_ticker VARCHAR NOT NULL,
                observed_at TIMESTAMP NOT NULL,
                ticker VARCHAR NOT NULL,
                is_active BOOLEAN NOT NULL,
                is_adr BOOLEAN,
                daily_last_updated TIMESTAMP,
                exchange VARCHAR,
                asset_type VARCHAR,
                price_coverage_start DATE,
                price_coverage_end DATE,
                is_leveraged BOOLEAN,
                join_status VARCHAR NOT NULL,
                PRIMARY KEY (perma_ticker, observed_at)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS fundamental_daily_metrics (
                perma_ticker VARCHAR NOT NULL,
                metric_date DATE NOT NULL,
                market_cap DOUBLE PRECISION,
                enterprise_value DOUBLE PRECISION,
                pe_ratio DOUBLE PRECISION,
                available_at TIMESTAMP,
                fetched_at TIMESTAMP NOT NULL,
                source_revision VARCHAR,
                PRIMARY KEY (perma_ticker, metric_date)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_us_tickers_ticker ON us_tickers (ticker)",
            "CREATE INDEX IF NOT EXISTS idx_us_tickers_filtered_ticker ON us_tickers_filtered (ticker)",
            "CREATE INDEX IF NOT EXISTS idx_us_tickers_filtered_assettype ON us_tickers_filtered (assettype)",
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_historical_ticker_date ON historical_data (ticker, date)",
            "CREATE INDEX IF NOT EXISTS idx_historical_ticker ON historical_data (ticker)",
            "CREATE INDEX IF NOT EXISTS idx_historical_date ON historical_data (date)",
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_security_observations_key ON security_observations (perma_ticker, observed_at)",
            "CREATE INDEX IF NOT EXISTS idx_security_observations_ticker ON security_observations (ticker)",
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_fundamental_daily_metrics_key ON fundamental_daily_metrics (perma_ticker, metric_date)",
            "CREATE INDEX IF NOT EXISTS idx_fundamental_daily_metrics_date ON fundamental_daily_metrics (metric_date)",
        ]

        close(LibPQ.execute(conn, "BEGIN"))
        try
            for statement in statements
                close(LibPQ.execute(conn, statement))
            end
            close(LibPQ.execute(conn, "COMMIT"))
        catch
            try
                close(LibPQ.execute(conn, "ROLLBACK"))
            catch
            end
            rethrow()
        end
        return nothing
    end

    """
        create_indexes(conn::DuckDBConnection)

    Create indexes on the historical_data table for better query performance.
    """
    function create_indexes(conn::DuckDBConnection)
        try
            @info "Creating database indexes..."

            # Create index on ticker column for faster ticker lookups
            DBInterface.execute(conn, """
                CREATE INDEX IF NOT EXISTS idx_historical_ticker
                ON historical_data(ticker)
            """)

            # Create index on date column for faster date range queries
            DBInterface.execute(conn, """
                CREATE INDEX IF NOT EXISTS idx_historical_date
                ON historical_data(date)
            """)

            # Create composite index for ticker + date queries
            DBInterface.execute(conn, """
                CREATE INDEX IF NOT EXISTS idx_historical_ticker_date
                ON historical_data(ticker, date)
            """)

            @info "Database indexes created successfully"
        catch e
            @warn "Failed to create indexes" exception=e
            rethrow(e)
        end
    end

    """
        list_tables(conn::DuckDBConnection)

    List all tables in the database.
    """
    function list_tables(conn::DuckDBConnection)::DataFrame
        try
            result = DBInterface.execute(conn, """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'main'
                ORDER BY table_name
            """) |> DataFrame

            @info "Found $(nrow(result)) tables in database"
            return result
        catch e
            @warn "Failed to list tables" exception=e
            rethrow(e)
        end
    end

    """
        create_or_replace_table(pg_conn::LibPQ.Connection, table_name::String, create_table_query::String)

    Create or replace a table in PostgreSQL.
    """
    function create_or_replace_table(pg_conn::LibPQ.Connection, table_name::String, create_table_query::String)
        safe_name = validate_identifier(table_name)
        backup_name = validate_identifier("$(table_name)_backup")

        # Check if the table exists in PostgreSQL (use parameterized query for value)
        table_exists_pg = LibPQ.execute(
            pg_conn,
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = \$1;",
            [safe_name]
        ) |> DataFrame

        if isempty(table_exists_pg)
            # If the table doesn't exist, create it
            LibPQ.execute(pg_conn, create_table_query)
            @info "Created table $safe_name in PostgreSQL"
        else
            # If the table exists, rename it as a backup
            LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $backup_name;")
            LibPQ.execute(pg_conn, "CREATE TABLE $backup_name AS TABLE $safe_name;")
            LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $safe_name;")
            LibPQ.execute(pg_conn, create_table_query)
            @info "Created new table $safe_name in PostgreSQL, old table is stored as $backup_name"
        end
    end

    """
        generate_create_table_query(table_name::String, schema::DataFrame)

    Generate a CREATE TABLE query for PostgreSQL based on the DuckDB schema.
    Converts all column names to lowercase to avoid case-sensitivity issues.
    """
    function generate_create_table_query(table_name::String, schema::DataFrame)
        query = "CREATE TABLE IF NOT EXISTS $(lowercase(table_name)) ("
        columns = []
        for row in eachrow(schema)
            column_name = lowercase(row.column_name)
            data_type = row.column_type
            pg_type = map_duckdb_to_postgres_type(data_type)
            push!(columns, "$(column_name) $(pg_type)")
        end
        query *= join(columns, ", ")

        # Match the logical table name even when building a staging table so
        # the swapped-in table keeps the key that ON CONFLICT upserts rely on.
        # PRIMARY KEY also makes it discoverable by get_primary_key_columns.
        base_name = replace(lowercase(table_name), r"_staging$" => "")
        primary_keys = Dict(
            "historical_data" => ("ticker", "date"),
            "security_observations" => ("perma_ticker", "observed_at"),
            "fundamental_daily_metrics" => ("perma_ticker", "metric_date"),
        )
        if haskey(primary_keys, base_name)
            query *= ", PRIMARY KEY ($(join(primary_keys[base_name], ", ")))"
        end

        query *= ")"
        return query
    end

    """
        map_duckdb_to_postgres_type(duckdb_type::String)

    Map DuckDB data types to PostgreSQL data types.
    """
    function map_duckdb_to_postgres_type(duckdb_type::String)
        type_mapping = Dict(
            "VARCHAR" => "VARCHAR",
            "INTEGER" => "INTEGER",
            "BIGINT" => "BIGINT",
            "DOUBLE" => "DOUBLE PRECISION",
            "BOOLEAN" => "BOOLEAN",
            "DATE" => "DATE",
            "TIMESTAMP" => "TIMESTAMP"
        )

        for (key, value) in type_mapping
            if occursin(key, uppercase(duckdb_type))
                return value
            end
        end

        return duckdb_type  # Use the same type if no specific mapping
    end
    export create_tables, create_indexes, create_or_replace_table, list_tables
    export generate_create_table_query, map_duckdb_to_postgres_type
end
