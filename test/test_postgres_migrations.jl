using Test
using LibPQ
using QuansiftMarketData

const MigrationSchema = QuansiftMarketData.DB.Schema

@testset "PostgreSQL migration public contract" begin
    @test POSTGRES_SCHEMA_VERSION == 2
    @test hasmethod(postgres_schema_version, Tuple{LibPQ.Connection})
    @test hasmethod(migrate_postgres!, Tuple{LibPQ.Connection})
    @test fieldnames(PostgresMigrationResult) ==
          (:from_version, :to_version, :applied_versions)
    @test PostgresMigrationError <: Exception

    @test_throws ArgumentError MigrationSchema.validate_migration_options(0, 30)
    @test_throws ArgumentError MigrationSchema.validate_migration_options(3, 30)
    @test_throws ArgumentError MigrationSchema.validate_migration_options(1, -1)
    @test_throws ArgumentError MigrationSchema.validate_migration_options(1, 30, -1)
    @test MigrationSchema.validate_migration_options(1, 0) === nothing
    @test MigrationSchema.validate_migration_options(2, 0, 0) === nothing

    method = which(migrate_postgres!, Tuple{LibPQ.Connection})
    @test Base.kwarg_decl(method) == [
        :target_version,
        :lock_timeout_seconds,
        :statement_timeout_seconds,
    ]
end

@testset "PostgreSQL migration registry is immutable and contiguous" begin
    migrations = MigrationSchema.POSTGRES_MIGRATIONS
    @test collect(map(migration -> migration.version, migrations)) ==
          collect(1:POSTGRES_SCHEMA_VERSION)
    @test all(migration -> !isempty(migration.name), migrations)
    @test all(migration -> length(migration.checksum) == 64, migrations)
    @test all(migration ->
        migration.checksum == MigrationSchema.migration_checksum(
            migration.version,
            migration.name,
            migration.definition,
        ), migrations)
    @test migrations[1].checksum ==
          "52d1a3e4d45fc923e748b8e80901a3d66bf98750d9f20c63feb286218da71750"
    @test occursin("ADD COLUMN fetched_at TIMESTAMP", migrations[2].definition)
    @test occursin("ALTER COLUMN fetched_at SET NOT NULL", migrations[2].definition)
    @test occursin(
        "CURRENT_TIMESTAMP AT TIME ZONE 'UTC'",
        migrations[2].definition,
    )
    @test occursin(
        "CURRENT_TIMESTAMP AT TIME ZONE 'UTC'",
        MigrationSchema.POSTGRES_TARGET_DDL[3],
    )
    @test :fetched_at ∉ Symbol.(getproperty.(
        MigrationSchema.POSTGRES_V1_TARGET_MANIFEST.relations["historical_data"].columns,
        :name,
    ))
    @test last(
        MigrationSchema.POSTGRES_TARGET_MANIFEST.relations["historical_data"].columns,
    ) == MigrationSchema.PostgresColumnManifest(
        "fetched_at", :timestamp, false, :none, :none, true,
    )
end

@testset "PostgreSQL catalog type and index normalization" begin
    @test MigrationSchema.normalize_postgres_type("character varying") == :varchar
    @test MigrationSchema.normalize_postgres_type("varchar(64)") == :varchar
    @test MigrationSchema.normalize_postgres_type("double precision") == :float8
    @test MigrationSchema.normalize_postgres_type("timestamp without time zone") ==
          :timestamp
    @test MigrationSchema.normalize_postgres_type("timestamp with time zone") ==
          :timestamptz
    @test_throws ArgumentError MigrationSchema.normalize_postgres_type("jsonb")

    index = MigrationSchema.PostgresIndexManifest(
        ("ticker", "date"),
        true,
        false,
        false,
        false,
    )
    @test MigrationSchema.semantic_index_key(index) ==
          (true, false, ("ticker", "date"))

    expected_relation = deepcopy(
        MigrationSchema.POSTGRES_TARGET_MANIFEST.relations["historical_data"],
    )
    invalid_relation = deepcopy(expected_relation)
    existing_index = invalid_relation.indexes[1]
    invalid_relation.indexes[1] = MigrationSchema.PostgresIndexManifest(
        existing_index.columns,
        existing_index.unique,
        existing_index.primary,
        existing_index.partial,
        existing_index.expression,
        false,
        true,
    )
    @test !MigrationSchema._relation_matches(invalid_relation, expected_relation)
