using Test
using DataFrames
using Dates
using DBInterface
using DuckDB
using LibPQ
using QuansiftMarketData

const MigrationSchemaIntegration = QuansiftMarketData.DB.Schema
const PostgresIntegration = QuansiftMarketData.DB.Postgres

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
    for statement in MigrationSchemaIntegration.POSTGRES_V2_TARGET_DDL
        _pg_integration_command(conn, statement)
    end
    for statement in MigrationSchemaIntegration.POSTGRES_V2_TARGET_INDEX_DDL
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
        create_query = MigrationSchemaIntegration.generate_create_table_query(
            name,
            schemas[name],
        )
        if name == "security_observations"
            create_query = replace(
                create_query,
                "PRIMARY KEY (\"perma_ticker\", \"observed_at\", " *
                "\"ticker\", \"is_active\")" =>
                    "PRIMARY KEY (\"perma_ticker\", \"observed_at\")",
            )
        end
        _pg_integration_command(
            conn,
            create_query,
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

@testset "FK replacement missing-key query supports composite keys" begin
    @test PostgresIntegration.generate_missing_primary_keys_query(
        "target_table",
        "stage_table",
        ["ticker", "date"],
    ) == "SELECT EXISTS (SELECT \"ticker\", \"date\" FROM " *
         "\"public\".\"target_table\" EXCEPT SELECT \"ticker\", \"date\" FROM " *
         "\"public\".\"stage_table\") AS missing_primary_keys"
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

            @testset "Migration readiness reports without migrating" begin
                _pg_integration_cleanup(pg)
                ledger_relation() = only(_pg_integration_query(
                    pg,
                    "SELECT pg_catalog.to_regclass(" *
                    "'public.tiingojulia_schema_migrations') AS relation",
                ).relation)

                # A fresh database is migratable and says so without being
                # touched — the ledger must not be created as a side effect.
                fresh = postgres_migration_readiness(pg)
                @test fresh.state === :migration_required
                @test fresh.migratable
                @test !fresh.ready
                @test fresh.from_version == 0
                @test fresh.target_version == POSTGRES_SCHEMA_VERSION
                @test ismissing(ledger_relation())

                migrate_postgres!(pg)
                current = postgres_migration_readiness(pg)
                @test current.state === :ready
                @test current.ready
                @test current.migratable
                @test current.from_version == POSTGRES_SCHEMA_VERSION
                @test isempty(current.drift)

                # Drift is named, not merely detected. This is the shape the
                # data plane was in on 2026-08-19.
                _pg_integration_command(pg, """
                    ALTER TABLE "public"."security_observations"
                    ALTER COLUMN join_status DROP NOT NULL
                """)
                drifted = postgres_migration_readiness(pg)
                @test drifted.state === :drift
                @test !drifted.ready
                @test !drifted.migratable
                @test any(
                    finding -> finding.relation == "security_observations" &&
                        finding.subject == "join_status",
                    drifted.drift,
                )
                # migrate_postgres! must still refuse, and its message must
                # carry the same subject the readiness report did.
                refusal = try
                    migrate_postgres!(pg)
                    nothing
                catch caught
                    caught
                end
                @test refusal isa PostgresMigrationError
                @test occursin("join_status", sprint(showerror, refusal))

                _pg_integration_command(pg, """
                    ALTER TABLE "public"."security_observations"
                    ALTER COLUMN join_status SET NOT NULL
                """)
                @test postgres_migration_readiness(pg).state === :ready

                # An older build reading a newer ledger is a distinct state.
                behind = postgres_migration_readiness(pg; target_version=1)
                @test behind.state === :newer_schema
                @test !behind.migratable
            end

            @testset "PostgreSQL migration fresh and finite legacy catalog" begin
                _pg_integration_cleanup(pg)
                @test postgres_schema_version(pg) == 0
                fresh_result = migrate_postgres!(pg)
                @test fresh_result.from_version == 0
                @test fresh_result.to_version == POSTGRES_SCHEMA_VERSION
                @test fresh_result.applied_versions == [1, 2, 3]
                @test postgres_schema_version(pg) == 3
                @test create_tables(pg) === nothing
                @test only(_pg_integration_query(
                    pg,
                    "SELECT count(*) AS count FROM " *
                    "public.tiingojulia_schema_migrations",
                ).count) == 3

                _pg_integration_cleanup(pg)
                v1_result = migrate_postgres!(pg; target_version=1)
                @test v1_result.applied_versions == [1]
                @test postgres_schema_version(pg) == 1
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.historical_data " *
                    "(ticker, date, close) VALUES " *
                    "('LEGACY', DATE '2024-01-02', 42.0)",
                )
                v2_result = migrate_postgres!(pg)
                @test v2_result.from_version == 1
                @test v2_result.to_version == 3
                @test v2_result.applied_versions == [2, 3]
                migrated_eod = _pg_integration_query(
                    pg,
                    "SELECT fetched_at FROM public.historical_data " *
                    "WHERE ticker = 'LEGACY'",
                )
                @test only(migrated_eod.fetched_at) == DateTime(1970, 1, 1)
                @test only(_pg_integration_query(
                    pg,
                    "SELECT is_nullable FROM information_schema.columns " *
                    "WHERE table_schema = 'public' " *
                    "AND table_name = 'historical_data' " *
                    "AND column_name = 'fetched_at'",
                ).is_nullable) == "NO"
                @test migrate_postgres!(pg).applied_versions == Int[]

                _pg_integration_cleanup(pg)
                @test migrate_postgres!(pg; target_version=2).applied_versions == [1, 2]
                _pg_integration_command(
                    pg,
                    "ALTER INDEX public.uq_security_observations_key " *
                    "RENAME TO renamed_security_observations_key",
                )
                renamed_result = migrate_postgres!(pg)
                @test renamed_result.from_version == 2
                @test renamed_result.applied_versions == [3]
                @test postgres_schema_version(pg) == 3

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
                    @test result.to_version == 3
                    @test result.applied_versions == [1, 2, 3]
                    @test postgres_schema_version(pg) == 3
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
                @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
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
                @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
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
                @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
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
                    @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
                    @test postgres_schema_version(pg) == 3
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
                            "SELECT md5(string_agg(" *
                            (name == "historical_data" ?
                                "(to_jsonb(t) - 'fetched_at')::text" :
                                "to_jsonb(t)::text") *
                            ", '' ORDER BY " *
                            (name == "historical_data" ?
                                "(to_jsonb(t) - 'fetched_at')::text" :
                                "to_jsonb(t)::text") *
                            ")) AS fingerprint " *
                            "FROM public.$name t",
                        ).fingerprint) for name in names
                    )
                    deployed_before = deployed_fingerprints(deployed_tables)
                    @test MigrationSchemaIntegration.classify_preledger_manifest(
                        MigrationSchemaIntegration.inspect_postgres_manifest(pg),
                    ) == :deployed_first_party_composition
                    deployed_result = migrate_postgres!(pg)
                    @test deployed_result.from_version == 0
                    @test deployed_result.to_version == 3
                    @test deployed_result.applied_versions == [1, 2, 3]
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
                    @test postgres_schema_version(pg) == 3
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
                    @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
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
                    @test migrate_postgres!(pg).applied_versions == [1, 2, 3]
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
                    @test migrate_postgres!(second).applied_versions == [1, 2, 3]
                    @test postgres_schema_version(second) == 3
                finally
                    if LibPQ.transaction_status(pg) != LibPQ.libpq_c.PQTRANS_IDLE
                        _pg_integration_command(pg, "ROLLBACK")
                    end
                    close_postgres(second)
                end
            end

            @testset "PostgreSQL EOD migration bounds v2 work" begin
                _pg_integration_cleanup(pg)
                @test migrate_postgres!(pg; target_version=1).applied_versions == [1]
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.historical_data " *
                    "(ticker, date, close) VALUES " *
                    "('SLOW', DATE '2024-01-02', 42.0)",
                )
                blocker = connect_postgres(pg_connection_string; max_retries=1)
                try
                    _pg_integration_command(blocker, "BEGIN")
                    _pg_integration_query(
                        blocker,
                        "SELECT ticker FROM public.historical_data",
                    )
                    timeout_error = try
                        migrate_postgres!(
                            pg;
                            lock_timeout_seconds=30,
                            statement_timeout_seconds=1,
                        )
                        nothing
                    catch error
                        error
                    end
                    @test timeout_error isa PostgresMigrationError
                    @test occursin(
                        "statement timeout",
                        lowercase(isnothing(timeout_error) ? "" :
                                  sprint(showerror, timeout_error)),
                    )
                    @test LibPQ.transaction_status(pg) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    @test postgres_schema_version(pg) == 1
                    @test isempty(_pg_integration_query(
                        pg,
                        "SELECT column_name FROM information_schema.columns " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'historical_data' " *
                        "AND column_name = 'fetched_at'",
                    ))
                    preserved = _pg_integration_query(
                        pg,
                        "SELECT ticker, date, close FROM public.historical_data",
                    )
                    @test preserved.ticker == ["SLOW"]
                    @test preserved.date == [Date(2024, 1, 2)]
                    @test preserved.close == [42.0]
                finally
                    try
                        _pg_integration_command(blocker, "ROLLBACK")
                    catch
                    end
                    close_postgres(blocker)
                end
            end

            _pg_integration_cleanup(pg)
            create_tables(pg)

            @testset "PostgreSQL EOD raw default is UTC naive" begin
                try
                    _pg_integration_command(
                        pg,
                        "SET TIME ZONE 'America/Los_Angeles'",
                    )
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.historical_data (ticker, date) " *
                        "VALUES ('TZDEFAULT', DATE '2024-01-01')",
                    )
                    utc_delta = only(_pg_integration_query(
                        pg,
                        "SELECT abs(extract(epoch FROM " *
                        "((CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - fetched_at))) " *
                        "AS seconds FROM public.historical_data " *
                        "WHERE ticker = 'TZDEFAULT'",
                    ).seconds)
                    @test utc_delta < 5
                finally
                    _pg_integration_command(pg, "SET TIME ZONE 'UTC'")
                    _pg_integration_command(
                        pg,
                        "DELETE FROM public.historical_data " *
                        "WHERE ticker = 'TZDEFAULT'",
                    )
                end
            end

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

            @testset "create_or_replace_table rolls back the full replacement" begin
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.atomic_replace_probe_backup",
                )
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.atomic_replace_probe",
                )
                _pg_integration_command(
                    pg,
                    "CREATE TABLE public.atomic_replace_probe " *
                    "(id INTEGER PRIMARY KEY, note TEXT)",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO public.atomic_replace_probe " *
                    "VALUES (1, 'original')",
                )
                replacement_error = try
                    create_or_replace_table(
                        pg,
                        "atomic_replace_probe",
                        "CREATE TABLE public.atomic_replace_probe (broken INVALID_TYPE)",
                    )
                    nothing
                catch error
                    error
                end
                @test replacement_error isa Exception
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                @test _pg_integration_query(
                    pg,
                    "SELECT id, note FROM public.atomic_replace_probe",
                ) == DataFrame(id=[1], note=["original"])
                @test ismissing(only(_pg_integration_query(
                    pg,
                    "SELECT to_regclass('public.atomic_replace_probe_backup') AS relation",
                ).relation))
                @test isnothing(create_or_replace_table(
                    pg,
                    "atomic_replace_probe",
                    "CREATE TABLE public.atomic_replace_probe " *
                    "(id INTEGER PRIMARY KEY, note TEXT, generation INTEGER)",
                ))
                @test nrow(_pg_integration_query(
                    pg,
                    "SELECT * FROM public.atomic_replace_probe",
                )) == 0
                @test _pg_integration_query(
                    pg,
                    "SELECT id, note FROM public.atomic_replace_probe_backup",
                ) == DataFrame(id=[1], note=["original"])
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.atomic_replace_probe",
                )
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.atomic_replace_probe_backup",
                )
            end

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

            universe_before_rejection = Dict(
                table => _pg_integration_query(
                    pg,
                    "SELECT * FROM public.$table ORDER BY ticker, exchange",
                )
                for table in ("us_tickers", "us_tickers_filtered")
            )
            for (empty_all, empty_filtered, label) in (
                (all_universe[1:0, :], filtered_universe, "all"),
                (all_universe, filtered_universe[1:0, :], "filtered"),
            )
                empty_error = try
                    replace_ticker_universe(pg, empty_all, empty_filtered)
                    nothing
                catch error
                    error
                end
                @test empty_error isa ArgumentError
                @test occursin(
                    "$label ticker universe must not be empty",
                    isnothing(empty_error) ? "" : sprint(showerror, empty_error),
                )
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                for table in keys(universe_before_rejection)
                    @test isequal(
                        _pg_integration_query(
                            pg,
                            "SELECT * FROM public.$table ORDER BY ticker, exchange",
                        ),
                        universe_before_rejection[table],
                    )
                end
            end

            # The supported-tickers feed lists the same symbol under several
            # exchanges, so repeated tickers are the universe's normal state
            # rather than corruption.
            duplicated_all = vcat(
                all_universe,
                transform(
                    all_universe[[1], :],
                    :exchange => (_ -> ["NYSE"]) => :exchange,
                ),
            )
            duplicated_filtered = vcat(
                filtered_universe,
                transform(
                    filtered_universe[[1], :],
                    :exchange => (_ -> ["NYSE"]) => :exchange,
                ),
            )
            @test replace_ticker_universe(
                pg,
                duplicated_all,
                duplicated_filtered,
            ) == (all_rows = 3, filtered_rows = 2)
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

            inconsistent_universes = (
                (
                    all_universe,
                    transform(filtered_universe, :ticker => (_ -> ["MSFT"]) => :ticker),
                    "filtered ticker universe contains keys absent from all ticker universe",
                ),
            )
            for (invalid_all, invalid_filtered, expected_message) in
                inconsistent_universes
                @test replace_ticker_universe(
                    pg,
                    all_universe,
                    filtered_universe,
                ) == (all_rows = 2, filtered_rows = 1)
                invalid_before = Dict(
                    table => _pg_integration_query(
                        pg,
                        "SELECT * FROM public.$table ORDER BY ticker, exchange",
                    )
                    for table in ("us_tickers", "us_tickers_filtered")
                )

                invalid_error = try
                    replace_ticker_universe(pg, invalid_all, invalid_filtered)
                    nothing
                catch error
                    error
                end
                @test invalid_error isa ArgumentError
                @test occursin(
                    expected_message,
                    isnothing(invalid_error) ? "" : sprint(showerror, invalid_error),
                )
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                for table in keys(invalid_before)
                    @test isequal(
                        _pg_integration_query(
                            pg,
                            "SELECT * FROM public.$table ORDER BY ticker, exchange",
                        ),
                        invalid_before[table],
                    )
                end
            end

            @test_throws ArgumentError replace_ticker_universe(
                pg,
                all_universe,
                filtered_universe;
                statement_timeout_seconds=0,
            )
            @test_throws ArgumentError replace_ticker_universe(
                pg,
                all_universe,
                filtered_universe;
                lock_timeout_seconds=-1,
            )
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

            _pg_integration_command(pg, """
                CREATE FUNCTION public.slow_universe_insert()
                RETURNS trigger LANGUAGE plpgsql AS \$\$
                BEGIN
                    PERFORM pg_catalog.pg_sleep(2);
                    RETURN NEW;
                END
                \$\$
            """)
            _pg_integration_command(pg, """
                CREATE TRIGGER slow_universe_insert
                BEFORE INSERT ON public.us_tickers
                FOR EACH ROW EXECUTE FUNCTION public.slow_universe_insert()
            """)
            universe_before_timeout = Dict(
                table => _pg_integration_query(
                    pg,
                    "SELECT * FROM public.$table ORDER BY ticker, exchange",
                )
                for table in ("us_tickers", "us_tickers_filtered")
            )
            try
                elapsed_seconds = @elapsed timeout_error = try
                    replace_ticker_universe(
                        pg,
                        all_universe,
                        filtered_universe;
                        lock_timeout_seconds=10,
                        statement_timeout_seconds=1,
                    )
                    nothing
                catch error
                    error
                end
                @test timeout_error !== nothing
                @test occursin(
                    "statement timeout",
                    lowercase(sprint(showerror, timeout_error)),
                ) || occursin(
                    "canceling statement",
                    lowercase(sprint(showerror, timeout_error)),
                )
                @test elapsed_seconds < 10
                @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
                @test only(_pg_integration_query(
                    pg,
                    "SELECT current_setting('lock_timeout') AS value",
                ).value) == "0"
                @test only(_pg_integration_query(
                    pg,
                    "SELECT current_setting('statement_timeout') AS value",
                ).value) == "0"
                for table in keys(universe_before_timeout)
                    @test isequal(
                        _pg_integration_query(
                            pg,
                            "SELECT * FROM public.$table ORDER BY ticker, exchange",
                        ),
                        universe_before_timeout[table],
                    )
                end
            finally
                _pg_integration_command(
                    pg,
                    "DROP TRIGGER IF EXISTS slow_universe_insert " *
                    "ON public.us_tickers",
                )
                _pg_integration_command(
                    pg,
                    "DROP FUNCTION IF EXISTS public.slow_universe_insert()",
                )
            end

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
            missing_provenance_error = try
                upsert_stock_data_bulk(pg, prices, "AAPL")
                nothing
            catch error
                error
            end
            @test missing_provenance_error isa ArgumentError
            @test occursin(
                "fetched_at",
                isnothing(missing_provenance_error) ? "" :
                    sprint(showerror, missing_provenance_error),
            )
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS count FROM public.historical_data " *
                "WHERE ticker = 'AAPL'",
            ).count) == 0

            initial_price_fetched_at = DateTime(2030, 1, 1)
            prices.fetched_at = fill(initial_price_fetched_at, nrow(prices))
            @test upsert_stock_data_bulk(pg, prices, "AAPL") == 2

            stored_prices = _pg_integration_query(
                pg,
                """
                SELECT date, close, volume, splitfactor, fetched_at
                FROM historical_data
                WHERE ticker = 'AAPL'
                ORDER BY date
                """,
            )
            @test nrow(stored_prices) == 2
            @test isnan(stored_prices.close[1])
            @test stored_prices.volume[1] == 0
            @test stored_prices.splitfactor[1] == 1.0
            @test all(.!ismissing.(stored_prices.fetched_at))

            updated_prices = copy(prices)
            updated_prices.close[2] = 202.5
            updated_prices.fetched_at .= initial_price_fetched_at
            @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT close FROM historical_data WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            ).close) == 202.5

            stale_prices = copy(updated_prices)
            stale_prices.close[2] = 50.0
            stale_prices.fetched_at .= DateTime(2029, 12, 31, 23, 59)
            @test upsert_stock_data_bulk(pg, stale_prices, "AAPL") == 0
            preserved_price = _pg_integration_query(
                pg,
                "SELECT close, fetched_at FROM historical_data " *
                "WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            )
            @test only(preserved_price.close) == 202.5
            @test only(preserved_price.fetched_at) == initial_price_fetched_at

            duplicate_prices = prices[[2, 2], :]
            duplicate_prices.close = [900.0, 901.0]
            duplicate_prices.fetched_at = fill(DateTime(2031, 1, 1), 2)
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

            state_observations = vcat(observations, observations)
            state_observations.is_active = [true, false]
            state_observations.join_status = ["matched", "inactive"]
            @test upsert_security_observations(pg, state_observations) == 2

            duplicate_observations = vcat(observations, observations)
            observation_error = try
                upsert_security_observations(pg, duplicate_observations)
                nothing
            catch error
                error
            end
            @test observation_error isa ArgumentError
            @test occursin(
                "duplicate persistence key",
                isnothing(observation_error) ? "" :
                lowercase(sprint(showerror, observation_error)),
            )
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            @test _pg_integration_query(
                pg,
                "SELECT is_active FROM public.security_observations " *
                "ORDER BY is_active DESC",
            ).is_active == [true, false]

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

            equal_timestamp_metrics = copy(metrics)
            equal_timestamp_metrics.market_cap[1] = 3.1e12
            equal_timestamp_metrics.source_revision[1] = "rev-equal"
            @test upsert_fundamental_daily_metrics(pg, equal_timestamp_metrics) == 1

            stale_metrics = copy(equal_timestamp_metrics)
            stale_metrics.market_cap[1] = 2.0e12
            stale_metrics.fetched_at[1] = observed_at - Minute(1)
            stale_metrics.source_revision[1] = "rev-stale"
            @test upsert_fundamental_daily_metrics(pg, stale_metrics) == 0

            preserved_metrics = _pg_integration_query(
                pg,
                "SELECT market_cap, fetched_at, source_revision " *
                "FROM fundamental_daily_metrics WHERE perma_ticker = 'perm-aapl' " *
                "AND metric_date = DATE '2024-01-03'",
            )
            @test only(preserved_metrics.market_cap) == 3.1e12
            @test only(preserved_metrics.fetched_at) == observed_at
            @test only(preserved_metrics.source_revision) == "rev-equal"

            string_guard_error = try
                PostgresIntegration.transactional_upsert!(
                    pg,
                    "fundamental_daily_metrics",
                    metrics,
                    [:perma_ticker, :metric_date],
                    Symbol.(names(metrics)[3:end]);
                    update_guard_column="fetched_at",
                )
                nothing
            catch error
                error
            end
            @test string_guard_error isa TypeError
            @test occursin(
                "keyword argument update_guard_column",
                isnothing(string_guard_error) ? "" :
                sprint(showerror, string_guard_error),
            )
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            rejected_guard_state = _pg_integration_query(
                pg,
                "SELECT market_cap, source_revision " *
                "FROM fundamental_daily_metrics " *
                "WHERE perma_ticker = 'perm-aapl' " *
                "AND metric_date = DATE '2024-01-03'",
            )
            @test only(rejected_guard_state.market_cap) == 3.1e12
            @test only(rejected_guard_state.source_revision) == "rev-equal"

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
            @test replace_error isa ArgumentError
            replace_error_text = isnothing(replace_error) ? "" :
                                 sprint(showerror, replace_error)
            @test occursin(
                "unsupported foreign-key dependencies",
                replace_error_text,
            )
            @test occursin(
                "tiingo_test_historical_ticker_fk",
                replace_error_text,
            )
            @test occursin(
                "tiingo_test_security_ticker_fk",
                replace_error_text,
            )
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
            ).row_count) == 2

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
            ).row_count) == 2

            mktempdir() do directory
                destination = joinpath(directory, "historical_data.parquet")
                result = write_parquet(pg, "historical_data", destination)
                @test result.rows == 2
                @test result.columns == 15
                restored = _pg_integration_read_parquet(destination)
                @test restored.ticker == ["AAPL", "AAPL"]
                @test restored.close[2] == 202.5
            end

            @testset "PostgreSQL Parquet snapshot supports SELECT-only roles" begin
                reader_role = "tiingo_parquet_reader"
                reader_password = "parquet-reader-password"
                reader_role_exists = only(_pg_integration_query(
                    pg,
                    "SELECT EXISTS (SELECT 1 FROM pg_roles " *
                    "WHERE rolname = '$reader_role') AS present",
                ).present)
                if reader_role_exists
                    _pg_integration_command(pg, "DROP OWNED BY $reader_role")
                    _pg_integration_command(pg, "DROP ROLE $reader_role")
                end
                _pg_integration_command(
                    pg,
                    "CREATE ROLE $reader_role LOGIN PASSWORD '$reader_password'",
                )
                reader = nothing
                try
                    _pg_integration_command(
                        pg,
                        "GRANT USAGE ON SCHEMA public TO $reader_role",
                    )
                    _pg_integration_command(
                        pg,
                        "GRANT SELECT ON public.historical_data TO $reader_role",
                    )
                    reader_options = PostgresIntegration.connection_options_map(
                        pg_connection_string,
                    )
                    reader_options["user"] = reader_role
                    reader_options["password"] = reader_password
                    reader = connect_postgres(
                        PostgresIntegration.build_postgres_connection_string(
                            reader_options,
                        );
                        max_retries=1,
                    )

                    mktempdir() do directory
                        destination = joinpath(directory, "reader.parquet")
                        result = write_parquet(
                            reader,
                            "historical_data",
                            destination,
                        )
                        @test result.rows == 2
                        @test _pg_integration_read_parquet(destination).ticker ==
                              ["AAPL", "AAPL"]
                    end
                    @test LibPQ.transaction_status(reader) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                finally
                    !isnothing(reader) && close_postgres(reader)
                    _pg_integration_command(pg, "DROP OWNED BY $reader_role")
                    _pg_integration_command(pg, "DROP ROLE $reader_role")
                end
            end

            @testset "PostgreSQL Parquet snapshot is stable behind a writer" begin
                writer = connect_postgres(pg_connection_string; max_retries=1)
                try
                    _pg_integration_command(writer, "BEGIN")
                    _pg_integration_command(
                        writer,
                        "INSERT INTO public.historical_data " *
                        "(ticker, date, close) VALUES " *
                        "('LOCKED', DATE '2024-01-04', 1.0)",
                    )
                    mktempdir() do directory
                        destination = joinpath(directory, "blocked.parquet")
                        result = write_parquet(
                            pg,
                            "historical_data",
                            destination,
                        )
                        @test result.rows == 2
                        restored = _pg_integration_read_parquet(destination)
                        @test restored.ticker == ["AAPL", "AAPL"]
                        @test "LOCKED" ∉ restored.ticker
                        @test LibPQ.transaction_status(pg) ==
                              LibPQ.libpq_c.PQTRANS_IDLE
                    end
                finally
                    try
                        _pg_integration_command(writer, "ROLLBACK")
                    catch
                    end
                    close_postgres(writer)
                end
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
                    "SET search_path TO $hostile_schema, public",
                )

                create_tables(pg)
                @test replace_ticker_universe(
                    pg,
                    all_universe,
                    filtered_universe,
                ) == (all_rows=2, filtered_rows=1)
                @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2

                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM public.us_tickers ORDER BY ticker",
                ).ticker == ["AAPL", "SPY"]
                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM $hostile_schema.us_tickers",
                ).ticker == ["HOSTILE"]
            finally
                _pg_integration_command(pg, "SET search_path TO public")
                _pg_integration_command(
                    pg,
                    "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                )
            end
            @testset "Upserts bound their lock wait instead of hanging" begin
                # Without a lock timeout the nightly upsert blocks forever
                # behind any conflicting lock — a reader holding the table, an
                # abandoned session — and the cron run stalls with no error
                # and nothing to page on. A silent stall is worse than a
                # crash, so the wait has to be bounded and loud.
                _pg_integration_cleanup(pg)
                migrate_postgres!(pg)
                create_tables(pg)

                blocker = connect_postgres(pg_connection_string; max_retries = 1)
                try
                    _pg_integration_command(blocker, "BEGIN")
                    _pg_integration_command(
                        blocker,
                        "LOCK TABLE public.historical_data IN ACCESS EXCLUSIVE MODE",
                    )

                    frame = DataFrame(
                        ticker = ["AAPL"],
                        date = [Date(2024, 1, 2)],
                        close = [1.0],
                    )
                    elapsed_seconds = @elapsed caught = try
                        PostgresIntegration.transactional_upsert!(
                            pg,
                            "historical_data",
                            frame,
                            [:ticker, :date],
                            [:close];
                            lock_timeout_seconds = 1,
                        )
                        nothing
                    catch error
                        error
                    end

                    @test caught !== nothing
                    @test occursin(
                        "lock timeout",
                        lowercase(sprint(showerror, caught)),
                    )
                    @test elapsed_seconds < 30
                    # The failure must leave a usable, idle connection, and
                    # the timeout must not outlive its transaction.
                    @test LibPQ.transaction_status(pg) ==
                        LibPQ.libpq_c.PQTRANS_IDLE
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT current_setting('lock_timeout') AS value",
                    ).value) == "0"
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT current_setting('statement_timeout') AS value",
                    ).value) == "0"
                finally
                    try
                        _pg_integration_command(blocker, "ROLLBACK")
                    finally
                        close_postgres(blocker)
                    end
                end

                # With the lock released the same upsert succeeds, so the
                # timeout bounds the wait without weakening the write.
                @test PostgresIntegration.transactional_upsert!(
                    pg,
                    "historical_data",
                    DataFrame(
                        ticker = ["AAPL"],
                        date = [Date(2024, 1, 2)],
                        close = [1.0],
                    ),
                    [:ticker, :date],
                    [:close];
                    lock_timeout_seconds = 1,
                ) == 1

                @test_throws ArgumentError PostgresIntegration.transactional_upsert!(
                    pg,
                    "historical_data",
                    DataFrame(
                        ticker = ["AAPL"],
                        date = [Date(2024, 1, 2)],
                        close = [1.0],
                    ),
                    [:ticker, :date],
                    [:close];
                    lock_timeout_seconds = -1,
                )
            end

            @testset "FK-referenced targets publish by upsert, not drop" begin
                # `publish_postgres_table!` probes for the target's existence
                # before deciding between in-place upsert and drop+rename. The
                # probe used to be wrapped in a swallowing catch, so a
                # transient catalog failure routed an FK-referenced table
                # straight to the branch that destroys its dependents. This
                # pins the surviving behaviour.
                _pg_integration_cleanup(pg)
                for table in (
                    "fk_publish_child",
                    "fk_publish_stage",
                    "fk_publish_parent",
                )
                    _pg_integration_command(
                        pg,
                        "DROP TABLE IF EXISTS public.$table CASCADE",
                    )
                end

                try
                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_parent (
                            ticker VARCHAR PRIMARY KEY,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_parent " *
                        "VALUES ('AAPL', 'original')",
                    )
                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_child (
                            ticker VARCHAR
                                REFERENCES public.fk_publish_parent (ticker)
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_child VALUES ('AAPL')",
                    )
                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_stage (
                            ticker VARCHAR,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_stage VALUES " *
                        "('AAPL', 'refreshed'), ('MSFT', 'new')",
                    )

                    fk_reader = connect_postgres(
                        pg_connection_string;
                        max_retries = 1,
                    )
                    try
                        _pg_integration_command(fk_reader, "BEGIN")
                        @test _pg_integration_query(
                            fk_reader,
                            "SELECT ticker FROM public.fk_publish_parent",
                        ).ticker == ["AAPL"]
                        PostgresIntegration.replace_postgres_table!(
                            pg,
                            "FK_PUBLISH_PARENT",
                            "FK_PUBLISH_STAGE",
                        )
                    finally
                        try
                            _pg_integration_command(fk_reader, "ROLLBACK")
                        catch
                        end
                        close_postgres(fk_reader)
                    end

                    # The dependent row survives, so the parent was refreshed
                    # in place rather than dropped and recreated.
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) AS count FROM public.fk_publish_child",
                    ).count) == 1
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) AS count FROM pg_constraint " *
                        "WHERE contype = 'f' AND confrelid = " *
                        "'public.fk_publish_parent'::regclass",
                    ).count) == 1
                    @test _pg_integration_query(
                        pg,
                        "SELECT ticker, note FROM public.fk_publish_parent " *
                        "ORDER BY ticker",
                    ).note == ["refreshed", "new"]
                    @test isempty(_pg_integration_query(
                        pg,
                        "SELECT 1 FROM information_schema.tables " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'fk_publish_stage'",
                    ))

                    _pg_integration_command(
                        pg,
                        "DELETE FROM public.fk_publish_parent " *
                        "WHERE ticker = 'MSFT'",
                    )
                    _pg_integration_command(
                        pg,
                        "UPDATE public.fk_publish_parent SET note = 'original' " *
                        "WHERE ticker = 'AAPL'",
                    )
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_parent " *
                        "VALUES ('OLD', 'legacy')",
                    )
                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_stage (
                            ticker VARCHAR,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_stage VALUES " *
                        "('AAPL', 'refreshed'), ('MSFT', 'new')",
                    )

                    missing_key_error = try
                        PostgresIntegration.replace_postgres_table!(
                            pg,
                            "fk_publish_parent",
                            "fk_publish_stage",
                        )
                        nothing
                    catch error
                        error
                    end

                    @test missing_key_error isa ArgumentError
                    @test occursin(
                        "absent from staging",
                        isnothing(missing_key_error) ? "" :
                        sprint(showerror, missing_key_error),
                    )
                    @test LibPQ.transaction_status(pg) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    preserved_parent = _pg_integration_query(
                        pg,
                        "SELECT ticker, note FROM public.fk_publish_parent " *
                        "ORDER BY ticker",
                    )
                    @test collect(zip(
                        preserved_parent.ticker,
                        preserved_parent.note,
                    )) == [("AAPL", "original"), ("OLD", "legacy")]
                    @test _pg_integration_query(
                        pg,
                        "SELECT ticker FROM public.fk_publish_child",
                    ).ticker == ["AAPL"]
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) AS count FROM pg_constraint " *
                        "WHERE contype = 'f' AND confrelid = " *
                        "'public.fk_publish_parent'::regclass",
                    ).count) == 1
                    stage_exists = !isempty(_pg_integration_query(
                        pg,
                        "SELECT 1 FROM information_schema.tables " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'fk_publish_stage'",
                    ))
                    @test !stage_exists

                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_stage (
                            ticker VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_stage VALUES " *
                        "('AAPL'), ('OLD')",
                    )

                    missing_column_error = try
                        PostgresIntegration.replace_postgres_table!(
                            pg,
                            "fk_publish_parent",
                            "fk_publish_stage",
                        )
                        nothing
                    catch error
                        error
                    end

                    @test missing_column_error isa ArgumentError
                    @test occursin(
                        "missing target columns",
                        isnothing(missing_column_error) ? "" :
                        sprint(showerror, missing_column_error),
                    )
                    @test occursin(
                        "note",
                        isnothing(missing_column_error) ? "" :
                        sprint(showerror, missing_column_error),
                    )
                    @test LibPQ.transaction_status(pg) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    preserved_columns_parent = _pg_integration_query(
                        pg,
                        "SELECT ticker, note " *
                        "FROM public.fk_publish_parent ORDER BY ticker",
                    )
                    @test collect(zip(
                        preserved_columns_parent.ticker,
                        preserved_columns_parent.note,
                    )) == [("AAPL", "original"), ("OLD", "legacy")]
                    @test _pg_integration_query(
                        pg,
                        "SELECT ticker FROM public.fk_publish_child",
                    ).ticker == ["AAPL"]
                    @test only(_pg_integration_query(
                        pg,
                        "SELECT count(*) AS count FROM pg_constraint " *
                        "WHERE contype = 'f' AND confrelid = " *
                        "'public.fk_publish_parent'::regclass",
                    ).count) == 1
                    @test isempty(_pg_integration_query(
                        pg,
                        "SELECT 1 FROM information_schema.tables " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'fk_publish_stage'",
                    ))

                    _pg_integration_command(pg, """
                        CREATE TABLE public.fk_publish_stage (
                            ticker VARCHAR,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.fk_publish_stage VALUES " *
                        "('AAPL', 'refreshed'), ('OLD', 'legacy'), " *
                        "('MSFT', 'new')",
                    )

                    blocker = connect_postgres(
                        pg_connection_string;
                        max_retries = 1,
                    )
                    try
                        _pg_integration_command(blocker, "BEGIN")
                        _pg_integration_command(
                            blocker,
                            "UPDATE public.fk_publish_parent " *
                            "SET note = 'blocked' WHERE ticker = 'AAPL'",
                        )
                        _pg_integration_command(
                            pg,
                            "SET lock_timeout = '750ms'",
                        )

                        lock_error = try
                            PostgresIntegration.replace_postgres_table!(
                                pg,
                                "fk_publish_parent",
                                "fk_publish_stage",
                            )
                            nothing
                        catch error
                            error
                        end
                        lock_error_text = isnothing(lock_error) ? "" :
                                          lowercase(sprint(showerror, lock_error))

                        @test lock_error isa Exception
                        @test occursin("could not obtain lock", lock_error_text)
                        @test !occursin("lock timeout", lock_error_text)
                        @test LibPQ.transaction_status(pg) ==
                              LibPQ.libpq_c.PQTRANS_IDLE
                        locked_parent = _pg_integration_query(
                            pg,
                            "SELECT ticker, note " *
                            "FROM public.fk_publish_parent ORDER BY ticker",
                        )
                        @test collect(zip(
                            locked_parent.ticker,
                            locked_parent.note,
                        )) == [("AAPL", "original"), ("OLD", "legacy")]
                        @test _pg_integration_query(
                            pg,
                            "SELECT ticker FROM public.fk_publish_child",
                        ).ticker == ["AAPL"]
                        @test only(_pg_integration_query(
                            pg,
                            "SELECT count(*) AS count FROM pg_constraint " *
                            "WHERE contype = 'f' AND confrelid = " *
                            "'public.fk_publish_parent'::regclass",
                        ).count) == 1
                        @test isempty(_pg_integration_query(
                            pg,
                            "SELECT 1 FROM information_schema.tables " *
                            "WHERE table_schema = 'public' " *
                            "AND table_name = 'fk_publish_stage'",
                        ))
                    finally
                        try
                            _pg_integration_command(pg, "SET lock_timeout = '0'")
                        catch
                        end
                        try
                            _pg_integration_command(blocker, "ROLLBACK")
                        catch
                        end
                        close_postgres(blocker)
                    end
                finally
                    for table in (
                        "fk_publish_child",
                        "fk_publish_stage",
                        "fk_publish_parent",
                    )
                        _pg_integration_command(
                            pg,
                            "DROP TABLE IF EXISTS public.$table CASCADE",
                        )
                    end
                end
            end

            @testset "absent replacement publishes by direct rename" begin
                for table in ("replace_race_stage", "replace_race_target")
                    _pg_integration_command(
                        pg,
                        "DROP TABLE IF EXISTS public.$table CASCADE",
                    )
                end
                try
                    _pg_integration_command(pg, """
                        CREATE TABLE public.replace_race_stage (
                            ticker VARCHAR PRIMARY KEY,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.replace_race_stage " *
                        "VALUES ('STAGE', 'staged')",
                    )
                    PostgresIntegration.replace_postgres_table!(
                        pg,
                        "replace_race_target",
                        "replace_race_stage",
                    )

                    @test LibPQ.transaction_status(pg) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    renamed_target = _pg_integration_query(
                        pg,
                        "SELECT ticker, note " *
                        "FROM public.replace_race_target",
                    )
                    @test collect(zip(
                        renamed_target.ticker,
                        renamed_target.note,
                    )) == [("STAGE", "staged")]
                    @test isempty(_pg_integration_query(
                        pg,
                        "SELECT 1 FROM information_schema.tables " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'replace_race_stage'",
                    ))
                finally
                    for table in ("replace_race_stage", "replace_race_target")
                        _pg_integration_command(
                            pg,
                            "DROP TABLE IF EXISTS public.$table CASCADE",
                        )
                    end
                end
            end

            @testset "non-FK replacement fails fast behind a reader" begin
                for table in ("replace_reader_stage", "replace_reader_target")
                    _pg_integration_command(
                        pg,
                        "DROP TABLE IF EXISTS public.$table CASCADE",
                    )
                end
                reader = connect_postgres(
                    pg_connection_string;
                    max_retries = 1,
                )
                try
                    _pg_integration_command(pg, """
                        CREATE TABLE public.replace_reader_target (
                            ticker VARCHAR PRIMARY KEY,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.replace_reader_target " *
                        "VALUES ('ORIGINAL', 'preserved')",
                    )
                    _pg_integration_command(pg, """
                        CREATE TABLE public.replace_reader_stage (
                            ticker VARCHAR PRIMARY KEY,
                            note VARCHAR
                        )
                    """)
                    _pg_integration_command(
                        pg,
                        "INSERT INTO public.replace_reader_stage " *
                        "VALUES ('STAGE', 'replacement')",
                    )
                    _pg_integration_command(reader, "BEGIN")
                    @test _pg_integration_query(
                        reader,
                        "SELECT ticker FROM public.replace_reader_target",
                    ).ticker == ["ORIGINAL"]
                    _pg_integration_command(pg, "SET lock_timeout = '750ms'")

                    reader_error = try
                        PostgresIntegration.replace_postgres_table!(
                            pg,
                            "replace_reader_target",
                            "replace_reader_stage",
                        )
                        nothing
                    catch error
                        error
                    end
                    reader_error_text = isnothing(reader_error) ? "" :
                                        lowercase(sprint(showerror, reader_error))

                    @test reader_error isa Exception
                    @test occursin("could not obtain lock", reader_error_text)
                    @test !occursin("lock timeout", reader_error_text)
                    @test LibPQ.transaction_status(pg) ==
                          LibPQ.libpq_c.PQTRANS_IDLE
                    preserved_reader_target = _pg_integration_query(
                        pg,
                        "SELECT ticker, note " *
                        "FROM public.replace_reader_target",
                    )
                    @test collect(zip(
                        preserved_reader_target.ticker,
                        preserved_reader_target.note,
                    )) == [("ORIGINAL", "preserved")]
                    @test isempty(_pg_integration_query(
                        pg,
                        "SELECT 1 FROM information_schema.tables " *
                        "WHERE table_schema = 'public' " *
                        "AND table_name = 'replace_reader_stage'",
                    ))
                finally
                    try
                        _pg_integration_command(pg, "SET lock_timeout = '0'")
                    catch
                    end
                    try
                        _pg_integration_command(reader, "ROLLBACK")
                    catch
                    end
                    close_postgres(reader)
                    for table in ("replace_reader_stage", "replace_reader_target")
                        _pg_integration_command(
                            pg,
                            "DROP TABLE IF EXISTS public.$table CASCADE",
                        )
                    end
                end
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
