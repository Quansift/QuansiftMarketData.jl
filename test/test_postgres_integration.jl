using Test
using DataFrames
using Dates
using DBInterface
using DuckDB
using LibPQ
using Tiingo

const MigrationSchemaIntegration = Tiingo.DB.Schema

function _pg_integration_query(conn::LibPQ.Connection, sql::String)::DataFrame
    result = LibPQ.execute(conn, sql)
    try
        return DataFrame(result)
    finally
        close(result)
    end
end

function _pg_integration_command(conn::LibPQ.Connection, sql::String)
    close(LibPQ.execute(conn, sql))
    return nothing
end

function _pg_integration_cleanup(conn::LibPQ.Connection)
    for table in (
        "tiingo_test_filtered_fk",
        "filtered_stocks",
        "legacy_atomic_child",
        "legacy_atomic_second",
        "legacy_atomic_first",
        "tiingojulia_schema_migrations",
        "fundamental_daily_metrics",
        "security_observations",
        "historical_data",
        "us_tickers_filtered",
        "us_tickers",
    )
        _pg_integration_command(conn, "DROP TABLE IF EXISTS $table CASCADE")
    end
end

function _pg_integration_create_v1_relation(conn, name::String)
    statements = Dict(
        "us_tickers" => """
            CREATE TABLE public.us_tickers (
                ticker VARCHAR, exchange VARCHAR, assettype VARCHAR,
                pricecurrency VARCHAR, startdate DATE, enddate DATE
            )
        """,
        "us_tickers_filtered" => """
            CREATE TABLE public.us_tickers_filtered (
                ticker VARCHAR, exchange VARCHAR, assettype VARCHAR,
                pricecurrency VARCHAR, startdate DATE, enddate DATE
            )
        """,
        "historical_data" => """
            CREATE TABLE public.historical_data (
                ticker VARCHAR, date DATE, close FLOAT, high FLOAT, low FLOAT,
                open FLOAT, volume BIGINT, adjclose FLOAT, adjhigh FLOAT,
                adjlow FLOAT, adjopen FLOAT, adjvolume BIGINT, divcash FLOAT,
                splitfactor FLOAT, UNIQUE (ticker, date)
            )
        """,
    )
    _pg_integration_command(conn, statements[name])
    if name == "historical_data"
        _pg_integration_command(
            conn,
            "INSERT INTO public.historical_data " *
            "(ticker, date, close, volume, splitfactor) VALUES " *
            "('LEGACY', DATE '2020-01-02', 42.5, 123, 1.0)",
        )
    else
        _pg_integration_command(
            conn,
            "INSERT INTO public.$name " *
            "(ticker, exchange, assettype, pricecurrency, startdate, enddate) " *
            "VALUES ('LEGACY', 'NASDAQ', 'Stock', 'USD', " *
            "DATE '2020-01-01', DATE '2020-01-03')",
        )
    end
    return nothing
end

function _pg_integration_create_current_preledger(conn)
    for statement in MigrationSchemaIntegration.POSTGRES_TARGET_DDL
        _pg_integration_command(conn, statement)
    end
    for statement in MigrationSchemaIntegration.POSTGRES_TARGET_INDEX_DDL
        _pg_integration_command(conn, statement)
    end
    return nothing
end