end

@testset "PostgreSQL finite pre-ledger catalog" begin
    @test Set(keys(MigrationSchema.POSTGRES_LEGACY_CATALOG)) == Set([
        :fresh,
        :released_1_0_export,
        :first_party_compatibility_export,
        :deployed_first_party_composition,
        :released_1_0_plus_preledger_bootstrap,
        :current_1_1_preledger,
        :current_1_2_preledger,
    ])

    @test MigrationSchema.classify_preledger_manifest(
        MigrationSchema.PostgresDatabaseManifest(),
    ) == :fresh

    released = MigrationSchema.manifest_subset(
        MigrationSchema.POSTGRES_V1_0_MANIFEST,
        ["historical_data", "us_tickers_filtered"],
    )
    @test MigrationSchema.classify_preledger_manifest(released) ==
          :released_1_0_export

    @test MigrationSchema.classify_preledger_manifest(
        MigrationSchema.POSTGRES_TARGET_MANIFEST,
    ) == :current_1_2_preledger
    @test MigrationSchema.classify_preledger_manifest(
        MigrationSchema.POSTGRES_V1_TARGET_MANIFEST,
    ) == :current_1_1_preledger

    compatibility_export = deepcopy(
        MigrationSchema.POSTGRES_COMPATIBILITY_EXPORT_MANIFEST,
    )
    @test MigrationSchema.classify_preledger_manifest(compatibility_export) ==
          :first_party_compatibility_export
    @test compatibility_export.relations["historical_data"].columns[3].data_type ==
          :float4
    @test compatibility_export.relations["security_observations"].columns[3].nullable
    @test compatibility_export.relations["fundamental_daily_metrics"].columns[7].nullable

    deployed_export = deepcopy(MigrationSchema.POSTGRES_DEPLOYED_EXPORT_MANIFEST)
    @test MigrationSchema.classify_preledger_manifest(deployed_export) ==
          :deployed_first_party_composition
    @test deployed_export.relations["historical_data"].columns[3].data_type ==
          :float8
    @test !deployed_export.relations["us_tickers_filtered"].columns[1].nullable
    @test Set(MigrationSchema.semantic_index_key.(
        deployed_export.relations["us_tickers_filtered"].indexes,
    )) == Set([
        (true, true, ("ticker",)),
        (false, false, ("assettype",)),
        (false, false, ("exchange",)),
    ])

    for near_miss in (
        let manifest = deepcopy(deployed_export)
            manifest.relations["us_tickers_filtered"].owner_matches_current_role = false
            manifest
        end,
        let manifest = deepcopy(deployed_export)
            manifest.relations["us_tickers_filtered"].columns[1] =
                MigrationSchema.PostgresColumnManifest("ticker", :varchar, true)
            manifest
        end,
        let manifest = deepcopy(deployed_export)
            pop!(manifest.relations["us_tickers_filtered"].indexes)
            manifest
        end,
        let manifest = deepcopy(deployed_export)
            manifest.relations["us_tickers"] = deepcopy(
                MigrationSchema.POSTGRES_TARGET_MANIFEST.relations["us_tickers"],
            )
            manifest
        end,
    )
        @test_throws PostgresMigrationError MigrationSchema.classify_preledger_manifest(
            near_miss,
        )
    end

    for near_miss in (
        let manifest = deepcopy(compatibility_export)
            delete!(manifest.relations, "security_observations")
            manifest
        end,
        let manifest = deepcopy(compatibility_export)
            manifest.relations["us_tickers"] = deepcopy(
                MigrationSchema.POSTGRES_TARGET_MANIFEST.relations["us_tickers"],
            )
            manifest
        end,
        let manifest = deepcopy(compatibility_export)
            manifest.relations["historical_data"].owner_matches_current_role = false
            manifest
        end,
        let manifest = deepcopy(compatibility_export)
            manifest.relations["historical_data"].row_security = true
            manifest
        end,
        let manifest = deepcopy(compatibility_export)
            manifest.relations["historical_data"].columns[3] =
                MigrationSchema.PostgresColumnManifest("close", :float8, true)
            manifest
        end,
        let manifest = deepcopy(compatibility_export)
            push!(
                manifest.relations["us_tickers_filtered"].indexes,
                deepcopy(MigrationSchema.POSTGRES_TARGET_MANIFEST.relations[
                    "us_tickers_filtered"
                ].indexes[1]),
            )
            manifest
        end,
    )
        @test_throws PostgresMigrationError MigrationSchema.classify_preledger_manifest(
            near_miss,
        )
    end

    hostile = deepcopy(MigrationSchema.POSTGRES_TARGET_MANIFEST)
    push!(
        hostile.relations["historical_data"].columns,
        MigrationSchema.PostgresColumnManifest("payload", :text, true),
    )
    error = try
        MigrationSchema.classify_preledger_manifest(hostile)
        nothing
    catch caught
        caught
    end
    @test error isa PostgresMigrationError
    @test occursin("backup", lowercase(sprint(showerror, error)))
