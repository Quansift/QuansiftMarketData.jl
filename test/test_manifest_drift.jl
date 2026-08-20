using Test
using QuansiftMarketData

const DriftSchema = QuansiftMarketData.DB.Schema

_drift_column(name, data_type, nullable) =
    DriftSchema.PostgresColumnManifest(name, data_type, nullable)

_drift_index(columns...; unique=false, primary=false) =
    DriftSchema.PostgresIndexManifest(
        Tuple(String.(columns)),
        unique,
        primary,
        false,
        false,
        true,
        true,
        :btree,
        true,
        true,
    )

function _drift_relation(name, columns, indexes=DriftSchema.PostgresIndexManifest[])
    return DriftSchema.PostgresRelationManifest(
        String(name),
        :table,
        copy(columns),
        copy(indexes),
    )
end

_drift_manifest(relations...) = DriftSchema.PostgresDatabaseManifest(
    Dict(relation.name => relation for relation in relations),
)

_canonical_drift_manifest() = _drift_manifest(
    _drift_relation(
        "widgets",
        [
            _drift_column("id", :int4, false),
            _drift_column("label", :varchar, false),
        ],
        [_drift_index("id"; unique=true, primary=true)],
    ),
)

@testset "Manifest drift reporting" begin
    @testset "an identical manifest reports no drift" begin
        @test isempty(DriftSchema._manifest_drift(
            _canonical_drift_manifest(),
            _canonical_drift_manifest(),
        ))
    end

    @testset "a nullable column that should not be names itself" begin
        actual = _drift_manifest(
            _drift_relation(
                "widgets",
                [
                    _drift_column("id", :int4, false),
                    _drift_column("label", :varchar, true),
                ],
                [_drift_index("id"; unique=true, primary=true)],
            ),
        )
        drift = DriftSchema._manifest_drift(actual, _canonical_drift_manifest())
        @test length(drift) == 1
        finding = only(drift)
        @test finding.relation == "widgets"
        @test finding.component === :column
        @test finding.subject == "label"
        # The whole point of the issue: the operator must be able to act on
        # this without reading the source.
        rendered = sprint(show, finding)
        @test occursin("widgets", rendered)
        @test occursin("label", rendered)
    end

    @testset "a missing index names the key it should have covered" begin
        actual = _drift_relation(
            "widgets",
            [
                _drift_column("id", :int4, false),
                _drift_column("label", :varchar, false),
            ],
            [_drift_index("id"; unique=true, primary=true)],
        )
        expected = _drift_relation(
            "widgets",
            [
                _drift_column("id", :int4, false),
                _drift_column("label", :varchar, false),
            ],
            [
                _drift_index("id"; unique=true, primary=true),
                _drift_index("label"),
            ],
        )
        drift = DriftSchema._manifest_drift(
            _drift_manifest(actual),
            _drift_manifest(expected),
        )
        @test length(drift) == 1
        finding = only(drift)
        @test finding.component === :index
        @test occursin("label", sprint(show, finding))
    end

    @testset "an extra index is tolerated, matching _manifest_matches" begin
        actual = _drift_relation(
            "widgets",
            [
                _drift_column("id", :int4, false),
                _drift_column("label", :varchar, false),
            ],
            [
                _drift_index("id"; unique=true, primary=true),
                _drift_index("label"),
            ],
        )
        @test isempty(DriftSchema._manifest_drift(
            _drift_manifest(actual),
            _canonical_drift_manifest(),
        ))
    end

    @testset "a missing relation is reported once, not per column" begin
        drift = DriftSchema._manifest_drift(
            DriftSchema.PostgresDatabaseManifest(
                Dict{String,DriftSchema.PostgresRelationManifest}(),
            ),
            _canonical_drift_manifest(),
        )
        @test length(drift) == 1
        @test only(drift).component === :relation
        @test only(drift).relation == "widgets"
    end

    @testset "an unexpected relation is reported" begin
        extra = _drift_relation("gadgets", [_drift_column("id", :int4, false)])
        actual = _drift_manifest(
            _drift_relation(
                "widgets",
                [
                    _drift_column("id", :int4, false),
                    _drift_column("label", :varchar, false),
                ],
                [_drift_index("id"; unique=true, primary=true)],
            ),
            extra,
        )
        drift = DriftSchema._manifest_drift(actual, _canonical_drift_manifest())
        @test length(drift) == 1
        @test only(drift).relation == "gadgets"
    end

    @testset "several drifts are all reported, not just the first" begin
        actual = _drift_manifest(
            _drift_relation(
                "widgets",
                [
                    _drift_column("id", :int4, true),
                    _drift_column("label", :varchar, true),
                ],
                DriftSchema.PostgresIndexManifest[],
            ),
        )
        drift = DriftSchema._manifest_drift(actual, _canonical_drift_manifest())
        @test length(drift) >= 2
        @test any(finding -> finding.component === :index, drift)
    end

    @testset "a migration error names what to repair" begin
        actual = _drift_manifest(
            _drift_relation(
                "widgets",
                [
                    _drift_column("id", :int4, false),
                    _drift_column("label", :varchar, true),
                ],
                [_drift_index("id"; unique=true, primary=true)],
            ),
        )
        error = try
            DriftSchema._validate_target_manifest_against(actual, _canonical_drift_manifest(), 1)
            nothing
        catch caught
            caught
        end
        @test error isa PostgresMigrationError
        rendered = sprint(showerror, error)
        # The message the operator actually receives has to carry the subject.
        @test occursin("widgets", rendered)
        @test occursin("label", rendered)
        @test occursin("manual repair", rendered)
    end

    @testset "a long drift list is summarised rather than dumped" begin
        many = [_drift_column("c$index", :int4, false) for index in 1:40]
        actual = _drift_manifest(_drift_relation("widgets", many))
        expected = _drift_manifest(_drift_relation(
            "widgets",
            [_drift_column("c$index", :varchar, false) for index in 1:40],
        ))
        error = try
            DriftSchema._validate_target_manifest_against(actual, expected, 1)
            nothing
        catch caught
            caught
        end
        rendered = sprint(showerror, error)
        @test occursin("more", rendered)
        @test count(==('\n'), rendered) <= DriftSchema._MAX_REPORTED_DRIFT + 3
    end

    @testset "readiness state follows from version and drift" begin
        state = DriftSchema._readiness_state
        no_drift = DriftSchema.PostgresManifestDrift[]
        some_drift = [DriftSchema.PostgresManifestDrift(
            "widgets", :column, "label", "NOT NULL", "nullable",
        )]

        @test state(3, 3, no_drift) === :ready
        @test state(1, 3, no_drift) === :migration_required
        # Drift outranks a pending migration: migrating a drifted database is
        # what fail-closed exists to prevent.
        @test state(1, 3, some_drift) === :drift
        @test state(3, 3, some_drift) === :drift
        @test state(4, 3, no_drift) === :newer_schema
        # A newer schema is reported as such even when the catalog also differs,
        # because an older build cannot know what the newer manifest should be.
        @test state(4, 3, some_drift) === :newer_schema
    end

    @testset "readiness reports whether migrating is safe" begin
        readiness = DriftSchema.PostgresMigrationReadiness(
            :migration_required, 1, 3, DriftSchema.PostgresManifestDrift[],
        )
        @test readiness.state === :migration_required
        @test !readiness.ready
        @test readiness.migratable

        drifted = DriftSchema.PostgresMigrationReadiness(
            :drift, 1, 3,
            [DriftSchema.PostgresManifestDrift(
                "widgets", :column, "label", "NOT NULL", "nullable",
            )],
        )
        @test !drifted.ready
        @test !drifted.migratable

        current = DriftSchema.PostgresMigrationReadiness(
            :ready, 3, 3, DriftSchema.PostgresManifestDrift[],
        )
        @test current.ready
        @test current.migratable
    end

    @testset "matching agrees with drift emptiness" begin
        # One engine, so the predicate and the report can never disagree.
        canonical = _canonical_drift_manifest()
        drifted = _drift_manifest(
            _drift_relation(
                "widgets",
                [
                    _drift_column("id", :int4, false),
                    _drift_column("label", :varchar, true),
                ],
                [_drift_index("id"; unique=true, primary=true)],
            ),
        )
        @test DriftSchema._manifest_matches(canonical, canonical) ==
              isempty(DriftSchema._manifest_drift(canonical, canonical))
        @test DriftSchema._manifest_matches(drifted, canonical) ==
              isempty(DriftSchema._manifest_drift(drifted, canonical))
    end
end