function _pg_integration_create_compatibility_export(conn)
    schemas = Dict(
        "historical_data" => DataFrame(
            column_name=[
                "ticker", "date", "close", "high", "low", "open", "volume",
                "adjClose", "adjHigh", "adjLow", "adjOpen", "adjVolume",
                "divCash", "splitFactor",
            ],
            column_type=[
                "VARCHAR", "DATE", "FLOAT", "FLOAT", "FLOAT", "FLOAT",
                "BIGINT", "FLOAT", "FLOAT", "FLOAT", "FLOAT", "BIGINT",
                "FLOAT", "FLOAT",
            ],
        ),
        "us_tickers_filtered" => DataFrame(
            column_name=[
                "ticker", "exchange", "assetType", "priceCurrency", "startDate",
                "endDate",
            ],
            column_type=["VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "DATE", "DATE"],
        ),
        "security_observations" => DataFrame(
            column_name=[
                "perma_ticker", "observed_at", "ticker", "is_active", "is_adr",
                "daily_last_updated", "exchange", "asset_type",
                "price_coverage_start", "price_coverage_end", "is_leveraged",
                "join_status",
            ],
            column_type=[
                "VARCHAR", "TIMESTAMP", "VARCHAR", "BOOLEAN", "BOOLEAN",
                "TIMESTAMP", "VARCHAR", "VARCHAR", "DATE", "DATE", "BOOLEAN",
                "VARCHAR",
            ],
        ),
        "fundamental_daily_metrics" => DataFrame(
            column_name=[
                "perma_ticker", "metric_date", "market_cap", "enterprise_value",
                "pe_ratio", "available_at", "fetched_at", "source_revision",
            ],
            column_type=[
                "VARCHAR", "DATE", "DOUBLE", "DOUBLE", "DOUBLE", "TIMESTAMP",
                "TIMESTAMP", "VARCHAR",
            ],
        ),
    )
    for name in (
        "historical_data",
        "us_tickers_filtered",
        "security_observations",
        "fundamental_daily_metrics",
    )
        _pg_integration_command(
            conn,
            MigrationSchemaIntegration.generate_create_table_query(name, schemas[name]),
        )
    end
    _pg_integration_command(conn, """
        INSERT INTO public.historical_data
          (ticker, date, close, high, low, open, volume, adjclose, adjhigh,
           adjlow, adjopen, adjvolume, divcash, splitfactor)
        VALUES ('EXPORTED', DATE '2024-02-03', 0.1, 0.2, 0.3, 0.4, 123,
                0.5, 0.6, 0.7, 0.8, 456, 0.9, 1.1)
    """)
    _pg_integration_command(conn, """
        INSERT INTO public.us_tickers_filtered
          (ticker, exchange, assettype, pricecurrency, startdate, enddate)
        VALUES ('EXPORTED', 'NASDAQ', 'Stock', 'USD',
                DATE '2024-01-01', DATE '2024-12-31')
    """)
    _pg_integration_command(conn, """
        INSERT INTO public.security_observations
          (perma_ticker, observed_at, ticker, is_active, join_status)
        VALUES ('PERMA', TIMESTAMP '2024-02-03 12:00:00', 'EXPORTED', true, 'matched')
    """)
    _pg_integration_command(conn, """
        INSERT INTO public.fundamental_daily_metrics
          (perma_ticker, metric_date, market_cap, fetched_at)
        VALUES ('PERMA', DATE '2024-02-03', 100.5, TIMESTAMP '2024-02-04 12:00:00')
    """)
    return nothing
end

function _pg_integration_create_deployed_export(
    conn;
    primary_key_name::String="scheduler filtered ticker pkey",
    create_filtered_stocks::Bool=true,
    foreign_key_delete_action::String="CASCADE",
)
    _pg_integration_create_compatibility_export(conn)
    _pg_integration_command(conn, """
        ALTER TABLE public.historical_data
          ALTER COLUMN close TYPE DOUBLE PRECISION,
          ALTER COLUMN high TYPE DOUBLE PRECISION,
          ALTER COLUMN low TYPE DOUBLE PRECISION,
          ALTER COLUMN open TYPE DOUBLE PRECISION,
          ALTER COLUMN adjclose TYPE DOUBLE PRECISION,
          ALTER COLUMN adjhigh TYPE DOUBLE PRECISION,
          ALTER COLUMN adjlow TYPE DOUBLE PRECISION,
          ALTER COLUMN adjopen TYPE DOUBLE PRECISION,
          ALTER COLUMN divcash TYPE DOUBLE PRECISION,
          ALTER COLUMN splitfactor TYPE DOUBLE PRECISION
    """)
    quoted_key = MigrationSchemaIntegration.quote_postgres_identifier(primary_key_name)
    _pg_integration_command(conn, """
        ALTER TABLE public.us_tickers_filtered
          ALTER COLUMN ticker SET NOT NULL,
          ADD CONSTRAINT $quoted_key PRIMARY KEY (ticker)
    """)
    _pg_integration_command(
        conn,
        "CREATE INDEX scheduler_filtered_assettype " *
        "ON public.us_tickers_filtered (assettype)",
    )
    _pg_integration_command(
        conn,
        "CREATE INDEX scheduler_filtered_exchange " *
        "ON public.us_tickers_filtered (exchange)",
    )
    create_filtered_stocks || return nothing
    ticker_definition =
        "ticker VARCHAR PRIMARY KEY " *
        "CONSTRAINT filtered_stocks_ticker_fkey " *
        "REFERENCES public.us_tickers_filtered (ticker) " *
        "ON DELETE $foreign_key_delete_action"
    _pg_integration_command(conn, """
        CREATE TABLE public.filtered_stocks (
            $ticker_definition,
            retained_value INTEGER NOT NULL
        )
    """)
    _pg_integration_command(
        conn,
        "INSERT INTO public.filtered_stocks VALUES ('EXPORTED', 7)",
    )
    return nothing
end

function _pg_integration_assert_legacy_rows(conn, names)
    for name in names
        if name == "historical_data"
            row = _pg_integration_query(
                conn,
                "SELECT ticker, date, close, volume, splitfactor " *
                "FROM public.historical_data",
            )
            @test row.ticker == ["LEGACY"]
            @test row.close == [42.5]
            @test row.volume == [123]
            @test row.splitfactor == [1.0]
        else
            row = _pg_integration_query(
                conn,
                "SELECT ticker, exchange, assettype, pricecurrency " *
                "FROM public.$name",
            )
            @test row.ticker == ["LEGACY"]
            @test row.exchange == ["NASDAQ"]
            @test row.assettype == ["Stock"]
            @test row.pricecurrency == ["USD"]
        end
    end
    return nothing
end

function _pg_integration_read_parquet(path::String)::DataFrame
    conn = DBInterface.connect(DuckDB.DB)
    try
        return DBInterface.execute(
            conn,
            "SELECT * FROM read_parquet('$path') ORDER BY ticker, date",
        ) |> DataFrame
    finally
        DBInterface.close!(conn)
    end
end

pg_connection_string = get(ENV, "TIINGO_TEST_PG_CONNECTION", "")

@testset "PostgreSQL 17 persistence integration" begin
    if isempty(pg_connection_string)
        @test_skip "set TIINGO_TEST_PG_CONNECTION to an isolated PostgreSQL database"
    else
        pg = connect_postgres(pg_connection_string; max_retries = 1)
        try
            server_version_num = only(_pg_integration_query(
                pg,
                "SELECT current_setting('server_version_num')::integer " *
                "AS server_version_num",
            ).server_version_num)
            @test 170_000 <= server_version_num < 180_000

            @testset "PostgreSQL migration fresh and finite legacy catalog" begin
                _pg_integration_cleanup(pg)
                @test postgres_schema_version(pg) == 0
                fresh_result = migrate_postgres!(pg)
                @test fresh_result.from_version == 0
                @test fresh_result.to_version == POSTGRES_SCHEMA_VERSION
                @test fresh_result.applied_versions == [1]
                @test postgres_schema_version(pg) == 1
                @test create_tables(pg) === nothing
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) AS count FROM " *
                    "public.tiingojulia_schema_migrations",
                ).count) == 1

                relation_names = [
                    "us_tickers",
                    "us_tickers_filtered",
                    "historical_data",
                ]
                for mask in 1:7
                    _pg_integration_cleanup(pg)
                    selected = [
                        relation_names[index] for index in eachindex(relation_names)
                        if !iszero(mask & (1 << (index - 1)))
                    ]
                    for name in selected
                        _pg_integration_create_v1_relation(pg, name)
                    end
                    @test postgres_schema_version(pg) == 0
                    result = migrate_postgres!(pg)
                    @test result.from_version == 0
                    @test result.to_version == 1
                    @test result.applied_versions == [1]
                    @test postgres_schema_version(pg) == 1
                    _pg_integration_assert_legacy_rows(pg, selected)
                    if "historical_data" in selected
                        key = _pg_integration_query(
                            pg,
                            """
                            SELECT a.attname, a.attnotnull
                            FROM pg_catalog.pg_attribute a
                            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                            WHERE n.nspname = 'public'
                              AND c.relname = 'historical_data'
                              AND a.attname IN ('ticker', 'date')
                            ORDER BY a.attname
                            """,
                        )
                        @test all(key.attnotnull)
                    end
                end

                _pg_integration_cleanup(pg)
                _pg_integration_create_v1_relation(pg, "historical_data")
                _pg_integration_create_current_preledger(pg)
                hybrid_before = _pg_integration_query(
                    pg,
                    "SELECT ticker, date, close, volume FROM public.historical_data",
                )
                @test migrate_postgres!(pg).applied_versions == [1]
                hybrid_after = _pg_integration_query(
                    pg,
                    "SELECT ticker, date, close, volume FROM public.historical_data",
                )
                @test hybrid_after == hybrid_before

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.historical_data " *
                    "(ticker, date, close) VALUES " *
                    "('CURRENT', DATE '2024-01-02', 88.0)",
                )
                @test migrate_postgres!(pg).applied_versions == [1]
                @test only(_pg_integration_query(
                    pg,
                    "SELECT close FROM public.historical_data " *
                    "WHERE ticker = 'CURRENT'",
                ).close) == 88.0

                _pg_integration_cleanup(pg)
                _pg_integration_create_compatibility_export(pg)
                unchanged_export_tables = (
                    "us_tickers_filtered",
                    "security_observations",
                    "fundamental_daily_metrics",
                )
                before_export = Dict(name => only(_pg_integration_query(
                    pg,
                    "SELECT md5(string_agg(to_jsonb(t)::text, '' " *
                    "ORDER BY to_jsonb(t)::text)) AS fingerprint " *
                    "FROM public.$name t",
                ).fingerprint) for name in unchanged_export_tables)
                historical_stable_sql = """
                    SELECT md5(string_agg(
                        to_jsonb(ROW(ticker, date, volume, adjvolume))::text,
                        '' ORDER BY ticker, date
                    )) AS fingerprint
                    FROM public.historical_data
                """
                historical_real_sql = """
                    SELECT close::REAL, high::REAL, low::REAL, open::REAL,
                           adjclose::REAL, adjhigh::REAL, adjlow::REAL,
                           adjopen::REAL, divcash::REAL, splitfactor::REAL
                    FROM public.historical_data
                    ORDER BY ticker, date
                """
                historical_stable_before = only(_pg_integration_query(
                    pg,
                    historical_stable_sql,
                ).fingerprint)
                historical_real_before = _pg_integration_query(pg, historical_real_sql)
                @test MigrationSchemaIntegration.classify_preledger_manifest(
                    MigrationSchemaIntegration.inspect_postgres_manifest(pg),
                ) == :first_party_compatibility_export
                @test migrate_postgres!(pg).applied_versions == [1]
                after_export = Dict(name => only(_pg_integration_query(
                    pg,
                    "SELECT md5(string_agg(to_jsonb(t)::text, '' " *
                    "ORDER BY to_jsonb(t)::text)) AS fingerprint " *
                    "FROM public.$name t",
                ).fingerprint) for name in unchanged_export_tables)
                @test after_export == before_export
                @test only(_pg_integration_query(
                    pg,
                    historical_stable_sql,
                ).fingerprint) == historical_stable_before
                @test _pg_integration_query(pg, historical_real_sql) ==
                      historical_real_before
                @test migrate_postgres!(pg).applied_versions == Int[]

                export_owner = "tiingo_test_export_owner"
                _pg_integration_cleanup(pg)
                _pg_integration_command(pg, "DROP ROLE IF EXISTS $export_owner")
                _pg_integration_command(pg, "CREATE ROLE $export_owner NOLOGIN")
                try
                    _pg_integration_command(
                        pg,
                        "GRANT CREATE ON SCHEMA public TO $export_owner",
                    )
                    _pg_integration_create_compatibility_export(pg)
                    for name in (
                        "historical_data",
                        unchanged_export_tables...,
                    )
                        _pg_integration_command(
                            pg,
                            "ALTER TABLE public.$name OWNER TO $export_owner",
                        )
                    end
                    @test_throws PostgresMigrationError migrate_postgres!(pg)
                    _pg_integration_command(pg, "SET ROLE $export_owner")
                    @test migrate_postgres!(pg).applied_versions == [1]
                    @test postgres_schema_version(pg) == 1
                finally
                    _pg_integration_command(pg, "RESET ROLE")
                    _pg_integration_cleanup(pg)
                    _pg_integration_command(
                        pg,
                        "REVOKE CREATE ON SCHEMA public FROM $export_owner",
                    )
                    _pg_integration_command(pg, "DROP ROLE IF EXISTS $export_owner")
                end

                deployed_owner = "tiingo_test_deployed_migrator"
                _pg_integration_cleanup(pg)
                _pg_integration_command(pg, "DROP ROLE IF EXISTS $deployed_owner")
                _pg_integration_command(pg, "CREATE ROLE $deployed_owner NOLOGIN")
                deployed_tables = (
                    "historical_data",
                    "us_tickers_filtered",
                    "security_observations",
                    "fundamental_daily_metrics",
                    "filtered_stocks",
                )
                try
                    _pg_integration_command(
                        pg,
                        "GRANT CREATE ON SCHEMA public TO $deployed_owner",
                    )
                    _pg_integration_create_deployed_export(pg)
                    for name in deployed_tables
                        _pg_integration_command(
                            pg,
                            "ALTER TABLE public.$name OWNER TO $deployed_owner",
                        )
                    end
                    @test_throws PostgresMigrationError migrate_postgres!(pg)
                    _pg_integration_command(pg, "SET ROLE $deployed_owner")
                    deployed_fingerprints = names -> Dict(
                        name => only(_pg_integration_query(
                            pg,
                            "SELECT md5(string_agg(to_jsonb(t)::text, '' " *
                            "ORDER BY to_jsonb(t)::text)) AS fingerprint " *
                            "FROM public.$name t",
                        ).fingerprint) for name in names
                    )
                    deployed_before = deployed_fingerprints(deployed_tables)
                    @test MigrationSchemaIntegration.classify_preledger_manifest(
                        MigrationSchemaIntegration.inspect_postgres_manifest(pg),
                    ) == :deployed_first_party_composition
                    deployed_result = migrate_postgres!(pg)
                    @test deployed_result.from_version == 0
                    @test deployed_result.to_version == 1
                    @test deployed_result.applied_versions == [1]
                    deployed_after = deployed_fingerprints(deployed_tables)
                    @test deployed_after == deployed_before
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT is_nullable FROM information_schema.columns " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'us_tickers_filtered' " *
                        "AND column_name = 'ticker'",
                    ).is_nullable) == "YES"
                    post_manifest =
                        MigrationSchemaIntegration.inspect_postgres_manifest(pg)
                    filtered_indexes = post_manifest.relations[
                        "us_tickers_filtered"
                    ].indexes
                    @test !any(index -> index.primary, filtered_indexes)
                    @test any(
                        index -> index.unique && !index.primary &&
                            index.columns == ("ticker",),
                        filtered_indexes,
                    )
                    read_deployed_fk = () -> NamedTuple(only(eachrow(
                        _pg_integration_query(pg, """
                        SELECT
                            fk.conname,
                            pg_get_constraintdef(fk.oid, false) AS definition,
                            fk.conindid::regclass::text AS referenced_index,
                            pg_get_userbyid(child.relowner) AS child_owner,
                            fk.convalidated
                        FROM pg_constraint fk
                        JOIN pg_class child ON child.oid = fk.conrelid
                        WHERE fk.conrelid = 'public.filtered_stocks'::regclass
                          AND fk.contype = 'f'
                        """)
                    )))
                    deployed_fk = read_deployed_fk()
                    @test deployed_fk.conname == "filtered_stocks_ticker_fkey"
                    @test deployed_fk.definition ==
                          "FOREIGN KEY (ticker) REFERENCES us_tickers_filtered(ticker) ON DELETE CASCADE"
                    @test deployed_fk.referenced_index ==
                          "tiingojulia_us_tickers_filtered_ticker_bridge"
                    @test deployed_fk.child_owner == deployed_owner
                    @test deployed_fk.convalidated
                    for columns in (("ticker",), ("assettype",), ("exchange",))
                        @test any(
                            index -> !index.unique && !index.primary &&
                                index.columns == columns,
                            filtered_indexes,
                        )
                    end

                    replacement_universe = DataFrame(
                        ticker = ["EXPORTED", "NEW"],
                        exchange = ["NYSE", "NASDAQ"],
                        asset_type = ["Stock", "Stock"],
                        price_currency = ["USD", "USD"],
                        start_date = fill(Date(2024, 1, 1), 2),
                        end_date = fill(Date(2024, 12, 31), 2),
                    )
                    replacement_filtered = replacement_universe[[1], :]
                    @test replace_ticker_universe(
                        pg,
                        replacement_universe,
                        replacement_filtered,
                    ) == (all_rows = 2, filtered_rows = 1)
                    @test _pg_integration_query(
                        pg,
                        "SELECT ticker FROM public.us_tickers ORDER BY ticker",
                    ).ticker == ["EXPORTED", "NEW"]
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT retained_value FROM public.filtered_stocks " *
                        "WHERE ticker = 'EXPORTED'",
                    ).retained_value) == 7
                    @test read_deployed_fk() == deployed_fk

                    atomic_tables = (
                        "us_tickers",
                        "us_tickers_filtered",
                        "filtered_stocks",
                    )
                    omitted_before = deployed_fingerprints(atomic_tables)
                    omitted_error = try
                        replace_ticker_universe(
                            pg,
                            replacement_universe[[2], :],
                            replacement_universe[[2], :],
                        )
                        nothing
                    catch error
                        error
                    end
                    @test omitted_error isa LibPQ.Errors.PQResultError
                    @test occursin(
                        "filtered_stocks_ticker_fkey",
                        sprint(showerror, omitted_error),
                    )
                    @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                    @test isequal(
                        deployed_fingerprints(atomic_tables),
                        omitted_before,
                    )
                    @test read_deployed_fk() == deployed_fk

                    _pg_integration_command(pg, """
                        CREATE TABLE public.tiingo_test_filtered_fk (
                            ticker VARCHAR,
                            CONSTRAINT tiingo_test_unknown_filtered_fkey
                              FOREIGN KEY (ticker)
                              REFERENCES public.us_tickers_filtered (ticker)
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.tiingo_test_filtered_fk " *
                        "VALUES ('EXPORTED')",
                    )
                    unknown_fk_tables = (atomic_tables..., "tiingo_test_filtered_fk")
                    unknown_fk_before = deployed_fingerprints(unknown_fk_tables)
                    unknown_dependency_error = try
                        replace_ticker_universe(
                            pg,
                            replacement_universe,
                            replacement_filtered,
                        )
                        nothing
                    catch error
                        error
                    end
                    @test unknown_dependency_error isa ArgumentError
                    @test occursin(
                        "tiingo_test_unknown_filtered_fkey",
                        sprint(showerror, unknown_dependency_error),
                    )
                    @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                    @test isequal(
                        deployed_fingerprints(unknown_fk_tables),
                        unknown_fk_before,
                    )
                    @test read_deployed_fk() == deployed_fk
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) FROM pg_constraint " *
                        "WHERE contype = 'f' AND confrelid = " *
                        "'public.us_tickers_filtered'::regclass",
                    ).count) == 2
                    _pg_integration_command(
                        pg,
                        "DROP TABLE public.tiingo_test_filtered_fk",
                    )

                    _pg_integration_command(pg, """
                        INSERT INTO public.us_tickers_filtered
                          (ticker, exchange, assettype)
                        VALUES ('EXPORTED', 'NYSE', 'Stock')
                        ON CONFLICT (ticker) DO UPDATE
                        SET exchange = EXCLUDED.exchange
                    """)
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT exchange FROM public.us_tickers_filtered " *
                        "WHERE ticker = 'EXPORTED'",
                    ).exchange) == "NYSE"
                    @test postgres_schema_version(pg) == 1
                    @test migrate_postgres!(pg).applied_versions == Int[]
                    _pg_integration_command(
                        pg,
                        "DELETE FROM public.us_tickers_filtered " *
                        "WHERE ticker = 'EXPORTED'",
                    )
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) FROM public.filtered_stocks " *
                        "WHERE ticker = 'EXPORTED'",
                    ).count) == 0

                    _pg_integration_command(pg, "RESET ROLE")
                    _pg_integration_cleanup(pg)
                    _pg_integration_create_deployed_export(
                        pg;
                        create_filtered_stocks=false,
                    )
                    for name in deployed_tables[1:4]
                        _pg_integration_command(
                            pg,
                            "ALTER TABLE public.$name OWNER TO $deployed_owner",
                        )
                    end
                    _pg_integration_command(pg, "SET ROLE $deployed_owner")
                    @test migrate_postgres!(pg).applied_versions == [1]
                    @test ismissing(only(_pg_integration_query(
                        pg,
                        "SELECT to_regclass('public.filtered_stocks') AS relation",
                    ).relation))
                    @test migrate_postgres!(pg).applied_versions == Int[]
                finally
                    _pg_integration_command(pg, "RESET ROLE")
                    _pg_integration_cleanup(pg)
                    _pg_integration_command(
                        pg,
                        "REVOKE CREATE ON SCHEMA public FROM $deployed_owner",
                    )
                    _pg_integration_command(
                        pg,
                        "DROP ROLE IF EXISTS $deployed_owner",
                    )
                end
            end

            @testset "PostgreSQL migration fail-closed ledger and rollback" begin
                _pg_integration_cleanup(pg)
                _pg_integration_create_deployed_export(pg)
                _pg_integration_command(
                    pg,
                    "UPDATE public.security_observations SET ticker = NULL",
                )
                _pg_integration_command(
                    pg,
                    "UPDATE public.fundamental_daily_metrics SET fetched_at = NULL",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test postgres_schema_version(pg) == 0
                @test only(_pg_integration_query(
                    pg,
                    "SELECT is_nullable FROM information_schema.columns " *
                    "WHERE table_schema = 'public' " *
                    "AND table_name = 'us_tickers_filtered' " *
                    "AND column_name = 'ticker'",
                ).is_nullable) == "NO"
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) FROM information_schema.table_constraints " *
                    "WHERE table_schema = 'public' " *
                    "AND table_name = 'us_tickers_filtered' " *
                    "AND constraint_type = 'PRIMARY KEY'",
                ).count) == 1
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT to_regclass(" *
                    "'public.tiingojulia_us_tickers_filtered_ticker_bridge'" *
                    ") AS relation",
                ).relation))

                _pg_integration_cleanup(pg)
                _pg_integration_create_deployed_export(
                    pg;
                    foreign_key_delete_action="NO ACTION",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test postgres_schema_version(pg) == 0
                wrong_action_fk = only(eachrow(_pg_integration_query(
                    pg,
                    """
                    SELECT pg_get_constraintdef(oid, false) AS definition,
                           conindid::regclass::text AS referenced_index
                    FROM pg_constraint
                    WHERE conname = 'filtered_stocks_ticker_fkey'
                    """,
                )))
                @test wrong_action_fk.definition ==
                      "FOREIGN KEY (ticker) REFERENCES us_tickers_filtered(ticker)"
                @test wrong_action_fk.referenced_index ==
                      "\"scheduler filtered ticker pkey\""

                _pg_integration_cleanup(pg)
                _pg_integration_create_deployed_export(
                    pg;
                    primary_key_name="arbitrary Scheduler PK name",
                )
                _pg_integration_command(pg, """
                    CREATE TABLE public.tiingo_test_filtered_fk (
                        ticker VARCHAR REFERENCES public.us_tickers_filtered (ticker)
                    )
                """)
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.tiingo_test_filtered_fk VALUES ('EXPORTED')",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test postgres_schema_version(pg) == 0
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) FROM information_schema.table_constraints " *
                    "WHERE table_schema = 'public' " *
                    "AND table_name = 'us_tickers_filtered' " *
                    "AND constraint_type = 'PRIMARY KEY'",
                ).count) == 1
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT to_regclass(" *
                    "'public.tiingojulia_us_tickers_filtered_ticker_bridge'" *
                    ") AS relation",
                ).relation))
                @test only(_pg_integration_query(
                    pg,
                    "SELECT ticker FROM public.tiingo_test_filtered_fk",
                ).ticker) == "EXPORTED"
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) FROM pg_constraint " *
                    "WHERE contype = 'f' AND confrelid = " *
                    "'public.us_tickers_filtered'::regclass",
                ).count) == 2
                @test only(_pg_integration_query(
                    pg,
                    "SELECT conindid::regclass::text AS referenced_index " *
                    "FROM pg_constraint " *
                    "WHERE conname = 'filtered_stocks_ticker_fkey'",
                ).referenced_index) == "\"arbitrary Scheduler PK name\""

                _pg_integration_cleanup(pg)
                _pg_integration_create_compatibility_export(pg)
                _pg_integration_command(
                    pg,
                    "UPDATE public.security_observations SET ticker = NULL",
                )
                _pg_integration_command(
                    pg,
                    "UPDATE public.fundamental_daily_metrics SET fetched_at = NULL",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test postgres_schema_version(pg) == 0
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT to_regclass('public.us_tickers') AS relation",
                ).relation))
                @test only(_pg_integration_query(
                    pg,
                    "SELECT data_type FROM information_schema.columns " *
                    "WHERE table_schema = 'public' " *
                    "AND table_name = 'historical_data' AND column_name = 'close'",
                ).data_type) == "real"
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT ticker FROM public.security_observations",
                ).ticker))
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT fetched_at FROM public.fundamental_daily_metrics",
                ).fetched_at))
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

                _pg_integration_cleanup(pg)
                _pg_integration_command(
                    pg,
                    "CREATE TABLE public.historical_data " *
                    "(ticker TEXT, payload JSONB)",
                )
                unknown_error = try
                    migrate_postgres!(pg)
                    nothing
                catch error
                    error
                end
                @test unknown_error isa PostgresMigrationError
                @test occursin("backup", lowercase(sprint(showerror, unknown_error)))
                @test postgres_schema_version(pg) == 0
                @test Set(_pg_integration_query(
                    pg,
                    """
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name = 'historical_data'
                    """,
                ).column_name) == Set(["ticker", "payload"])
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

                _pg_integration_cleanup(pg)
                _pg_integration_create_v1_relation(pg, "historical_data")
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.historical_data " *
                    "(ticker, date, close) VALUES " *
                    "(NULL, DATE '2020-01-03', 99.0)",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test postgres_schema_version(pg) == 0
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) AS count FROM public.historical_data",
                ).count) == 2
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT to_regclass('public.security_observations') AS relation",
                ).relation))
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                _pg_integration_command(
                    pg,
                    "UPDATE public.tiingojulia_schema_migrations " *
                    "SET checksum = repeat('0', 64) WHERE version = 1",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    """
                    CREATE TABLE public.tiingojulia_schema_migrations (
                        version INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        checksum TEXT NOT NULL,
                        applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        package_version TEXT NOT NULL
                    )
                    """,
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.tiingojulia_schema_migrations " *
                    "(version, name, checksum, package_version) VALUES " *
                    "(2, 'future', repeat('f', 64), '9.0.0')",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            end

            @testset "PostgreSQL migration rejects spoofed security metadata" begin
                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.historical_data ENABLE ROW LEVEL SECURITY",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT pg_catalog.to_regclass(" *
                    "'public.tiingojulia_schema_migrations') AS relation",
                ).relation))
                @test only(_pg_integration_query(
                    pg,
                    "SELECT relrowsecurity FROM pg_catalog.pg_class c " *
                    "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace " *
                    "WHERE n.nspname = 'public' AND c.relname = 'historical_data'",
                ).relrowsecurity)

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "CREATE FUNCTION public.tiingo_test_trigger() RETURNS trigger " *
                    "LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'",
                )
                _pg_integration_command(
                    pg,
                    "CREATE TRIGGER tiingo_test_unexpected BEFORE INSERT ON " *
                    "public.us_tickers FOR EACH ROW EXECUTE FUNCTION " *
                    "public.tiingo_test_trigger()",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT pg_catalog.to_regclass(" *
                    "'public.tiingojulia_schema_migrations') AS relation",
                ).relation))
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) FROM pg_catalog.pg_trigger t " *
                    "JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid " *
                    "WHERE c.relname = 'us_tickers' AND NOT t.tgisinternal",
                ).count) == 1
                _pg_integration_command(
                    pg,
                    "DROP FUNCTION public.tiingo_test_trigger() CASCADE",
                )

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                try
                    _pg_integration_command(pg, "SET allow_system_table_mods = on")
                    _pg_integration_command(
                        pg,
                        "UPDATE pg_catalog.pg_index SET indisvalid = false " *
                        "WHERE indexrelid = " *
                        "'public.idx_us_tickers_ticker'::pg_catalog.regclass",
                    )
                    @test_throws PostgresMigrationError migrate_postgres!(pg)
                    @test ismissing(only(_pg_integration_query(
                        pg,
                        "SELECT pg_catalog.to_regclass(" *
                        "'public.tiingojulia_schema_migrations') AS relation",
                    ).relation))
                    @test !only(_pg_integration_query(
                        pg,
                        "SELECT indisvalid FROM pg_catalog.pg_index " *
                        "WHERE indexrelid = " *
                        "'public.idx_us_tickers_ticker'::pg_catalog.regclass",
                    ).indisvalid)
                finally
                    _pg_integration_command(pg, "SET allow_system_table_mods = off")
                end

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.us_tickers SET UNLOGGED",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT pg_catalog.to_regclass(" *
                    "'public.tiingojulia_schema_migrations') AS relation",
                ).relation))

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.us_tickers " *
                    "ALTER COLUMN ticker SET DEFAULT 'SPOOF'",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "DROP INDEX public.idx_us_tickers_ticker",
                )
                _pg_integration_command(
                    pg,
                    "CREATE INDEX idx_us_tickers_ticker ON public.us_tickers " *
                    "(ticker varchar_pattern_ops)",
                )
                @test_throws PostgresMigrationError migrate_postgres!(pg)

                foreign_owner = "tiingo_test_foreign_owner"
                _pg_integration_cleanup(pg)
                _pg_integration_command(pg, "DROP ROLE IF EXISTS $foreign_owner")
                _pg_integration_command(pg, "CREATE ROLE $foreign_owner NOLOGIN")
                try
                    _pg_integration_create_current_preledger(pg)
                    _pg_integration_command(
                        pg,
                        "ALTER TABLE public.us_tickers OWNER TO $foreign_owner",
                    )
                    @test_throws PostgresMigrationError migrate_postgres!(pg)
                finally
                    _pg_integration_cleanup(pg)
                    _pg_integration_command(pg, "DROP ROLE IF EXISTS $foreign_owner")
                end

                _pg_integration_cleanup(pg)
                _pg_integration_create_current_preledger(pg)
                _pg_integration_command(
                    pg,
                    "CREATE VIEW public.tiingojulia_schema_migrations AS " *
                    "SELECT 1::integer AS version, " *
                    "'canonical_v1_baseline'::text AS name, " *
                    "'$(MigrationSchemaIntegration.POSTGRES_MIGRATIONS[1].checksum)'::text " *
                    "AS checksum, CURRENT_TIMESTAMP AS applied_at, " *
                    "'1.1.0'::text AS package_version",
                )
                @test_throws PostgresMigrationError postgres_schema_version(pg)
                @test_throws PostgresMigrationError migrate_postgres!(pg)
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                _pg_integration_command(
                    pg,
                    "DROP VIEW public.tiingojulia_schema_migrations",
                )

                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.tiingojulia_schema_migrations " *
                    "DROP CONSTRAINT tiingojulia_schema_migrations_version_check",
                )
                @test_throws PostgresMigrationError postgres_schema_version(pg)
                @test_throws PostgresMigrationError migrate_postgres!(pg)

                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.tiingojulia_schema_migrations " *
                    "ALTER COLUMN applied_at SET DEFAULT pg_catalog.clock_timestamp()",
                )
                @test_throws PostgresMigrationError postgres_schema_version(pg)

                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                _pg_integration_command(
                    pg,
                    "ALTER TABLE public.tiingojulia_schema_migrations SET UNLOGGED",
                )
                @test_throws PostgresMigrationError postgres_schema_version(pg)

                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                _pg_integration_command(
                    pg,
                    "CREATE INDEX tiingo_test_ledger_extra ON " *
                    "public.tiingojulia_schema_migrations (name)",
                )
                @test_throws PostgresMigrationError postgres_schema_version(pg)

                _pg_integration_cleanup(pg)
                _pg_integration_command(pg, "DROP ROLE IF EXISTS $foreign_owner")
                _pg_integration_command(pg, "CREATE ROLE $foreign_owner NOLOGIN")
                try
                    migrate_postgres!(pg)
                    _pg_integration_command(
                        pg,
                        "ALTER TABLE public.tiingojulia_schema_migrations " *
                        "OWNER TO $foreign_owner",
                    )
                    @test_throws PostgresMigrationError postgres_schema_version(pg)
                    @test_throws PostgresMigrationError migrate_postgres!(pg)
                finally
                    _pg_integration_cleanup(pg)
                    _pg_integration_command(pg, "DROP ROLE IF EXISTS $foreign_owner")
                end
            end

            @testset "PostgreSQL migration ignores hostile search-path functions" begin
                _pg_integration_cleanup(pg)
                hostile_schema = "tiingo_test_migration_shadow"
                _pg_integration_command(
                    pg,
                    "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                )
                _pg_integration_command(pg, "CREATE SCHEMA $hostile_schema")
                try
                    _pg_integration_command(
                        pg,
                        "CREATE TABLE $hostile_schema.calls (name TEXT)",
                    )
                    _pg_integration_command(
                        pg,
                        "CREATE FUNCTION $hostile_schema.to_regclass(text) " *
                        "RETURNS regclass LANGUAGE plpgsql AS 'BEGIN INSERT INTO " *
                        "$hostile_schema.calls VALUES (''to_regclass''); " *
                        "RETURN NULL; END'",
                    )
                    _pg_integration_command(
                        pg,
                        "CREATE FUNCTION $hostile_schema.set_config(text, text, boolean) " *
                        "RETURNS text LANGUAGE plpgsql AS 'BEGIN INSERT INTO " *
                        "$hostile_schema.calls VALUES (''set_config''); " *
                        "RETURN \$2; END'",
                    )
                    _pg_integration_command(
                        pg,
                        "CREATE FUNCTION $hostile_schema.pg_advisory_xact_lock(" *
                        "integer, integer) RETURNS void LANGUAGE plpgsql AS " *
                        "'BEGIN INSERT INTO $hostile_schema.calls VALUES " *
                        "(''advisory''); END'",
                    )
                    hostile_path = "$hostile_schema, pg_catalog, public"
                    _pg_integration_command(pg, "SET search_path TO $hostile_path")
                    @test postgres_schema_version(pg) == 0
                    @test migrate_postgres!(pg).applied_versions == [1]
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) FROM $hostile_schema.calls",
                    ).count) == 0
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT pg_catalog.current_setting('search_path') AS path",
                    ).path) == hostile_path
                finally
                    _pg_integration_command(pg, "SET search_path TO public")
                    _pg_integration_command(
                        pg,
                        "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                    )
                end
            end

            @testset "PostgreSQL migration advisory lock contention" begin
                _pg_integration_cleanup(pg)
                second = connect_postgres(pg_connection_string; max_retries=1)
                try
                    _pg_integration_command(pg, "BEGIN")
                    _pg_integration_command(
                        pg,
                        "SELECT pg_advisory_xact_lock(1414089038, 1)",
                    )
                    lock_error = try
                        migrate_postgres!(second; lock_timeout_seconds=1)
                        nothing
                    catch error
                        error
                    end
                    @test lock_error isa PostgresMigrationError
                    @test LibPQ.transaction_status(second) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    @test postgres_schema_version(second) == 0
                    _pg_integration_command(pg, "COMMIT")
                    @test migrate_postgres!(second).applied_versions == [1]
                    @test postgres_schema_version(second) == 1
                finally
                    if LibPQ.transaction_status(pg) != LibPQ.libpq_c.PQTRANS_IDLE
                        _pg_integration_command(pg, "ROLLBACK")
                    end
                    close_postgres(second)
                end
            end

            _pg_integration_cleanup(pg)
            create_tables(pg)

            expected_tables = Set([
                "fundamental_daily_metrics",
                "historical_data",
                "security_observations",
                "us_tickers",
                "us_tickers_filtered",
            ])
            created_tables = _pg_integration_query(
                pg,
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                """,
            )
            @test expected_tables ⊆ Set(String.(created_tables.table_name))

            all_universe = DataFrame(
                ticker = ["AAPL", "SPY"],
                exchange = ["NASDAQ", "NYSE ARCA"],
                asset_type = ["Stock", "ETF"],
                price_currency = ["USD", "USD"],
                start_date = [Date(1980, 12, 12), Date(1993, 1, 22)],
                end_date = fill(Date(2026, 7, 25), 2),
            )
            filtered_universe = all_universe[[1], :]
            @test replace_ticker_universe(
                pg,
                all_universe,
                filtered_universe,
            ) == (all_rows = 2, filtered_rows = 1)

            prices = DataFrame(
                date = [Date(2024, 1, 2), Date(2024, 1, 3)],
                close = Union{Missing,Float64}[missing, 101.0],
                high = Union{Missing,Float64}[missing, 102.0],
                low = Union{Missing,Float64}[missing, 99.0],
                open = Union{Missing,Float64}[missing, 100.0],
                volume = Union{Missing,Int64}[missing, 1_000],
                adjClose = Union{Missing,Float64}[missing, 101.0],
                adjHigh = Union{Missing,Float64}[missing, 102.0],
                adjLow = Union{Missing,Float64}[missing, 99.0],
                adjOpen = Union{Missing,Float64}[missing, 100.0],
                adjVolume = Union{Missing,Int64}[missing, 1_000],
                divCash = Union{Missing,Float64}[missing, 0.0],
                splitFactor = Union{Missing,Float64}[missing, 1.0],
            )
            @test upsert_stock_data_bulk(pg, prices, "AAPL") == 2

            stored_prices = _pg_integration_query(
                pg,
                """
                SELECT date, close, volume, splitfactor
                FROM historical_data
                WHERE ticker = 'AAPL'
                ORDER BY date
                """,
            )
            @test nrow(stored_prices) == 2
            @test isnan(stored_prices.close[1])
            @test stored_prices.volume[1] == 0
            @test stored_prices.splitfactor[1] == 1.0

            updated_prices = copy(prices)
            updated_prices.close[2] = 202.5
            @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT close FROM historical_data WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            ).close) == 202.5

            duplicate_prices = prices[[2, 2], :]
            duplicate_prices.close = [900.0, 901.0]
            @test_throws Exception upsert_stock_data_bulk(pg, duplicate_prices, "AAPL")
            @test only(_pg_integration_query(
                pg,
                "SELECT close FROM historical_data WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            ).close) == 202.5

            observed_at = DateTime(2026, 7, 25, 12)
            observations = DataFrame(
                perma_ticker = ["perm-aapl"],
                observed_at = [observed_at],
                ticker = ["AAPL"],
                is_active = [true],
                is_adr = Union{Missing,Bool}[missing],
                daily_last_updated = Union{Missing,DateTime}[missing],
                exchange = Union{Missing,String}["NASDAQ"],
                asset_type = Union{Missing,String}["Stock"],
                price_coverage_start = Union{Missing,Date}[Date(1980, 12, 12)],
                price_coverage_end = Union{Missing,Date}[Date(2026, 7, 25)],
                is_leveraged = Union{Missing,Bool}[missing],
                join_status = ["matched"],
            )
            @test upsert_security_observations(pg, observations) == 1

            metrics = DataFrame(
                perma_ticker = ["perm-aapl"],
                metric_date = [Date(2024, 1, 3)],
                market_cap = Union{Missing,Float64}[3.0e12],
                enterprise_value = Union{Missing,Float64}[missing],
                pe_ratio = Union{Missing,Float64}[25.0],
                available_at = Union{Missing,DateTime}[missing],
                fetched_at = [observed_at],
                source_revision = Union{Missing,String}[missing],
            )
            @test upsert_fundamental_daily_metrics(pg, metrics) == 1
            stored_metrics = _pg_integration_query(
                pg,
                "SELECT market_cap, enterprise_value, pe_ratio FROM fundamental_daily_metrics",
            )
            @test only(stored_metrics.market_cap) == 3.0e12
            @test ismissing(only(stored_metrics.enterprise_value))
            @test only(stored_metrics.pe_ratio) == 25.0

            duplicate_metrics = metrics[[1, 1], :]
            duplicate_error = try
                upsert_fundamental_daily_metrics(pg, duplicate_metrics)
                nothing
            catch error
                error
            end
            @test duplicate_error isa ArgumentError
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM fundamental_daily_metrics",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "CREATE UNIQUE INDEX tiingo_test_us_tickers_ticker_key " *
                "ON us_tickers (ticker)",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE historical_data ADD CONSTRAINT " *
                "tiingo_test_historical_ticker_fk FOREIGN KEY (ticker) " *
                "REFERENCES us_tickers (ticker)",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE security_observations ADD CONSTRAINT " *
                "tiingo_test_security_ticker_fk FOREIGN KEY (ticker) " *
                "REFERENCES us_tickers (ticker)",
            )

            replacement_universe = all_universe[[2], :]
            replace_error = try
                replace_ticker_universe(
                    pg,
                    replacement_universe,
                    replacement_universe,
                )
                nothing
            catch error
                error
            end
            @test replace_error isa Exception
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            @test _pg_integration_query(
                pg,
                "SELECT ticker FROM us_tickers ORDER BY ticker",
            ).ticker == ["AAPL", "SPY"]
            @test _pg_integration_query(
                pg,
                "SELECT ticker FROM us_tickers_filtered ORDER BY ticker",
            ).ticker == ["AAPL"]
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM historical_data WHERE ticker = 'AAPL'",
            ).row_count) == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM security_observations WHERE ticker = 'AAPL'",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "ALTER TABLE historical_data DROP CONSTRAINT " *
                "tiingo_test_historical_ticker_fk",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE security_observations DROP CONSTRAINT " *
                "tiingo_test_security_ticker_fk",
            )
            _pg_integration_command(
                pg,
                "DROP INDEX tiingo_test_us_tickers_ticker_key",
            )

            @test replace_ticker_universe(
                pg,
                replacement_universe,
                replacement_universe,
            ) == (all_rows = 1, filtered_rows = 1)
            replaced_all = _pg_integration_query(
                pg,
                "SELECT ticker, assettype FROM us_tickers",
            )
            replaced_filtered = _pg_integration_query(
                pg,
                "SELECT ticker, assettype FROM us_tickers_filtered",
            )
            @test replaced_all.ticker == ["SPY"]
            @test replaced_all.assettype == ["ETF"]
            @test replaced_filtered.ticker == ["SPY"]
            @test replaced_filtered.assettype == ["ETF"]
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM historical_data WHERE ticker = 'AAPL'",
            ).row_count) == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM security_observations WHERE ticker = 'AAPL'",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_first (id BIGINT, generation TEXT)",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_first VALUES (1, 'old-first')",
            )
            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_second (id BIGINT UNIQUE, generation TEXT)",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_second VALUES (1, 'old-second')",
            )
            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_child (source_id BIGINT REFERENCES legacy_atomic_second(id))",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_child VALUES (1)",
            )
            stages_before = _pg_integration_query(
                pg,
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name LIKE '_tiingo_stage_%'
                ORDER BY table_name
                """,
            ).table_name

            legacy_source = DBInterface.connect(DuckDB.DB)
            try
                DBInterface.execute(
                    legacy_source,
                    "CREATE TABLE legacy_atomic_first (id BIGINT, generation VARCHAR)",
                )
                DBInterface.execute(
                    legacy_source,
                    "INSERT INTO legacy_atomic_first VALUES (1, 'new-first')",
                )
                DBInterface.execute(
                    legacy_source,
                    "CREATE TABLE legacy_atomic_second (id BIGINT, generation VARCHAR)",
                )
                DBInterface.execute(
                    legacy_source,
                    "INSERT INTO legacy_atomic_second VALUES (1, 'new-second')",
                )

                @test_throws Exception export_to_postgres(
                    legacy_source,
                    pg,
                    ["legacy_atomic_first", "legacy_atomic_second"];
                    use_dataframe=true,
                    max_retries=1,
                    retry_delay=0,
                )
            finally
                DBInterface.close!(legacy_source)
            end

            @test only(_pg_integration_query(
                pg,
                "SELECT generation FROM legacy_atomic_first",
            ).generation) == "old-first"
            @test only(_pg_integration_query(
                pg,
                "SELECT generation FROM legacy_atomic_second",
            ).generation) == "old-second"
            @test _pg_integration_query(
                pg,
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE '_tiingo_stage_%' ORDER BY table_name",
            ).table_name == stages_before
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

            mktempdir() do directory
                destination = joinpath(directory, "historical_data.parquet")
                result = write_parquet(pg, "historical_data", destination)
                @test result.rows == 2
                @test result.columns == 14
                restored = _pg_integration_read_parquet(destination)
                @test restored.ticker == ["AAPL", "AAPL"]
                @test restored.close[2] == 202.5
            end

            hostile_schema = "tiingo_test_hostile_path"
            _pg_integration_command(
                pg,
                "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
            )
            _pg_integration_command(pg, "CREATE SCHEMA $hostile_schema")
            try
                for table in (
                    "us_tickers",
                    "us_tickers_filtered",
                    "historical_data",
                    "security_observations",
                    "fundamental_daily_metrics",
                )
                    _pg_integration_command(
                        pg,
                        "CREATE TABLE $hostile_schema.$table " *
                        "(LIKE public.$table INCLUDING ALL)",
                    )
                end
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.us_tickers " *
                    "(ticker) VALUES ('HOSTILE')",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.us_tickers_filtered " *
                    "(ticker) VALUES ('HOSTILE')",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.historical_data " *
                    "(ticker, date) VALUES ('HOSTILE', DATE '2000-01-01')",
                )
                _pg_integration_command(
                    pg,
                    "CREATE TABLE $hostile_schema.hostile_publish_probe " *
                    "(id BIGINT, generation TEXT)",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.hostile_publish_probe " *
                    "VALUES (1, 'hostile-sentinel')",
                )
                _pg_integration_command(
                    pg,
                    "SET search_path TO $hostile_schema, public",
                )

                create_tables(pg)
                @test replace_ticker_universe(
                    pg,
                    all_universe,
                    filtered_universe,
                ) == (all_rows=2, filtered_rows=1)
                @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2

                hostile_source = DBInterface.connect(DuckDB.DB)
                try
                    DBInterface.execute(
                        hostile_source,
                        "CREATE TABLE hostile_publish_probe " *
                        "(id BIGINT, generation VARCHAR)",
                    )
                    DBInterface.execute(
                        hostile_source,
                        "INSERT INTO hostile_publish_probe " *
                        "VALUES (1, 'public-generation')",
                    )
                    export_to_postgres(
                        hostile_source,
                        pg,
                        ["hostile_publish_probe"];
                        use_dataframe=true,
                        max_retries=1,
                        retry_delay=0,
                    )
                finally
                    DBInterface.close!(hostile_source)
                end

                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM public.us_tickers ORDER BY ticker",
                ).ticker == ["AAPL", "SPY"]
                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM $hostile_schema.us_tickers",
                ).ticker == ["HOSTILE"]
                @test only(_pg_integration_query(
                    pg,
                    "SELECT generation FROM public.hostile_publish_probe",
                ).generation) == "public-generation"
                @test only(_pg_integration_query(
                    pg,
                    "SELECT generation FROM " *
                    "$hostile_schema.hostile_publish_probe",
                ).generation) == "hostile-sentinel"
            finally
                _pg_integration_command(pg, "SET search_path TO public")
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.hostile_publish_probe CASCADE",
                )
                _pg_integration_command(
                    pg,
                    "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                )
            end
        finally
            try
                _pg_integration_cleanup(pg)
            finally
                close_postgres(pg)
            end
        end
    end
end
