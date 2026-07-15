module Postgres
    using LibPQ
    using DuckDB
    using DBInterface
    using DataFrames
    using Logging

    using ..Config
    using ..Core: DuckDBConnection, validate_identifier, validate_file_path
    using ..Schema: create_or_replace_table, generate_create_table_query

    const PostgreSQLConnection = LibPQ.Connection
    const LIBPQ_CONNINFO_ORDER = [
        "service",
        "host",
        "hostaddr",
        "port",
        "dbname",
        "user",
        "password",
        "passfile",
        "connect_timeout",
        "sslmode",
        "sslrootcert",
        "sslcert",
        "sslkey",
        "sslcrl",
        "sslcrldir",
        "application_name",
        "options",
        "target_session_attrs",
    ]
    const POSTGRES_ENV_MAP = Dict(
        "service" => "PGSERVICE",
        "host" => "PGHOST",
        "hostaddr" => "PGHOSTADDR",
        "port" => "PGPORT",
        "dbname" => "PGDATABASE",
        "user" => "PGUSER",
        "password" => "PGPASSWORD",
        "passfile" => "PGPASSFILE",
        "connect_timeout" => "PGCONNECT_TIMEOUT",
        "sslmode" => "PGSSLMODE",
        "sslrootcert" => "PGSSLROOTCERT",
        "sslcert" => "PGSSLCERT",
        "sslkey" => "PGSSLKEY",
        "sslcrl" => "PGSSLCRL",
        "sslcrldir" => "PGSSLCRLDIR",
        "application_name" => "PGAPPNAME",
        "options" => "PGOPTIONS",
        "target_session_attrs" => "PGTARGETSESSIONATTRS",
    )

    normalize_conninfo_value(value) = value === nothing || value === missing ? nothing : strip(String(value))

    function libpq_quote(value::String)::String
        escaped = replace(value, "\\" => "\\\\", "'" => "\\'")
        return "'$escaped'"
    end

    function connection_options_map(connection::Union{String, PostgreSQLConnection})::Dict{String,String}
        raw_options = connection isa PostgreSQLConnection ? LibPQ.conninfo(connection) : LibPQ.conninfo(connection)
        options = Dict{String,String}()

        for option in raw_options
            value = normalize_conninfo_value(option.val)
            if isnothing(value) || isempty(value)
                continue
            end
            options[String(option.keyword)] = value
        end

        return options
    end

    function build_postgres_connection_string(options::Dict{String,String})::String
        ordered_keys = [key for key in LIBPQ_CONNINFO_ORDER if haskey(options, key)]
        remaining_keys = sort!(collect(setdiff(Set(keys(options)), Set(ordered_keys))))
        all_keys = vcat(ordered_keys, remaining_keys)

        return join(["$key=$(libpq_quote(options[key]))" for key in all_keys], " ")
    end

    function normalize_postgres_connection_string(connection_string::String; timeout_seconds::Int=30)::String
        options = try
            connection_options_map(connection_string)
        catch e
            throw(ArgumentError("Invalid PostgreSQL connection string: $e"))
        end

        if timeout_seconds > 0 && !haskey(options, "connect_timeout")
            options["connect_timeout"] = string(timeout_seconds)
        end

        return build_postgres_connection_string(options)
    end

    function postgres_env_vars(options::Dict{String,String})::Dict{String,String}
        env_vars = Dict{String,String}()
        for (option_name, env_name) in POSTGRES_ENV_MAP
            if haskey(options, option_name)
                env_vars[env_name] = options[option_name]
            end
        end
        return env_vars
    end

    function with_temporary_env(f::Function, env_vars::Dict{String,String})
        original = Dict{String,Union{Nothing,String}}()
        try
            for (name, value) in env_vars
                original[name] = get(ENV, name, nothing)
                ENV[name] = value
            end
            return f()
        finally
            for name in keys(env_vars)
                original_value = get(original, name, nothing)
                if original_value === nothing
                    pop!(ENV, name, nothing)
                else
                    ENV[name] = original_value
                end
            end
        end
    end

    function drop_postgres_table_if_exists(pg_conn::PostgreSQLConnection, table_name::String)
        safe_name = validate_identifier(table_name)
        LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $safe_name;")
    end

    """
        is_fk_referenced(pg_conn, table_name) -> Bool

    Check whether `table_name` is referenced by any foreign key constraint
    from another table (i.e. it is the *parent* / referenced side).
    """
    function is_fk_referenced(pg_conn::PostgreSQLConnection, table_name::String)::Bool
        safe_name = validate_identifier(table_name)
        result = LibPQ.execute(pg_conn, """
            SELECT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE contype = 'f'
                  AND confrelid = '$safe_name'::regclass
            )
        """)
        df = DataFrame(result)
        return df[1, 1]
    end

    """
        get_primary_key_columns(pg_conn, table_name) -> Vector{String}

    Return the column names that form the primary key of `table_name`,
    looked up from the PostgreSQL catalog.
    """
    function get_primary_key_columns(pg_conn::PostgreSQLConnection, table_name::String)::Vector{String}
        safe_name = validate_identifier(table_name)
        result = LibPQ.execute(pg_conn, """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = '$safe_name'::regclass
              AND i.indisprimary
            ORDER BY a.attnum
        """)
        df = DataFrame(result)
        return String.(df[!, :attname])
    end

    function replace_postgres_table!(pg_conn::PostgreSQLConnection, target_table::String, staging_table::String)
        safe_target = validate_identifier(target_table)
        safe_staging = validate_identifier(staging_table)

        # Check if the target table exists and is referenced by foreign keys
        target_exists = false
        try
            res = LibPQ.execute(pg_conn, """
                SELECT EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = 'public' AND table_name = '$safe_target'
                )
            """)
            target_exists = DataFrame(res)[1, 1]
        catch
        end

        fk_referenced = target_exists && is_fk_referenced(pg_conn, safe_target)

        if fk_referenced
            # Upsert path: refresh in-place to preserve dependent FK constraints
            pk_cols = get_primary_key_columns(pg_conn, safe_target)
            if isempty(pk_cols)
                error("Table $safe_target is referenced by foreign keys but has no primary key; " *
                      "an upsert key is required to refresh in-place without dropping the table")
            end

            # Get column list from the staging table
            col_result = LibPQ.execute(pg_conn, """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = '$safe_staging'
                ORDER BY ordinal_position
            """)
            all_cols = String.(DataFrame(col_result)[!, :column_name])
            non_pk_cols = filter(c -> !(c in pk_cols), all_cols)

            cols_sql = join(all_cols, ", ")
            pk_sql = join(pk_cols, ", ")
            update_sql = join(["$c = EXCLUDED.$c" for c in non_pk_cols], ", ")

            upsert_query = if isempty(non_pk_cols)
                "INSERT INTO $safe_target ($cols_sql) SELECT $cols_sql FROM $safe_staging ON CONFLICT ($pk_sql) DO NOTHING"
            else
                "INSERT INTO $safe_target ($cols_sql) SELECT $cols_sql FROM $safe_staging ON CONFLICT ($pk_sql) DO UPDATE SET $update_sql"
            end

            @info "Table $safe_target is FK-referenced; using upsert instead of drop+rename"
            LibPQ.execute(pg_conn, "BEGIN")
            try
                LibPQ.execute(pg_conn, upsert_query)
                LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $safe_staging;")
                LibPQ.execute(pg_conn, "COMMIT")
            catch e
                try
                    LibPQ.execute(pg_conn, "ROLLBACK")
                catch
                end
                try
                    drop_postgres_table_if_exists(pg_conn, safe_staging)
                catch
                end
                @error "Failed to upsert into FK-referenced PostgreSQL table" target_table=safe_target staging_table=safe_staging exception=(e, catch_backtrace())
                rethrow(e)
            end
        else
            # Fast path: drop + rename (no FK dependents)
            LibPQ.execute(pg_conn, "BEGIN")
            try
                LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $safe_target;")
                LibPQ.execute(pg_conn, "ALTER TABLE $safe_staging RENAME TO $safe_target;")
                LibPQ.execute(pg_conn, "COMMIT")
            catch e
                try
                    LibPQ.execute(pg_conn, "ROLLBACK")
                catch
                end
                @error "Failed to atomically replace PostgreSQL table" target_table=safe_target staging_table=safe_staging exception=(e, catch_backtrace())
                rethrow(e)
            end
        end
    end

    """
        connect_postgres(connection_string::String; timeout_seconds::Int=30, max_retries::Int=3, retry_delay::Int=5)

    Connect to the PostgreSQL database with retry logic and timeout.
    """
    function connect_postgres(connection_string::String;
                             timeout_seconds::Int=30,
                             max_retries::Int=3,
                             retry_delay::Int=5)::PostgreSQLConnection
        last_error = nothing

        if max_retries < 1
            throw(ArgumentError("max_retries must be >= 1"))
        end

        for attempt in 1:max_retries
            try
                conn_str = normalize_postgres_connection_string(connection_string; timeout_seconds=timeout_seconds)

                conn = LibPQ.Connection(conn_str)

                # Test connection with simple query
                result = execute(conn, "SELECT 1")
                close(result)

                @info "Connected to PostgreSQL successfully" attempt=attempt
                return conn
            catch e
                last_error = e
                @warn "PostgreSQL connection attempt $attempt/$max_retries failed" exception=(e, catch_backtrace())

                if attempt < max_retries
                    @info "Retrying in $retry_delay seconds..."
                    sleep(retry_delay)
                end
            end
        end

        @error "Failed to connect to PostgreSQL after $max_retries attempts"
        throw(last_error)
    end

    """
        close_postgres(conn::PostgreSQLConnection)

    Close the PostgreSQL database connection.
    """
    close_postgres(conn::PostgreSQLConnection) = LibPQ.close(conn)

    """
        export_to_postgres(duckdb_conn::DuckDBConnection, pg_conn::PostgreSQLConnection, tables::Vector{String}; pg_host::String="127.0.0.1", pg_user::String="postgres", pg_dbname::String="tiingo")

    Export tables from DuckDB to PostgreSQL.
    """
    function export_to_postgres(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        tables::Vector{String};
        parquet_file::String="historical_data.parquet",
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing,
        pg_connection_string::Union{Nothing,String}=nothing,
        max_retries::Int=3,
        retry_delay::Int=5,
        use_dataframe::Union{Bool, Nothing}=nothing,
        max_rows_for_dataframe::Int = 1_000_000
    )
        for table_name in tables
            retry_with_exponential_backoff(max_retries, retry_delay) do
                export_table_to_postgres(
                    duckdb_conn, pg_conn, table_name, parquet_file;
                    pg_host=pg_host,
                    pg_user=pg_user,
                    pg_dbname=pg_dbname,
                    pg_connection_string=pg_connection_string,
                    use_dataframe=use_dataframe, max_rows_for_dataframe=max_rows_for_dataframe
                )
                @info "Successfully exported $table_name from DuckDB to PostgreSQL"
            end
        end
    end

    # Helper function for retrying with exponential backoff
    function retry_with_exponential_backoff(f::Function, max_retries::Int, initial_delay::Int)
        for attempt in 1:max_retries
            try
                return f()
            catch e
                if attempt == max_retries
                    @error "Failed after $max_retries attempts" exception=(e, catch_backtrace())
                    rethrow(e)
                end
                delay = initial_delay * 2^(attempt - 1)
                @warn "Attempt $attempt failed. Retrying in $delay seconds..." exception=(e, catch_backtrace())
                sleep(delay)
            end
        end
    end

    """
        export_table_to_postgres(duckdb_conn::DuckDBConnection, pg_conn::PostgreSQLConnection, table_name::String, pg_host::String, pg_user::String, pg_dbname::String)

    Export a single table from DuckDB to PostgreSQL.
    """
    function export_table_to_postgres(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
        parquet_file::String;
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing,
        pg_connection_string::Union{Nothing,String}=nothing,
        use_dataframe::Union{Bool, Nothing}=nothing,
        max_rows_for_dataframe::Int = 1_000_000
    )
        safe_name = validate_identifier(table_name)
        @info "Exporting table $safe_name to PostgreSQL"

        # Check if the table exists in DuckDB
        table_exists = DBInterface.execute(
            duckdb_conn,
            """
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'main' AND table_name = ?;
            """,
            [safe_name]
        ) |> DataFrame

        if isempty(table_exists)
            error("Table $safe_name does not exist in DuckDB")
        end

        # Get row count
        row_count = DBInterface.execute(duckdb_conn, "SELECT COUNT(*) FROM $safe_name") |> DataFrame
        row_count = row_count[1, 1]

        # Determine whether to use DataFrame or Parquet
        use_df = if isnothing(use_dataframe)
            row_count <= max_rows_for_dataframe
        else
            use_dataframe
        end

        if use_df
            export_table_to_postgres_dataframe(duckdb_conn, pg_conn, table_name)
        else
            export_table_to_postgres_parquet(
                duckdb_conn,
                pg_conn,
                table_name,
                parquet_file;
                pg_host=pg_host,
                pg_user=pg_user,
                pg_dbname=pg_dbname,
                pg_connection_string=pg_connection_string,
            )
        end
    end

    function export_table_to_postgres_dataframe(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String
    )
        safe_name = validate_identifier(table_name)
        staging_name = validate_identifier("$(safe_name)_staging")
        @info "Exporting table $safe_name to PostgreSQL using DataFrames"

        try
            # Read the entire table into a DataFrame
            df = DBInterface.execute(duckdb_conn, "SELECT * FROM $safe_name") |> DataFrame
            @info "Loaded $safe_name into DataFrame with $(nrow(df)) rows"

            # Create and load a staging table before swapping it into place.
            schema = DBInterface.execute(duckdb_conn, "DESCRIBE $safe_name") |> DataFrame
            create_table_query = generate_create_table_query(staging_name, schema)
            drop_postgres_table_if_exists(pg_conn, staging_name)
            LibPQ.execute(pg_conn, create_table_query)

            # Insert data into PostgreSQL
            columns = join(lowercase.(names(df)), ", ")
            placeholders = join([string('$', i) for i in 1:ncol(df)], ", ")
            insert_query = "INSERT INTO $staging_name ($columns) VALUES ($placeholders)"

            LibPQ.load!(
                df,
                pg_conn,
                insert_query
            )

            replace_postgres_table!(pg_conn, safe_name, staging_name)
            @info "Inserted $(nrow(df)) rows into PostgreSQL table $safe_name"

        catch e
            try
                drop_postgres_table_if_exists(pg_conn, staging_name)
            catch
            end
            @error "Error exporting table $safe_name using DataFrames" exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    function export_table_to_postgres_parquet(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
        parquet_file::String;
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing,
        pg_connection_string::Union{Nothing,String}=nothing
    )
        safe_name = validate_identifier(table_name)
        staging_name = validate_identifier("$(safe_name)_staging")
        safe_parquet = validate_file_path(parquet_file)
        @info "Exporting table $safe_name to PostgreSQL using Parquet"

        try
            # Export to parquet
            DBInterface.execute(duckdb_conn, """COPY $safe_name TO '$safe_parquet';""")
            @info "Exported $safe_name to parquet file"

            # Create and load a staging table before swapping it into place.
            schema = DBInterface.execute(duckdb_conn, "DESCRIBE $safe_name") |> DataFrame
            create_table_query = generate_create_table_query(staging_name, schema)
            drop_postgres_table_if_exists(pg_conn, staging_name)
            LibPQ.execute(pg_conn, create_table_query)

            # Copy data from parquet to PostgreSQL
            setup_postgres_connection(
                duckdb_conn,
                pg_conn;
                connection_string=pg_connection_string,
                pg_host=pg_host,
                pg_user=pg_user,
                pg_dbname=pg_dbname,
            )
            DBInterface.execute(
                duckdb_conn,
                """COPY postgres_db.$staging_name FROM '$safe_parquet';"""
            )
            DBInterface.execute(duckdb_conn, "DETACH postgres_db;")
            replace_postgres_table!(pg_conn, safe_name, staging_name)
            @info "Copied data from parquet file to PostgreSQL table $safe_name"
        catch e
            try
                drop_postgres_table_if_exists(pg_conn, staging_name)
            catch
            end
            @error "Error exporting table $safe_name using Parquet" exception=(e, catch_backtrace())
            rethrow(e)
        finally
            try
                DBInterface.execute(duckdb_conn, "DETACH postgres_db;")
            catch
            end
            if isfile(parquet_file)
                rm(parquet_file)
                @info "Removed temporary parquet file for $table_name"
            end
        end
    end

    """
        setup_postgres_connection(duckdb_conn::DuckDBConnection, pg_host::String, pg_user::String, pg_dbname::String)

    Set up a PostgreSQL connection in DuckDB.
    """
    function setup_postgres_connection(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection;
        connection_string::Union{Nothing,String}=nothing,
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing
    )
        try
            options = if !isnothing(connection_string) && !isempty(strip(connection_string))
                connection_options_map(connection_string)
            else
                connection_options_map(pg_conn)
            end

            if !isnothing(pg_host) && !isempty(strip(pg_host))
                options["host"] = pg_host
            end
            if !isnothing(pg_user) && !isempty(strip(pg_user))
                options["user"] = pg_user
            end
            if !isnothing(pg_dbname) && !isempty(strip(pg_dbname))
                options["dbname"] = pg_dbname
            end

            env_vars = postgres_env_vars(options)

            with_temporary_env(env_vars) do
                DBInterface.execute(duckdb_conn, "INSTALL postgres;")
                DBInterface.execute(duckdb_conn, "LOAD postgres;")
                DBInterface.execute(duckdb_conn, "ATTACH '' AS postgres_db (TYPE postgres);")
            end
            @info "Successfully set up PostgreSQL connection in DuckDB"
        catch e
            @error "Failed to set up PostgreSQL connection in DuckDB" exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    export PostgreSQLConnection
    export connect_postgres, close_postgres, export_to_postgres
    export export_table_to_postgres, export_table_to_postgres_dataframe, export_table_to_postgres_parquet
    export setup_postgres_connection, normalize_postgres_connection_string, connection_options_map, postgres_env_vars
end
