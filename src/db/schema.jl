module Schema
    using DBInterface
    using DuckDB
    using DataFrames
    using LibPQ
    using Logging
    using SHA

    using ..Config
    using ..Core: DuckDBConnection, DatabaseQueryError, validate_identifier

    const POSTGRES_CANONICAL_SCHEMA = "public"

    """Quote and schema-qualify a canonical PostgreSQL relation identifier."""
    function qualified_postgres_identifier(
        identifier::AbstractString;
        schema::AbstractString=POSTGRES_CANONICAL_SCHEMA,
    )::String
        return quote_postgres_identifier(lowercase(String(schema))) * "." *
               quote_postgres_identifier(lowercase(String(identifier)))
    end

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
                fetched_at TIMESTAMP NOT NULL
                    DEFAULT make_timestamp_ms(epoch_ms(current_timestamp)),
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

        historical_columns = DBInterface.execute(conn, """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'main'
              AND table_name = 'historical_data'
              AND column_name = 'fetched_at'
        """) |> DataFrame
        if isempty(historical_columns)
            DBInterface.execute(conn, """
                ALTER TABLE historical_data
                ADD COLUMN fetched_at TIMESTAMP
                DEFAULT TIMESTAMP '1970-01-01 00:00:00'
            """)
            DBInterface.execute(conn, """
                ALTER TABLE historical_data
                ALTER COLUMN fetched_at SET NOT NULL
            """)
            DBInterface.execute(conn, """
                ALTER TABLE historical_data
                ALTER COLUMN fetched_at SET DEFAULT
                    make_timestamp_ms(epoch_ms(current_timestamp))
            """)
            DBInterface.execute(conn, "CHECKPOINT")
        end
    end

    include("migrations.jl")

    """
        create_tables(conn::LibPQ.Connection)

    Migrate the canonical PostgreSQL schema to the version supported by this
    QuansiftMarketData build. The legacy `nothing` return value is preserved.
    """
    function create_tables(conn::LibPQ.Connection)
        migrate_postgres!(conn)
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
        safe_name = lowercase(validate_identifier(table_name))
        backup_name = validate_identifier("$(safe_name)_backup")
        qualified_name = qualified_postgres_identifier(safe_name)
        qualified_backup = qualified_postgres_identifier(backup_name)
        LibPQ.transaction_status(pg_conn) == LibPQ.libpq_c.PQTRANS_IDLE ||
            throw(ArgumentError(
                "create_or_replace_table requires an idle PostgreSQL connection",
            ))

        close(LibPQ.execute(pg_conn, "BEGIN"))
        try
            existence_result = LibPQ.execute(
                pg_conn,
                "SELECT table_name FROM information_schema.tables " *
                "WHERE table_schema = 'public' AND table_name = \$1",
                [safe_name],
            )
            table_exists_pg = try
                DataFrame(existence_result)
            finally
                close(existence_result)
            end

            if isempty(table_exists_pg)
                close(LibPQ.execute(pg_conn, create_table_query))
                @info "Created table $safe_name in PostgreSQL"
            else
                close(LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $qualified_backup"))
                close(LibPQ.execute(
                    pg_conn,
                    "CREATE TABLE $qualified_backup AS TABLE $qualified_name",
                ))
                close(LibPQ.execute(pg_conn, "DROP TABLE $qualified_name"))
                close(LibPQ.execute(pg_conn, create_table_query))
                @info "Created new table $safe_name in PostgreSQL, old table is stored as $backup_name"
            end
            close(LibPQ.execute(pg_conn, "COMMIT"))
            return nothing
        catch
            try
                close(LibPQ.execute(pg_conn, "ROLLBACK"))
            catch
            end
            rethrow()
        end
    end

    """
        quote_postgres_identifier(identifier::AbstractString)::String

    Quote a PostgreSQL identifier. Embedded double quotes are duplicated and
    NUL bytes are rejected because PostgreSQL strings cannot contain them.
    """
    function quote_postgres_identifier(identifier::AbstractString)::String
        occursin('\0', identifier) &&
            throw(ArgumentError("PostgreSQL identifiers cannot contain NUL bytes"))
        return "\"" * replace(identifier, "\"" => "\"\"") * "\""
    end

    """
        generate_create_table_query(table_name::String, schema::DataFrame)

    Generate a CREATE TABLE query for PostgreSQL based on the DuckDB schema.
    Converts all column names to lowercase to avoid case-sensitivity issues.
    """
    function generate_create_table_query(
        table_name::String,
        schema::DataFrame;
        base_table_name::Union{Nothing,String}=nothing,
    )
        logical_table_name = lowercase(table_name)
        quoted_table_name = qualified_postgres_identifier(logical_table_name)
        query = "CREATE TABLE IF NOT EXISTS $quoted_table_name ("
        columns = String[]
        for row in eachrow(schema)
            column_name = lowercase(row.column_name)
            data_type = row.column_type
            pg_type = map_duckdb_to_postgres_type(data_type)
            quoted_column_name = quote_postgres_identifier(column_name)
            push!(columns, "$quoted_column_name $pg_type")
        end
        query *= join(columns, ", ")

        # Match the logical table name even when building a staging table so
        # the swapped-in table keeps the key that ON CONFLICT upserts rely on.
        # PRIMARY KEY also makes it discoverable by get_primary_key_columns.
        base_name = isnothing(base_table_name) ?
            replace(logical_table_name, r"_staging$" => "") :
            lowercase(validate_identifier(base_table_name))
        primary_keys = Dict(
            "historical_data" => ("ticker", "date"),
            "security_observations" => ("perma_ticker", "observed_at"),
            "fundamental_daily_metrics" => ("perma_ticker", "metric_date"),
        )
        if haskey(primary_keys, base_name)
            quoted_primary_keys = quote_postgres_identifier.(primary_keys[base_name])
            query *= ", PRIMARY KEY ($(join(quoted_primary_keys, ", ")))"
        end

        query *= ")"
        return query
    end

    # DECIMAL(p, s) / NUMERIC(p, s). Precision and scale are digits only, and the
    # returned type is rebuilt from the parsed integers, so no caller-supplied
    # text ever reaches the generated DDL.
    const DECIMAL_TYPE_PATTERN = r"^(?:DECIMAL|NUMERIC)\(\s*(\d{1,4})\s*,\s*(\d{1,4})\s*\)$"

    # PostgreSQL rejects NUMERIC precision outside 1..1000.
    const MAX_NUMERIC_PRECISION = 1000

    """
        map_duckdb_to_postgres_type(duckdb_type::String)

    Map DuckDB data types to PostgreSQL data types.
    """
    function map_duckdb_to_postgres_type(duckdb_type::String)
        type_mapping = Dict{String,String}(
            "VARCHAR" => "VARCHAR",
            "INTEGER" => "INTEGER",
            "BIGINT" => "BIGINT",
            "FLOAT" => "REAL",
            "DOUBLE" => "DOUBLE PRECISION",
            "BOOLEAN" => "BOOLEAN",
            "DATE" => "DATE",
            "TIMESTAMP" => "TIMESTAMP"
        )

        normalized_type = uppercase(strip(duckdb_type))
        haskey(type_mapping, normalized_type) && return type_mapping[normalized_type]

        decimal_match = match(DECIMAL_TYPE_PATTERN, normalized_type)
        if decimal_match !== nothing
            precision = parse(Int, decimal_match.captures[1])
            scale = parse(Int, decimal_match.captures[2])
            if 1 <= precision <= MAX_NUMERIC_PRECISION && 0 <= scale <= precision
                return "NUMERIC($(precision), $(scale))"
            end
        end

        throw(ArgumentError(
            "Unsupported DuckDB type for PostgreSQL export: '$duckdb_type'",
        ))
    end
    export create_tables, create_indexes, create_or_replace_table, list_tables
    export generate_create_table_query, map_duckdb_to_postgres_type
    export quote_postgres_identifier, qualified_postgres_identifier
    export POSTGRES_SCHEMA_VERSION, PostgresMigrationResult, PostgresMigrationError
    export postgres_schema_version, migrate_postgres!
end
