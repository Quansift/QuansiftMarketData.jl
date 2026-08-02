module Postgres
    using LibPQ
    using DuckDB
    using DBInterface
    using DataFrames
    using Logging

    using ..Config
    using ..Core: DuckDBConnection, validate_identifier, validate_file_path
    import ..Operations: upsert_stock_data, upsert_stock_data_bulk
    import ..Operations: upsert_security_observations, upsert_fundamental_daily_metrics
    using ..Operations: validate_fundamental_daily_metrics_keys
    using ..Schema:
        create_or_replace_table,
        generate_create_table_query,
        qualified_postgres_identifier,
        quote_postgres_identifier

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
    const TEMPORARY_ENV_LOCK = ReentrantLock()
    const POSTGRES_STAGE_COUNTER = Threads.Atomic{UInt64}(0)

    normalize_conninfo_value(value) = value === nothing || value === missing ? nothing : strip(String(value))

    function libpq_quote(value::String)::String
        escaped = replace(value, "\\" => "\\\\", "'" => "\\'")
        return "'$escaped'"
    end

    function parse_postgres_connection_options(connection_string::String)
        error_pointer = Ref{Ptr{UInt8}}(C_NULL)
        options_pointer = LibPQ.libpq_c.PQconninfoParse(
            connection_string,
            error_pointer,
        )

        if error_pointer[] != C_NULL
            LibPQ.libpq_c.PQfreemem(error_pointer[])
            options_pointer != C_NULL &&
                LibPQ.libpq_c.PQconninfoFree(options_pointer)
            throw(ArgumentError(
                "Invalid PostgreSQL connection string (libpq parse failure)",
            ))
        elseif options_pointer == C_NULL
            throw(ArgumentError(
                "Invalid PostgreSQL connection string (libpq allocation failure)",
            ))
        end

        try
            return LibPQ.conninfo(options_pointer)
        finally
            LibPQ.libpq_c.PQconninfoFree(options_pointer)
        end
    end

    function connection_options_map(connection::Union{String, PostgreSQLConnection})::Dict{String,String}
        raw_options = connection isa PostgreSQLConnection ?
            LibPQ.conninfo(connection) :
            parse_postgres_connection_options(connection)
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
        options = connection_options_map(connection_string)

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
        lock(TEMPORARY_ENV_LOCK) do
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
    end

    const POSTGRES_EXTENSION_LOAD_ERROR =
        "DuckDB PostgreSQL extension is not preinstalled. " *
        "Preinstall it at build time with `INSTALL postgres`, then retry; " *
        "runtime downloads are disabled."

    function load_postgres_extension!(
        conn;
        execute::Function=DBInterface.execute,
    )::Nothing
        try
            execute(conn, "LOAD postgres")
        catch
            throw(ErrorException(POSTGRES_EXTENSION_LOAD_ERROR))
        end
        return nothing
    end

    function require_idle_transaction(
        pg_conn::PostgreSQLConnection,
        operation::AbstractString,
    )::Nothing
        LibPQ.transaction_status(pg_conn) == LibPQ.libpq_c.PQTRANS_IDLE ||
            throw(ArgumentError(
                "$operation requires an idle PostgreSQL connection; " *
                "caller-owned transactions are not supported",
            ))
        return nothing
    end

    function drop_postgres_table_if_exists(pg_conn::PostgreSQLConnection, table_name::String)
        safe_name = validate_identifier(table_name)
        LibPQ.execute(pg_conn, generate_drop_postgres_table_query(safe_name))
    end

    function generate_drop_postgres_table_query(table_name::String)::String
        safe_name = validate_identifier(table_name)
        return "DROP TABLE IF EXISTS $(qualified_postgres_identifier(safe_name));"
    end

    function next_postgres_staging_name()::String
        sequence = Threads.atomic_add!(POSTGRES_STAGE_COUNTER, UInt64(1))
        token = string(time_ns(); base=16, pad=16) *
                string(UInt64(getpid()); base=16, pad=8) *
                string(sequence; base=16, pad=16)
        return validate_identifier("_tiingo_stage_$token")
    end

    function build_postgres_export_plans(tables::Vector{String})
        isempty(tables) && throw(ArgumentError("tables must contain at least one table name"))

        safe_tables = validate_identifier.(tables)
        logical_tables = lowercase.(safe_tables)
        length(unique(logical_tables)) == length(logical_tables) ||
            throw(ArgumentError("tables must not contain duplicate PostgreSQL table names"))

        return [
            (target=table_name, staging=next_postgres_staging_name())
            for table_name in safe_tables
        ]
    end

    function prepare_single_postgres_export(
        pg_conn,
        table_name::String;
        require_idle::Function=require_idle_transaction,
    )
        plan = only(build_postgres_export_plans([table_name]))
        require_idle(pg_conn, "single-table PostgreSQL export")
        return plan
    end

    """
        is_fk_referenced(pg_conn, table_name) -> Bool

    Check whether `table_name` is referenced by any foreign key constraint
    from another table (i.e. it is the *parent* / referenced side).
    """
    function is_fk_referenced(pg_conn::PostgreSQLConnection, table_name::String)::Bool
        safe_name = validate_identifier(table_name)
        qualified_name = qualified_postgres_identifier(safe_name)
        result = LibPQ.execute(pg_conn, """
            SELECT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE contype = 'f'
                  AND confrelid = '$qualified_name'::regclass
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
        qualified_name = qualified_postgres_identifier(safe_name)
        result = LibPQ.execute(pg_conn, """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = '$qualified_name'::regclass
              AND i.indisprimary
            ORDER BY a.attnum
        """)
        df = DataFrame(result)
        return String.(df[!, :attname])
    end

    function generate_refresh_upsert_query(
        target_table::String,
        staging_table::String,
        all_columns::AbstractVector{<:AbstractString},
        primary_key_columns::AbstractVector{<:AbstractString},
    )::String
        logical_columns = lowercase.(all_columns)
        logical_primary_keys = lowercase.(primary_key_columns)
        non_primary_columns = filter(
            column -> !(column in logical_primary_keys),
            logical_columns,
        )

        quoted_target = qualified_postgres_identifier(target_table)
        quoted_staging = qualified_postgres_identifier(staging_table)
        quoted_columns = quote_postgres_identifier.(logical_columns)
        quoted_primary_keys = quote_postgres_identifier.(logical_primary_keys)
        columns_sql = join(quoted_columns, ", ")
        primary_keys_sql = join(quoted_primary_keys, ", ")

        conflict_action = if isempty(non_primary_columns)
            "DO NOTHING"
        else
            updates = [
                begin
                    quoted_column = quote_postgres_identifier(column)
                    "$quoted_column = EXCLUDED.$quoted_column"
                end
                for column in non_primary_columns
            ]
            "DO UPDATE SET $(join(updates, ", "))"
        end

        return "INSERT INTO $quoted_target ($columns_sql) " *
               "SELECT $columns_sql FROM $quoted_staging " *
               "ON CONFLICT ($primary_keys_sql) $conflict_action"
    end

    function publish_postgres_table!(
        pg_conn::PostgreSQLConnection,
        target_table::String,
        staging_table::String,
    )::Nothing
        safe_target = validate_identifier(target_table)
        safe_staging = validate_identifier(staging_table)
        qualified_target = qualified_postgres_identifier(safe_target)
        qualified_staging = qualified_postgres_identifier(safe_staging)
        quoted_target_name = quote_postgres_identifier(lowercase(safe_target))

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
            upsert_query = generate_refresh_upsert_query(
                safe_target,
                safe_staging,
                all_cols,
                pk_cols,
            )

            @info "Table $safe_target is FK-referenced; using upsert instead of drop+rename"
            LibPQ.execute(pg_conn, upsert_query)
            LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $qualified_staging;")
        else
            # Fast path: drop + rename (no FK dependents)
            LibPQ.execute(pg_conn, "DROP TABLE IF EXISTS $qualified_target;")
            LibPQ.execute(
                pg_conn,
                "ALTER TABLE $qualified_staging RENAME TO $quoted_target_name;",
            )
        end
        return nothing
    end

    function replace_postgres_table!(
        pg_conn::PostgreSQLConnection,
        target_table::String,
        staging_table::String,
    )::Nothing
        safe_target = validate_identifier(target_table)
        safe_staging = validate_identifier(staging_table)
        require_idle_transaction(pg_conn, "PostgreSQL table replacement")

        LibPQ.execute(pg_conn, "BEGIN")
        try
            publish_postgres_table!(pg_conn, safe_target, safe_staging)
            LibPQ.execute(pg_conn, "COMMIT")
            return nothing
        catch e
            try
                LibPQ.execute(pg_conn, "ROLLBACK")
            catch
            end
            try
                drop_postgres_table_if_exists(pg_conn, safe_staging)
            catch
            end
            @error "Failed to atomically replace PostgreSQL table" target_table=safe_target staging_table=safe_staging exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    function publish_postgres_tables!(
        pg_conn,
        plans::AbstractVector;
        require_idle::Function=require_idle_transaction,
        execute::Function=LibPQ.execute,
        publish::Function=publish_postgres_table!,
    )::Nothing
        isempty(plans) && throw(ArgumentError("plans must contain at least one table"))
        require_idle(pg_conn, "PostgreSQL batch table replacement")

        execute(pg_conn, "BEGIN")
        try
            for plan in plans
                publish(pg_conn, plan.target, plan.staging)
            end
            execute(pg_conn, "COMMIT")
            return nothing
        catch
            try
                execute(pg_conn, "ROLLBACK")
            catch
            end
            rethrow()
        end
    end

    """
        connect_postgres(connection_string::String; timeout_seconds::Int=30, max_retries::Int=3, retry_delay::Int=5)

    Connect to the PostgreSQL database with retry logic and timeout.
    """
    function validate_postgres_connection(conn)::Nothing
        result = execute(conn, "SELECT 1")
        close(result)
        return nothing
    end

    function open_validated_postgres_connection(
        connection_string::String;
        opener::Function=LibPQ.Connection,
        validator::Function=validate_postgres_connection,
        closer::Function=LibPQ.close,
    )
        conn = opener(connection_string)
        try
            validator(conn)
            return conn
        catch
            try
                closer(conn)
            catch close_error
                @warn "Failed to close PostgreSQL connection after validation error" exception=(close_error, catch_backtrace())
            end
            rethrow()
        end
    end

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

                conn = open_validated_postgres_connection(conn_str)

                @info "Connected to PostgreSQL successfully" attempt=attempt
                return conn
            catch e
                safe_error = sanitize_postgres_connection_error(e)
                last_error = safe_error
                @warn "PostgreSQL connection attempt $attempt/$max_retries failed" exception=(safe_error, catch_backtrace())

                if attempt < max_retries
                    @info "Retrying in $retry_delay seconds..."
                    sleep(retry_delay)
                end
            end
        end

        @error "Failed to connect to PostgreSQL after $max_retries attempts"
        throw(last_error)
    end

    function sanitize_postgres_connection_error(error)::Exception
        error isa ArgumentError &&
            startswith(error.msg, "Invalid PostgreSQL connection string") &&
            return error
        message = sprint(showerror, error)
        message = replace(
            message,
            r"(?i)(postgres(?:ql)?://)[^@\s]+@" => s"\1[REDACTED]@",
        )
        message = replace(
            message,
            r"(?i)((?:user|password|passfile|pgpassword)\s*=\s*)(?:'[^']*'|\S+)" =>
                s"\1[REDACTED]",
        )
        return ErrorException(message)
    end

    """
        close_postgres(conn::PostgreSQLConnection)

    Close the PostgreSQL database connection.
    """
    close_postgres(conn::PostgreSQLConnection) = LibPQ.close(conn)

    function select_upsert_columns(
        data::DataFrame,
        mappings::Vector{Pair{Symbol,Symbol}},
    )::DataFrame
        available = Set(propertynames(data))
        required = first.(mappings)
        missing_columns = filter(column -> !(column in available), required)
        isempty(missing_columns) || throw(ArgumentError(
            "DataFrame is missing required columns: $(join(string.(missing_columns), ", "))",
        ))

        selected = DataFrame()
        for (source, target) in mappings
            selected[!, target] = data[!, source]
        end
        return selected
    end

    function transactional_upsert!(
        pg_conn::PostgreSQLConnection,
        table_name::String,
        data::DataFrame,
        conflict_columns::Vector{Symbol},
        update_columns::Vector{Symbol};
        select_expressions::Union{Nothing,Vector{String}}=nothing,
    )::Int
        nrow(data) == 0 && return 0

        safe_table = validate_identifier(table_name)
        staging_name = validate_identifier("_tiingo_$(safe_table)_$(time_ns())")
        columns = Symbol.(names(data))
        quoted_columns = quote_postgres_identifier.(string.(columns))
        column_sql = join(quoted_columns, ", ")
        placeholders = join([string('$', index) for index in eachindex(columns)], ", ")
        conflict_sql = join(quote_postgres_identifier.(string.(conflict_columns)), ", ")
        update_sql = join(
            [
                begin
                    quoted_column = quote_postgres_identifier(string(column))
                    "$quoted_column = EXCLUDED.$quoted_column"
                end
                for column in update_columns
            ],
            ", ",
        )
        qualified_table = qualified_postgres_identifier(safe_table)
        quoted_staging = quote_postgres_identifier(staging_name)
        qualified_staging = qualified_postgres_identifier(
            staging_name;
            schema="pg_temp",
        )
        source_sql = isnothing(select_expressions) ?
            column_sql :
            join(select_expressions, ", ")

        require_idle_transaction(pg_conn, "PostgreSQL DataFrame upsert")
        close(LibPQ.execute(pg_conn, "BEGIN"))
        try
            close(LibPQ.execute(
                pg_conn,
                "CREATE TEMP TABLE $quoted_staging " *
                "(LIKE $qualified_table INCLUDING DEFAULTS) ON COMMIT DROP",
            ))
            LibPQ.load!(
                data,
                pg_conn,
                "INSERT INTO $qualified_staging ($column_sql) VALUES ($placeholders)",
            )
            upsert_result = LibPQ.execute(
                pg_conn,
                """
                INSERT INTO $qualified_table ($column_sql)
                SELECT $source_sql FROM $qualified_staging
                ON CONFLICT ($conflict_sql) DO UPDATE SET $update_sql
                """,
            )
            affected_rows = try
                LibPQ.num_affected_rows(upsert_result)
            finally
                close(upsert_result)
            end
            close(LibPQ.execute(pg_conn, "COMMIT"))
            @info "Upserted DataFrame into PostgreSQL" table=safe_table rows=affected_rows
            return affected_rows
        catch
            try
                close(LibPQ.execute(pg_conn, "ROLLBACK"))
            catch
            end
            rethrow()
        end
    end

    const STOCK_COLUMN_MAPPINGS = [
        :date => :date,
        :close => :close,
        :high => :high,
        :low => :low,
        :open => :open,
        :volume => :volume,
        :adjClose => :adjclose,
        :adjHigh => :adjhigh,
        :adjLow => :adjlow,
        :adjOpen => :adjopen,
        :adjVolume => :adjvolume,
        :divCash => :divcash,
        :splitFactor => :splitfactor,
    ]

    const SECURITY_OBSERVATION_COLUMN_MAPPINGS = [
        :perma_ticker => :perma_ticker,
        :observed_at => :observed_at,
        :ticker => :ticker,
        :is_active => :is_active,
        :is_adr => :is_adr,
        :daily_last_updated => :daily_last_updated,
        :exchange => :exchange,
        :asset_type => :asset_type,
        :price_coverage_start => :price_coverage_start,
        :price_coverage_end => :price_coverage_end,
        :is_leveraged => :is_leveraged,
        :join_status => :join_status,
    ]

    const FUNDAMENTAL_METRIC_COLUMN_MAPPINGS = [
        :perma_ticker => :perma_ticker,
        :metric_date => :metric_date,
        :market_cap => :market_cap,
        :enterprise_value => :enterprise_value,
        :pe_ratio => :pe_ratio,
        :available_at => :available_at,
        :fetched_at => :fetched_at,
        :source_revision => :source_revision,
    ]

    const TICKER_UNIVERSE_COLUMN_MAPPINGS = [
        :ticker => :ticker,
        :exchange => :exchange,
        :asset_type => :assettype,
        :price_currency => :pricecurrency,
        :start_date => :startdate,
        :end_date => :enddate,
    ]

    function load_ticker_universe_frame!(
        pg_conn::PostgreSQLConnection,
        table_name::String,
        data::DataFrame,
    )::Nothing
        nrow(data) == 0 && return nothing

        safe_table = validate_identifier(table_name)
        columns = Symbol.(names(data))
        column_sql = join(quote_postgres_identifier.(string.(columns)), ", ")
        placeholders = join([string('$', index) for index in eachindex(columns)], ", ")
        LibPQ.load!(
            data,
            pg_conn,
            "INSERT INTO $(qualified_postgres_identifier(safe_table)) " *
            "($column_sql) VALUES ($placeholders)",
        )
        return nothing
    end

    function postgres_table_row_count(
        pg_conn::PostgreSQLConnection,
        table_name::String,
    )::Int
        safe_table = validate_identifier(table_name)
        result = LibPQ.execute(
            pg_conn,
            generate_postgres_table_row_count_query(safe_table),
        )
        try
            rows = DataFrame(result)
            return Int(rows[1, :row_count])
        finally
            close(result)
        end
    end

    function generate_postgres_table_row_count_query(table_name::String)::String
        safe_table = validate_identifier(table_name)
        return "SELECT count(*) AS row_count FROM " *
               qualified_postgres_identifier(safe_table)
    end

    const POSTGRES_TRUNCATE_TICKER_UNIVERSE_SQL =
        "TRUNCATE TABLE \"public\".\"us_tickers\", " *
        "\"public\".\"us_tickers_filtered\""

    """
        replace_ticker_universe(pg_conn, all_data, filtered_data)

    Atomically replace both PostgreSQL ticker-universe snapshots while retaining
    the existing table identities. Input frames use canonical snake-case
    columns: `ticker`, `exchange`, `asset_type`, `price_currency`,
    `start_date`, and `end_date`.
    """
    function replace_ticker_universe(
        pg_conn::PostgreSQLConnection,
        all_data::DataFrame,
        filtered_data::DataFrame,
    )::NamedTuple{(:all_rows,:filtered_rows),Tuple{Int,Int}}
        all_frame = select_upsert_columns(all_data, TICKER_UNIVERSE_COLUMN_MAPPINGS)
        filtered_frame = select_upsert_columns(
            filtered_data,
            TICKER_UNIVERSE_COLUMN_MAPPINGS,
        )
        require_idle_transaction(pg_conn, "replace_ticker_universe")

        close(LibPQ.execute(pg_conn, "BEGIN"))
        try
            close(LibPQ.execute(
                pg_conn,
                POSTGRES_TRUNCATE_TICKER_UNIVERSE_SQL,
            ))
            load_ticker_universe_frame!(pg_conn, "us_tickers", all_frame)
            load_ticker_universe_frame!(
                pg_conn,
                "us_tickers_filtered",
                filtered_frame,
            )
            all_rows = postgres_table_row_count(pg_conn, "us_tickers")
            filtered_rows = postgres_table_row_count(pg_conn, "us_tickers_filtered")
            close(LibPQ.execute(pg_conn, "COMMIT"))
            return (; all_rows, filtered_rows)
        catch
            try
                close(LibPQ.execute(pg_conn, "ROLLBACK"))
            catch
            end
            rethrow()
        end
    end

    """
        upsert_stock_data(pg_conn::PostgreSQLConnection, data::DataFrame, ticker::String)::Int

    Idempotently upsert one ticker's normalized EOD rows directly into
    PostgreSQL. The operation is atomic and never replaces the full table.
    """
    function upsert_stock_data(
        pg_conn::PostgreSQLConnection,
        data::DataFrame,
        ticker::String,
    )::Int
        nrow(data) == 0 && return 0
        frame = select_upsert_columns(data, STOCK_COLUMN_MAPPINGS)
        insertcols!(frame, 1, :ticker => fill(ticker, nrow(frame)))
        select_expressions = [
            "ticker",
            "date",
            "COALESCE(close, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(high, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(low, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(open, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(volume, 0)",
            "COALESCE(adjclose, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(adjhigh, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(adjlow, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(adjopen, 'NaN'::DOUBLE PRECISION)",
            "COALESCE(adjvolume, 0)",
            "COALESCE(divcash, 0.0)",
            "COALESCE(splitfactor, 1.0)",
        ]
        return transactional_upsert!(
            pg_conn,
            "historical_data",
            frame,
            [:ticker, :date],
            Symbol.(names(frame)[3:end]);
            select_expressions,
        )
    end

    """
        upsert_stock_data_bulk(pg_conn::PostgreSQLConnection, data::DataFrame, ticker::String)::Int

    PostgreSQL-compatible bulk alias matching the existing DuckDB contract.
    If `data` contains a ticker column, rows for other tickers are ignored.
    """
    function upsert_stock_data_bulk(
        pg_conn::PostgreSQLConnection,
        data::DataFrame,
        ticker::String,
    )::Int
        nrow(data) == 0 && return 0
        ticker_data = if :ticker in propertynames(data)
            filter(
                row -> !ismissing(row.ticker) && !isnothing(row.ticker) &&
                    String(row.ticker) == ticker,
                data,
            )
        else
            data
        end
        return upsert_stock_data(pg_conn, ticker_data, ticker)
    end

    """
        upsert_security_observations(pg_conn::PostgreSQLConnection, data::DataFrame)::Int

    Idempotently upsert normalized security identity observations directly
    into PostgreSQL.
    """
    function upsert_security_observations(
        pg_conn::PostgreSQLConnection,
        data::DataFrame,
    )::Int
        nrow(data) == 0 && return 0
        frame = select_upsert_columns(data, SECURITY_OBSERVATION_COLUMN_MAPPINGS)
        return transactional_upsert!(
            pg_conn,
            "security_observations",
            frame,
            [:perma_ticker, :observed_at],
            Symbol.(names(frame)[3:end]),
        )
    end

    """
        upsert_fundamental_daily_metrics(pg_conn::PostgreSQLConnection, data::DataFrame)::Int

    Idempotently upsert normalized Daily Metrics rows directly into PostgreSQL.
    """
    function upsert_fundamental_daily_metrics(
        pg_conn::PostgreSQLConnection,
        data::DataFrame,
    )::Int
        nrow(data) == 0 && return 0
        frame = select_upsert_columns(data, FUNDAMENTAL_METRIC_COLUMN_MAPPINGS)
        validate_fundamental_daily_metrics_keys(frame)
        return transactional_upsert!(
            pg_conn,
            "fundamental_daily_metrics",
            frame,
            [:perma_ticker, :metric_date],
            Symbol.(names(frame)[3:end]),
        )
    end

    function cleanup_postgres_stages!(
        pg_conn,
        staging_tables::AbstractVector{<:AbstractString};
        drop_table::Function=drop_postgres_table_if_exists,
    )::Nothing
        cleanup_errors = Exception[]
        for staging_table in unique(String.(staging_tables))
            try
                drop_table(pg_conn, staging_table)
            catch e
                push!(cleanup_errors, e)
            end
        end
        isempty(cleanup_errors) || throw(CompositeException(cleanup_errors))
        return nothing
    end

    function cleanup_postgres_stages_after_failure!(
        cleanup::Function,
        pg_conn,
        staging_tables::AbstractVector{<:AbstractString},
    )::Nothing
        try
            cleanup(pg_conn, staging_tables)
        catch cleanup_error
            @error "Failed to clean deprecated PostgreSQL export staging tables" staging_tables exception=(cleanup_error, catch_backtrace())
        end
        return nothing
    end

    function execute_postgres_export_plans!(
        duckdb_conn,
        pg_conn,
        plans::AbstractVector;
        max_retries::Int,
        retry_delay::Int,
        stage::Function,
        publish::Function,
        cleanup::Function,
        retry_operation::Function=retry_with_exponential_backoff,
    )::Nothing
        isempty(plans) && throw(ArgumentError("plans must contain at least one table"))
        staging_tables = String[plan.staging for plan in plans]

        try
            for plan in plans
                retry_operation(max_retries, retry_delay) do
                    cleanup(pg_conn, [plan.staging])
                    try
                        stage(duckdb_conn, pg_conn, plan)
                    catch
                        cleanup_postgres_stages_after_failure!(
                            cleanup,
                            pg_conn,
                            [plan.staging],
                        )
                        rethrow()
                    end
                end
            end

            retry_operation(max_retries, retry_delay) do
                publish(pg_conn, plans)
            end
        catch
            cleanup_postgres_stages_after_failure!(
                cleanup,
                pg_conn,
                staging_tables,
            )
            rethrow()
        end

        cleanup(pg_conn, staging_tables)
        return nothing
    end

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
        plans = build_postgres_export_plans(tables)
        require_idle_transaction(pg_conn, "deprecated PostgreSQL export")
        stage = function (source_conn, destination_conn, plan)
            stage_table_to_postgres!(
                source_conn,
                destination_conn,
                plan.target,
                plan.staging,
                parquet_file;
                pg_host,
                pg_user,
                pg_dbname,
                pg_connection_string,
                use_dataframe,
                max_rows_for_dataframe,
            )
        end
        publish = (destination_conn, staged_plans) ->
            publish_postgres_tables!(destination_conn, staged_plans)

        execute_postgres_export_plans!(
            duckdb_conn,
            pg_conn,
            plans;
            max_retries,
            retry_delay,
            stage,
            publish,
            cleanup=cleanup_postgres_stages!,
        )
        for plan in plans
            @info "Successfully exported $(plan.target) from DuckDB to PostgreSQL"
        end
        return nothing
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
        plan = prepare_single_postgres_export(pg_conn, table_name)
        try
            stage_table_to_postgres!(
                duckdb_conn,
                pg_conn,
                plan.target,
                plan.staging,
                parquet_file;
                pg_host,
                pg_user,
                pg_dbname,
                pg_connection_string,
                use_dataframe,
                max_rows_for_dataframe,
            )
            replace_postgres_table!(pg_conn, plan.target, plan.staging)
            return nothing
        catch e
            @error "Error exporting table $(plan.target)" exception=(e, catch_backtrace())
            rethrow(e)
        finally
            cleanup_postgres_stages_after_failure!(
                cleanup_postgres_stages!,
                pg_conn,
                [plan.staging],
            )
        end
    end

    function stage_table_to_postgres_dataframe!(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
        staging_name::String,
    )::Int
        safe_name = validate_identifier(table_name)
        safe_staging = validate_identifier(staging_name)
        @info "Exporting table $safe_name to PostgreSQL using DataFrames"

        df = DBInterface.execute(duckdb_conn, "SELECT * FROM $safe_name") |> DataFrame
        @info "Loaded $safe_name into DataFrame with $(nrow(df)) rows"

        schema = DBInterface.execute(duckdb_conn, "DESCRIBE $safe_name") |> DataFrame
        create_table_query = generate_create_table_query(
            safe_staging,
            schema;
            base_table_name=safe_name,
        )
        drop_postgres_table_if_exists(pg_conn, safe_staging)
        LibPQ.execute(pg_conn, create_table_query)

        insert_query = generate_dataframe_insert_query(safe_staging, names(df))
        LibPQ.load!(df, pg_conn, insert_query)
        @info "Loaded $(nrow(df)) rows into PostgreSQL staging table $safe_staging"
        return nrow(df)
    end

    function export_table_to_postgres_dataframe(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
    )
        plan = prepare_single_postgres_export(pg_conn, table_name)
        try
            rows = stage_table_to_postgres_dataframe!(
                duckdb_conn,
                pg_conn,
                plan.target,
                plan.staging,
            )
            replace_postgres_table!(pg_conn, plan.target, plan.staging)
            @info "Inserted $rows rows into PostgreSQL table $(plan.target)"
            return nothing
        catch e
            @error "Error exporting table $(plan.target) using DataFrames" exception=(e, catch_backtrace())
            rethrow(e)
        finally
            cleanup_postgres_stages_after_failure!(
                cleanup_postgres_stages!,
                pg_conn,
                [plan.staging],
            )
        end
    end

    function generate_dataframe_insert_query(
        table_name::String,
        column_names::AbstractVector{<:AbstractString},
    )::String
        quoted_table = qualified_postgres_identifier(table_name)
        quoted_columns = quote_postgres_identifier.(lowercase.(column_names))
        placeholders = [string('$', i) for i in eachindex(column_names)]
        return "INSERT INTO $quoted_table ($(join(quoted_columns, ", "))) " *
               "VALUES ($(join(placeholders, ", ")))"
    end

    function with_owned_parquet_file(f::Function, parquet_file::String)
        safe_hint = validate_file_path(abspath(parquet_file))
        return mktempdir(
            dirname(safe_hint);
            prefix=".tiingojulia-parquet-",
        ) do temporary_directory
            temporary_parquet = validate_file_path(
                joinpath(temporary_directory, "bridge.parquet"),
            )
            return f(temporary_parquet)
        end
    end

    function stage_table_to_postgres_parquet!(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
        staging_name::String,
        parquet_file::String;
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing,
        pg_connection_string::Union{Nothing,String}=nothing
    )::Int
        safe_name = validate_identifier(table_name)
        safe_staging = validate_identifier(staging_name)
        postgres_duckdb_staging = "\"postgres_db\".\"public\"." *
                                  quote_postgres_identifier(lowercase(safe_staging))
        @info "Exporting table $safe_name to PostgreSQL using Parquet"

        return with_owned_parquet_file(parquet_file) do temporary_parquet
            attached = false
            try
                # Export to a library-owned temporary parquet file.
                DBInterface.execute(
                    duckdb_conn,
                    """COPY $safe_name TO '$temporary_parquet';""",
                )
                @info "Exported $safe_name to temporary parquet file"

                # Create and load a staging table before swapping it into place.
                schema = DBInterface.execute(duckdb_conn, "DESCRIBE $safe_name") |> DataFrame
                create_table_query = generate_create_table_query(
                    safe_staging,
                    schema;
                    base_table_name=safe_name,
                )
                drop_postgres_table_if_exists(pg_conn, safe_staging)
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
                attached = true
                DBInterface.execute(
                    duckdb_conn,
                    """COPY $postgres_duckdb_staging FROM '$temporary_parquet';""",
                )
                DBInterface.execute(duckdb_conn, "DETACH postgres_db;")
                attached = false
                row_count = postgres_table_row_count(pg_conn, safe_staging)
                @info "Copied $row_count rows from Parquet into PostgreSQL staging table $safe_staging"
                return row_count
            finally
                if attached
                    try
                        DBInterface.execute(duckdb_conn, "DETACH postgres_db;")
                    catch
                    end
                end
            end
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
        pg_connection_string::Union{Nothing,String}=nothing,
    )
        plan = prepare_single_postgres_export(pg_conn, table_name)
        try
            stage_table_to_postgres_parquet!(
                duckdb_conn,
                pg_conn,
                plan.target,
                plan.staging,
                parquet_file;
                pg_host,
                pg_user,
                pg_dbname,
                pg_connection_string,
            )
            replace_postgres_table!(pg_conn, plan.target, plan.staging)
            @info "Copied data from Parquet into PostgreSQL table $(plan.target)"
            return nothing
        catch e
            @error "Error exporting table $(plan.target) using Parquet" exception=(e, catch_backtrace())
            rethrow(e)
        finally
            cleanup_postgres_stages_after_failure!(
                cleanup_postgres_stages!,
                pg_conn,
                [plan.staging],
            )
        end
    end

    function stage_table_to_postgres!(
        duckdb_conn::DuckDBConnection,
        pg_conn::PostgreSQLConnection,
        table_name::String,
        staging_name::String,
        parquet_file::String;
        pg_host::Union{Nothing,String}=nothing,
        pg_user::Union{Nothing,String}=nothing,
        pg_dbname::Union{Nothing,String}=nothing,
        pg_connection_string::Union{Nothing,String}=nothing,
        use_dataframe::Union{Bool,Nothing}=nothing,
        max_rows_for_dataframe::Int=1_000_000,
    )::Int
        safe_name = validate_identifier(table_name)
        safe_staging = validate_identifier(staging_name)
        @info "Staging table $safe_name for PostgreSQL publication"

        table_exists = DBInterface.execute(
            duckdb_conn,
            """
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'main' AND table_name = ?;
            """,
            [safe_name],
        ) |> DataFrame
        isempty(table_exists) && error("Table $safe_name does not exist in DuckDB")

        row_count_result = DBInterface.execute(
            duckdb_conn,
            "SELECT COUNT(*) FROM $safe_name",
        ) |> DataFrame
        row_count = Int(row_count_result[1, 1])
        use_df = isnothing(use_dataframe) ?
            row_count <= max_rows_for_dataframe :
            use_dataframe

        if use_df
            return stage_table_to_postgres_dataframe!(
                duckdb_conn,
                pg_conn,
                safe_name,
                safe_staging,
            )
        end
        return stage_table_to_postgres_parquet!(
            duckdb_conn,
            pg_conn,
            safe_name,
            safe_staging,
            parquet_file;
            pg_host,
            pg_user,
            pg_dbname,
            pg_connection_string,
        )
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
        pg_dbname::Union{Nothing,String}=nothing,
        execute::Function=DBInterface.execute,
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
                load_postgres_extension!(duckdb_conn; execute)
                execute(duckdb_conn, "ATTACH '' AS postgres_db (TYPE postgres);")
            end
            @info "Successfully set up PostgreSQL connection in DuckDB"
        catch e
            @error "Failed to set up PostgreSQL connection in DuckDB" exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    export PostgreSQLConnection
    export connect_postgres, close_postgres, export_to_postgres
    export replace_ticker_universe
    export upsert_stock_data, upsert_stock_data_bulk
    export upsert_security_observations, upsert_fundamental_daily_metrics
    export export_table_to_postgres, export_table_to_postgres_dataframe, export_table_to_postgres_parquet
    export setup_postgres_connection, load_postgres_extension!
    export normalize_postgres_connection_string, connection_options_map, postgres_env_vars
end