end

@testset "PostgreSQL migration errors are sanitized" begin
    secret = "postgresql://alice:secret@example.invalid/app"
    error = MigrationSchema.postgres_migration_error(
        1,
        "baseline",
        ErrorException("password=hunter2 at $secret"),
    )
    message = sprint(showerror, error)
    @test !occursin("alice", message)
    @test !occursin("secret", message)
    @test !occursin("hunter2", message)
    @test occursin("[REDACTED]", message)

    quoted = MigrationSchema.postgres_migration_error(
        nothing,
        "ledger",
        ErrorException(
            "user=alice password='top secret value' " *
            "postgresql://bob:p%40ss@example.invalid/app",
        ),
    )
    quoted_message = sprint(showerror, quoted)
    @test !occursin("top secret value", quoted_message)
    @test !occursin("secret value", quoted_message)
    @test !occursin("bob", quoted_message)
    @test !occursin("p%40ss", quoted_message)

    rollback_called = Ref(false)
    interrupt = InterruptException()
    caught = try
        MigrationSchema._throw_after_migration_failure(
            interrupt,
            nothing;
            rollback=() -> (rollback_called[] = true),
        )
        nothing
    catch error
        error
    end
    @test rollback_called[]
    @test caught === interrupt

    rollback_called[] = false
    caught = try
        MigrationSchema._throw_after_migration_failure(
            interrupt,
            nothing;
            rollback=() -> begin
                rollback_called[] = true
                error("rollback failed")
            end,
        )
        nothing
    catch error
        error
    end
    @test rollback_called[]
    @test caught === interrupt
end

@testset "PostgreSQL bootstrap trace ordering" begin
    trace = MigrationSchema.bootstrap_phase_order()
    @test trace == [
        :begin,
        :set_search_path,
        :set_lock_timeout,
        :set_statement_timeout,
        :advisory_lock,
        :create_ledger,
        :read_ledger,
        :inspect_application_schema,
        :apply_transition,
        :validate_target,
        :insert_ledger,
        :commit,
    ]
    @test findfirst(==(:inspect_application_schema), trace) <
          findfirst(==(:apply_transition), trace)
    @test MigrationSchema.POSTGRES_ADVISORY_LOCK_NAMESPACE ==
          (Int32(1414089038), Int32(1))
end

@testset "PostgreSQL migration rejects unsafe relation security metadata" begin
    for field in (
        :persistence,
        :owner_matches_current_role,
        :row_security,
        :force_row_security,
        :has_unexpected_triggers,
    )
        @test field in fieldnames(MigrationSchema.PostgresRelationManifest)
    end
    for field in (
        :valid,
        :ready,
        :access_method,
        :default_opclasses,
        :collations_match_columns,
    )
        @test field in fieldnames(MigrationSchema.PostgresIndexManifest)
    end
    for field in (:generated, :identity, :has_default)
        @test field in fieldnames(MigrationSchema.PostgresColumnManifest)
    end

    expected = MigrationSchema.POSTGRES_TARGET_MANIFEST.relations["us_tickers"]
    for mutation in (
        relation -> (relation.persistence = :unlogged),
        relation -> (relation.owner_matches_current_role = false),
        relation -> (relation.row_security = true),
        relation -> (relation.force_row_security = true),
        relation -> (relation.has_unexpected_triggers = true),
    )
        hostile = deepcopy(expected)
        mutation(hostile)
        @test !MigrationSchema._relation_matches(hostile, expected)
    end

    unsafe_column_relation = deepcopy(expected)
    column = unsafe_column_relation.columns[1]
    for unsafe_column in (
        MigrationSchema.PostgresColumnManifest(
            column.name,
            column.data_type,
            column.nullable,
            :stored,
            :none,
            false,
        ),
        MigrationSchema.PostgresColumnManifest(
            column.name,
            column.data_type,
            column.nullable,
            :none,
            :always,
            false,
        ),
        MigrationSchema.PostgresColumnManifest(
            column.name,
            column.data_type,
            column.nullable,
            :none,
            :none,
            true,
        ),
    )
        hostile = deepcopy(expected)
        hostile.columns[1] = unsafe_column
        @test !MigrationSchema._relation_matches(hostile, expected)
    end

    index = expected.indexes[1]
    for unsafe_index in (
        MigrationSchema.PostgresIndexManifest(
            index.columns,
            index.unique,
            index.primary,
            index.partial,
            index.expression,
            index.valid,
            index.ready,
            :hash,
            true,
            true,
        ),
        MigrationSchema.PostgresIndexManifest(
            index.columns,
            index.unique,
            index.primary,
            index.partial,
            index.expression,
            index.valid,
            index.ready,
            :btree,
            false,
            true,
        ),
        MigrationSchema.PostgresIndexManifest(
            index.columns,
            index.unique,
            index.primary,
            index.partial,
            index.expression,
            index.valid,
            index.ready,
            :btree,
            true,
            false,
        ),
    )
        hostile = deepcopy(expected)
        hostile.indexes[1] = unsafe_index
        @test !MigrationSchema._relation_matches(hostile, expected)
    end
end

@testset "PostgreSQL schema version source is read-only" begin
    source = read(joinpath(@__DIR__, "..", "src", "db", "migrations.jl"), String)
    version_body = match(
        r"function postgres_schema_version\(.*?\n\s*end"s,
        source,
    )
    @test !isnothing(version_body)
    body = version_body.match
    @test occursin("to_regclass", body)
    @test occursin("pg_catalog.to_regclass", body)
    @test !occursin("CREATE", body)
    @test !occursin("INSERT", body)
    @test !occursin("ALTER", body)
end


@testset "PostgreSQL bootstrap pins a safe transaction-local search path" begin
    source = read(joinpath(@__DIR__, "..", "src", "db", "migrations.jl"), String)
    @test occursin("pg_catalog.set_config('search_path'", source)
    @test occursin("pg_catalog.set_config('lock_timeout'", source)
    @test occursin("pg_catalog.pg_advisory_xact_lock", source)
    begin_offset = findfirst("_pg_command(conn, \"BEGIN\")", source)
    search_path_offset = findfirst("pg_catalog.set_config('search_path'", source)
    lock_timeout_offset = findfirst("pg_catalog.set_config('lock_timeout'", source)
    advisory_offset = findfirst("pg_catalog.pg_advisory_xact_lock", source)
    @test !isnothing(begin_offset)
    @test !isnothing(search_path_offset)
    @test !isnothing(lock_timeout_offset)
    @test !isnothing(advisory_offset)
    @test first(begin_offset) < first(search_path_offset) < first(lock_timeout_offset) <
          first(advisory_offset)
end
