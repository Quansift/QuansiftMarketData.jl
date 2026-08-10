const POSTGRES_SCHEMA_VERSION = 1
const POSTGRES_ADVISORY_LOCK_NAMESPACE = (Int32(1414089038), Int32(1))
const POSTGRES_MIGRATION_TABLE = "tiingojulia_schema_migrations"

struct PostgresColumnManifest
    name::String
    data_type::Symbol
    nullable::Bool
    generated::Symbol
    identity::Symbol
    has_default::Bool
end

PostgresColumnManifest(name, data_type, nullable) = PostgresColumnManifest(
    name,
    data_type,
    nullable,
    :none,
    :none,
    false,
)

struct PostgresIndexManifest
    columns::Tuple{Vararg{String}}
    unique::Bool
    primary::Bool
    partial::Bool
    expression::Bool
    valid::Bool
    ready::Bool
    access_method::Symbol
    default_opclasses::Bool
    collations_match_columns::Bool
end

PostgresIndexManifest(columns, unique, primary, partial, expression) =
    PostgresIndexManifest(
        columns,
        unique,
        primary,
        partial,
        expression,
        true,
        true,
        :btree,
        true,
        true,
    )

PostgresIndexManifest(columns, unique, primary, partial, expression, valid, ready) =
    PostgresIndexManifest(
        columns,
        unique,
        primary,
        partial,
        expression,
        valid,
        ready,
        :btree,
        true,
        true,
    )

mutable struct PostgresRelationManifest
    name::String
    relation_kind::Symbol
    persistence::Symbol
    columns::Vector{PostgresColumnManifest}
    indexes::Vector{PostgresIndexManifest}
    owner_matches_current_role::Bool
    row_security::Bool
    force_row_security::Bool
    has_unexpected_triggers::Bool
end

PostgresRelationManifest(name, relation_kind, columns, indexes) =
    PostgresRelationManifest(
        name,
        relation_kind,
        :permanent,
        columns,
        indexes,
        true,
        false,
        false,
        false,
    )

mutable struct PostgresDatabaseManifest
    relations::Dict{String,PostgresRelationManifest}
end

PostgresDatabaseManifest() = PostgresDatabaseManifest(
    Dict{String,PostgresRelationManifest}(),
)

struct PostgresMigration
    version::Int
    name::String
    definition::String
    checksum::String
end

struct PostgresMigrationResult
    from_version::Int
    to_version::Int
    applied_versions::Vector{Int}
end

struct PostgresMigrationError <: Exception
    version::Union{Nothing,Int}
    name::String
    message::String
end

function Base.showerror(io::IO, error::PostgresMigrationError)
    prefix = isnothing(error.version) ?
        "PostgreSQL migration" :
        "PostgreSQL migration $(error.version) ($(error.name))"
    print(io, prefix, " failed: ", error.message)
end

const _TICKER_COLUMNS = [
    PostgresColumnManifest("ticker", :varchar, true),
    PostgresColumnManifest("exchange", :varchar, true),
    PostgresColumnManifest("assettype", :varchar, true),
    PostgresColumnManifest("pricecurrency", :varchar, true),
    PostgresColumnManifest("startdate", :date, true),
    PostgresColumnManifest("enddate", :date, true),
]

const _HISTORICAL_VALUE_COLUMNS = [
    PostgresColumnManifest("close", :float8, true),
    PostgresColumnManifest("high", :float8, true),
    PostgresColumnManifest("low", :float8, true),
    PostgresColumnManifest("open", :float8, true),
    PostgresColumnManifest("volume", :int8, true),
    PostgresColumnManifest("adjclose", :float8, true),
    PostgresColumnManifest("adjhigh", :float8, true),
    PostgresColumnManifest("adjlow", :float8, true),
    PostgresColumnManifest("adjopen", :float8, true),
    PostgresColumnManifest("adjvolume", :int8, true),
    PostgresColumnManifest("divcash", :float8, true),
    PostgresColumnManifest("splitfactor", :float8, true),
]

_index(columns...; unique=false, primary=false) = PostgresIndexManifest(
    Tuple(String.(columns)),
    unique,
    primary,
    false,
    false,
)

function _relation(name, columns, indexes=PostgresIndexManifest[])
    return PostgresRelationManifest(
        String(name),
        :table,
        copy(columns),
        copy(indexes),
    )
end

function _v1_manifest()
    historical_columns = vcat(
        [
            PostgresColumnManifest("ticker", :varchar, true),
            PostgresColumnManifest("date", :date, true),
        ],
        _HISTORICAL_VALUE_COLUMNS,
    )
    return PostgresDatabaseManifest(Dict(
        "us_tickers" => _relation("us_tickers", _TICKER_COLUMNS),
        "us_tickers_filtered" =>
            _relation("us_tickers_filtered", _TICKER_COLUMNS),
        "historical_data" => _relation(
            "historical_data",
            historical_columns,
            [_index("ticker", "date"; unique=true)],
        ),
    ))
end

function _target_manifest()
    historical_columns = vcat(
        [
            PostgresColumnManifest("ticker", :varchar, false),
            PostgresColumnManifest("date", :date, false),
        ],
        _HISTORICAL_VALUE_COLUMNS,
    )
    observation_columns = [
        PostgresColumnManifest("perma_ticker", :varchar, false),
        PostgresColumnManifest("observed_at", :timestamp, false),
        PostgresColumnManifest("ticker", :varchar, false),
        PostgresColumnManifest("is_active", :boolean, false),
        PostgresColumnManifest("is_adr", :boolean, true),
        PostgresColumnManifest("daily_last_updated", :timestamp, true),
        PostgresColumnManifest("exchange", :varchar, true),
        PostgresColumnManifest("asset_type", :varchar, true),
        PostgresColumnManifest("price_coverage_start", :date, true),
        PostgresColumnManifest("price_coverage_end", :date, true),
        PostgresColumnManifest("is_leveraged", :boolean, true),
        PostgresColumnManifest("join_status", :varchar, false),
    ]
    metric_columns = [
        PostgresColumnManifest("perma_ticker", :varchar, false),
        PostgresColumnManifest("metric_date", :date, false),
        PostgresColumnManifest("market_cap", :float8, true),
        PostgresColumnManifest("enterprise_value", :float8, true),
        PostgresColumnManifest("pe_ratio", :float8, true),
        PostgresColumnManifest("available_at", :timestamp, true),
        PostgresColumnManifest("fetched_at", :timestamp, false),
        PostgresColumnManifest("source_revision", :varchar, true),
    ]
    return PostgresDatabaseManifest(Dict(
        "us_tickers" => _relation(
            "us_tickers",
            _TICKER_COLUMNS,
            [_index("ticker")],
        ),
        "us_tickers_filtered" => _relation(
            "us_tickers_filtered",
            _TICKER_COLUMNS,
            [_index("ticker"), _index("assettype")],
        ),
        "historical_data" => _relation(
            "historical_data",
            historical_columns,
            [
                _index("ticker", "date"; unique=true, primary=true),
                _index("ticker", "date"; unique=true),
                _index("ticker"),
                _index("date"),
            ],
        ),
        "security_observations" => _relation(
            "security_observations",
            observation_columns,
            [
                _index("perma_ticker", "observed_at"; unique=true, primary=true),
                _index("perma_ticker", "observed_at"; unique=true),
                _index("ticker"),
            ],
        ),
        "fundamental_daily_metrics" => _relation(
            "fundamental_daily_metrics",
            metric_columns,
            [
                _index("perma_ticker", "metric_date"; unique=true, primary=true),
                _index("perma_ticker", "metric_date"; unique=true),
                _index("metric_date"),
            ],
        ),
    ))
end

const POSTGRES_V1_0_MANIFEST = _v1_manifest()
const POSTGRES_TARGET_MANIFEST = _target_manifest()

function _compatibility_export_manifest()
    historical_columns = vcat(
        [
            PostgresColumnManifest("ticker", :varchar, false),
            PostgresColumnManifest("date", :date, false),
        ],
        [
            PostgresColumnManifest(
                column.name,
                column.data_type == :float8 ? :float4 : column.data_type,
                true,
            )
            for column in _HISTORICAL_VALUE_COLUMNS
        ],
    )
    observation_columns = [
        PostgresColumnManifest("perma_ticker", :varchar, false),
        PostgresColumnManifest("observed_at", :timestamp, false),
        PostgresColumnManifest("ticker", :varchar, true),
        PostgresColumnManifest("is_active", :boolean, true),
        PostgresColumnManifest("is_adr", :boolean, true),
        PostgresColumnManifest("daily_last_updated", :timestamp, true),
        PostgresColumnManifest("exchange", :varchar, true),
        PostgresColumnManifest("asset_type", :varchar, true),
        PostgresColumnManifest("price_coverage_start", :date, true),
        PostgresColumnManifest("price_coverage_end", :date, true),
        PostgresColumnManifest("is_leveraged", :boolean, true),
        PostgresColumnManifest("join_status", :varchar, true),
    ]
    metric_columns = [
        PostgresColumnManifest("perma_ticker", :varchar, false),
        PostgresColumnManifest("metric_date", :date, false),
        PostgresColumnManifest("market_cap", :float8, true),
        PostgresColumnManifest("enterprise_value", :float8, true),
        PostgresColumnManifest("pe_ratio", :float8, true),
        PostgresColumnManifest("available_at", :timestamp, true),
        PostgresColumnManifest("fetched_at", :timestamp, true),
        PostgresColumnManifest("source_revision", :varchar, true),
    ]
    return PostgresDatabaseManifest(Dict(
        "historical_data" => _relation(
            "historical_data",
            historical_columns,
            [_index("ticker", "date"; unique=true, primary=true)],
        ),
        "us_tickers_filtered" => _relation("us_tickers_filtered", _TICKER_COLUMNS),
        "security_observations" => _relation(
            "security_observations",
            observation_columns,
            [_index("perma_ticker", "observed_at"; unique=true, primary=true)],
        ),
        "fundamental_daily_metrics" => _relation(
            "fundamental_daily_metrics",
            metric_columns,
            [_index("perma_ticker", "metric_date"; unique=true, primary=true)],
        ),
    ))
end

const POSTGRES_COMPATIBILITY_EXPORT_MANIFEST = _compatibility_export_manifest()

function _deployed_export_manifest()
    filtered_columns = copy(_TICKER_COLUMNS)
    filtered_columns[1] = PostgresColumnManifest("ticker", :varchar, false)
    return PostgresDatabaseManifest(Dict(
        "historical_data" => _relation(
            "historical_data",
            POSTGRES_TARGET_MANIFEST.relations["historical_data"].columns,
            [_index("ticker", "date"; unique=true, primary=true)],
        ),
        "us_tickers_filtered" => _relation(
            "us_tickers_filtered",
            filtered_columns,
            [
                _index("ticker"; unique=true, primary=true),
                _index("assettype"),
                _index("exchange"),
            ],
        ),
        "security_observations" => deepcopy(
            POSTGRES_COMPATIBILITY_EXPORT_MANIFEST.relations[
                "security_observations"
            ],
        ),
        "fundamental_daily_metrics" => deepcopy(
            POSTGRES_COMPATIBILITY_EXPORT_MANIFEST.relations[
                "fundamental_daily_metrics"
            ],
        ),
    ))
end

const POSTGRES_DEPLOYED_EXPORT_MANIFEST = _deployed_export_manifest()
const POSTGRES_LEGACY_CATALOG = Dict(
    :fresh => "no canonical application relations",
    :released_1_0_export => "released 1.0 export subset",
    :first_party_compatibility_export => "first-party compatibility export",
    :deployed_first_party_composition => "deployed exporter/scheduler composition",
    :released_1_0_plus_preledger_bootstrap => "released 1.0/current hybrid",
    :current_1_1_preledger => "current pre-ledger schema",
)

const POSTGRES_TARGET_DDL = [
    """
    CREATE TABLE IF NOT EXISTS "public"."us_tickers" (
        ticker VARCHAR, exchange VARCHAR, assettype VARCHAR,
        pricecurrency VARCHAR, startdate DATE, enddate DATE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS "public"."us_tickers_filtered" (
        ticker VARCHAR, exchange VARCHAR, assettype VARCHAR,
        pricecurrency VARCHAR, startdate DATE, enddate DATE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS "public"."historical_data" (
        ticker VARCHAR NOT NULL, date DATE NOT NULL,
        close DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION,
        open DOUBLE PRECISION, volume BIGINT, adjclose DOUBLE PRECISION,
        adjhigh DOUBLE PRECISION, adjlow DOUBLE PRECISION,
        adjopen DOUBLE PRECISION, adjvolume BIGINT, divcash DOUBLE PRECISION,
        splitfactor DOUBLE PRECISION,
        CONSTRAINT tiingojulia_historical_data_pkey PRIMARY KEY (ticker, date)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS "public"."security_observations" (
        perma_ticker VARCHAR NOT NULL, observed_at TIMESTAMP NOT NULL,
        ticker VARCHAR NOT NULL, is_active BOOLEAN NOT NULL, is_adr BOOLEAN,
        daily_last_updated TIMESTAMP, exchange VARCHAR, asset_type VARCHAR,
        price_coverage_start DATE, price_coverage_end DATE,
        is_leveraged BOOLEAN, join_status VARCHAR NOT NULL,
        CONSTRAINT tiingojulia_security_observations_pkey
            PRIMARY KEY (perma_ticker, observed_at)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS "public"."fundamental_daily_metrics" (
        perma_ticker VARCHAR NOT NULL, metric_date DATE NOT NULL,
        market_cap DOUBLE PRECISION, enterprise_value DOUBLE PRECISION,
        pe_ratio DOUBLE PRECISION, available_at TIMESTAMP,
        fetched_at TIMESTAMP NOT NULL, source_revision VARCHAR,
        CONSTRAINT tiingojulia_fundamental_daily_metrics_pkey
            PRIMARY KEY (perma_ticker, metric_date)
    )
    """,
]

const POSTGRES_TARGET_INDEX_DDL = [
    "CREATE INDEX IF NOT EXISTS idx_us_tickers_ticker ON \"public\".\"us_tickers\" (ticker)",
    "CREATE INDEX IF NOT EXISTS idx_us_tickers_filtered_ticker ON \"public\".\"us_tickers_filtered\" (ticker)",
    "CREATE INDEX IF NOT EXISTS idx_us_tickers_filtered_assettype ON \"public\".\"us_tickers_filtered\" (assettype)",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_historical_ticker_date ON \"public\".\"historical_data\" (ticker, date)",
    "CREATE INDEX IF NOT EXISTS idx_historical_ticker ON \"public\".\"historical_data\" (ticker)",
    "CREATE INDEX IF NOT EXISTS idx_historical_date ON \"public\".\"historical_data\" (date)",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_security_observations_key ON \"public\".\"security_observations\" (perma_ticker, observed_at)",
    "CREATE INDEX IF NOT EXISTS idx_security_observations_ticker ON \"public\".\"security_observations\" (ticker)",
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_fundamental_daily_metrics_key ON \"public\".\"fundamental_daily_metrics\" (perma_ticker, metric_date)",
    "CREATE INDEX IF NOT EXISTS idx_fundamental_daily_metrics_date ON \"public\".\"fundamental_daily_metrics\" (metric_date)",
]

const POSTGRES_MIGRATION_1_DEFINITION = join(
    vcat(
        ["schema-version=1", "catalog=fresh,v1.0-export,v1.0-hybrid,current-preledger"],
        strip.(POSTGRES_TARGET_DDL),
        POSTGRES_TARGET_INDEX_DDL,
        ["legacy-historical=set-not-null(ticker,date);add-primary-key(ticker,date)"],
    ),
    "\n-- statement --\n",
)

function migration_checksum(version::Integer, name::AbstractString, definition::AbstractString)
    payload = "$(Int(version))\n$(String(name))\n$(String(definition))"
    return bytes2hex(SHA.sha256(codeunits(payload)))
end

const POSTGRES_MIGRATIONS = let
    name = "canonical_v1_baseline"
    definition = POSTGRES_MIGRATION_1_DEFINITION
    (PostgresMigration(1, name, definition, migration_checksum(1, name, definition)),)
end

function normalize_postgres_type(raw::AbstractString)::Symbol
    value = lowercase(strip(String(raw)))
    startswith(value, "character varying") && return :varchar
    startswith(value, "varchar") && return :varchar
    value in ("double precision", "float8", "float") && return :float8
    value in ("real", "float4") && return :float4
    value in ("bigint", "int8") && return :int8
    value in ("integer", "int4") && return :int4
    value == "date" && return :date
    value in ("timestamp without time zone", "timestamp") && return :timestamp
    value in ("timestamp with time zone", "timestamptz") && return :timestamptz
    value in ("boolean", "bool") && return :boolean
    value == "text" && return :text
    throw(ArgumentError("Unsupported PostgreSQL catalog type: '$raw'"))
end

function normalize_postgres_generated(raw::AbstractString)::Symbol
    value = String(raw)
    value == "" && return :none
    value == "s" && return :stored
    value == "v" && return :virtual
    return Symbol(value)
end

function normalize_postgres_identity(raw::AbstractString)::Symbol
    value = String(raw)
    value == "" && return :none
    value == "a" && return :always
    value == "d" && return :by_default
    return Symbol(value)
end

function normalize_postgres_expression(raw::AbstractString)::String
    return replace(lowercase(strip(String(raw))), r"[\s\(\)\"]" => "")
end

function postgres_default_semantic(value)::Symbol
    ismissing(value) && return :none
    normalized = normalize_postgres_expression(String(value))
    normalized in ("current_timestamp", "now") && return :current_timestamp
    return :other
end

function default_postgres_opclass(data_type::Symbol)::String
    data_type in (:varchar, :text) && return "text_ops"
    data_type == :date && return "date_ops"
    data_type == :timestamp && return "timestamp_ops"
    data_type == :timestamptz && return "timestamptz_ops"
    data_type == :int4 && return "int4_ops"
    data_type == :int8 && return "int8_ops"
    data_type == :float4 && return "float4_ops"
    data_type == :float8 && return "float8_ops"
    data_type == :boolean && return "bool_ops"
    return ""
end

semantic_index_key(index::PostgresIndexManifest) =
    (index.unique, index.primary, index.columns)

function manifest_subset(manifest::PostgresDatabaseManifest, names)
    selected = Dict{String,PostgresRelationManifest}()
    for name in names
        key = String(name)
        selected[key] = deepcopy(manifest.relations[key])
    end
    return PostgresDatabaseManifest(selected)
end

function _relation_matches(
    actual::PostgresRelationManifest,
    expected::PostgresRelationManifest;
    exact_indexes::Bool=false,
)
    actual.relation_kind == expected.relation_kind || return false
    actual.persistence == expected.persistence || return false
    actual.owner_matches_current_role || return false
    !actual.row_security || return false
    !actual.force_row_security || return false
    !actual.has_unexpected_triggers || return false
    actual.columns == expected.columns || return false
    any(index -> index.partial || index.expression, actual.indexes) && return false
    all(index -> index.valid && index.ready, actual.indexes) || return false
    all(index -> index.access_method == :btree, actual.indexes) || return false
    all(index -> index.default_opclasses, actual.indexes) || return false
    all(index -> index.collations_match_columns, actual.indexes) || return false
    actual_keys = Set(semantic_index_key.(actual.indexes))
    expected_keys = Set(semantic_index_key.(expected.indexes))
    return exact_indexes ? actual_keys == expected_keys : expected_keys ⊆ actual_keys
end

function _manifest_matches(
    actual::PostgresDatabaseManifest,
    expected::PostgresDatabaseManifest;
    exact_indexes::Bool=false,
)
    keys(actual.relations) == keys(expected.relations) || return false
    return all(
        name -> _relation_matches(
            actual.relations[name],
            expected.relations[name];
            exact_indexes,
        ),
        keys(expected.relations),
    )
end

function _is_released_v1_subset(manifest::PostgresDatabaseManifest)
    names = Set(keys(manifest.relations))
    isempty(names) && return false
    names ⊆ Set(keys(POSTGRES_V1_0_MANIFEST.relations)) || return false
    return all(
        name -> _relation_matches(
            manifest.relations[name],
            POSTGRES_V1_0_MANIFEST.relations[name];
            exact_indexes=true,
        ),
        names,
    )
end

function _is_preledger_hybrid(manifest::PostgresDatabaseManifest)
    keys(manifest.relations) == keys(POSTGRES_TARGET_MANIFEST.relations) || return false
    historical = manifest.relations["historical_data"]
    _relation_matches(
        historical,
        POSTGRES_V1_0_MANIFEST.relations["historical_data"],
    ) || return false
    for name in keys(POSTGRES_TARGET_MANIFEST.relations)
        name == "historical_data" && continue
        _relation_matches(
            manifest.relations[name],
            POSTGRES_TARGET_MANIFEST.relations[name],
        ) || return false
    end
    return true
end

function postgres_migration_error(version, name, error)::PostgresMigrationError
    message = sprint(showerror, error)
    message = replace(message, r"(?i)(postgres(?:ql)?://)[^@\s]+@" => s"\1[REDACTED]@")
    message = replace(
        message,
        r"""(?i)((?:["']?)(?:password|passwd|pwd|pgpassword)(?:["']?)\s*(?:=>|=|:)\s*)(["'])[^"']*["']""" =>
            s"\1\2[REDACTED]\2",
    )
    message = replace(
        message,
        r"""(?i)((?:["']?)(?:password|passwd|pwd|pgpassword)(?:["']?)\s*(?:=>|=|:)\s*)[^\s,;}"']+""" =>
            s"\1[REDACTED]",
    )
    return PostgresMigrationError(
        isnothing(version) ? nothing : Int(version),
        String(name),
        message,
    )
end

function _unknown_manifest_error()
    return PostgresMigrationError(
        nothing,
        "bootstrap",
        "unknown pre-ledger PostgreSQL layout; restore or take a backup and migrate it explicitly",
    )
end

function classify_preledger_manifest(manifest::PostgresDatabaseManifest)::Symbol
    isempty(manifest.relations) && return :fresh
    _manifest_matches(manifest, POSTGRES_TARGET_MANIFEST) &&
        return :current_1_1_preledger
    _manifest_matches(
        manifest,
        POSTGRES_COMPATIBILITY_EXPORT_MANIFEST;
        exact_indexes=true,
    ) && return :first_party_compatibility_export
    _manifest_matches(
        manifest,
        POSTGRES_DEPLOYED_EXPORT_MANIFEST;
        exact_indexes=true,
    ) && return :deployed_first_party_composition
    _is_released_v1_subset(manifest) && return :released_1_0_export
    _is_preledger_hybrid(manifest) &&
        return :released_1_0_plus_preledger_bootstrap
    throw(_unknown_manifest_error())
end

bootstrap_phase_order() = [
    :begin,
    :set_search_path,
    :set_lock_timeout,
    :advisory_lock,
    :create_ledger,
    :read_ledger,
    :inspect_application_schema,
    :apply_transition,
    :validate_target,
    :insert_ledger,
    :commit,
]

function validate_migration_options(target_version::Integer, lock_timeout_seconds::Integer)
    1 <= target_version <= POSTGRES_SCHEMA_VERSION || throw(ArgumentError(
        "target_version must be between 1 and $POSTGRES_SCHEMA_VERSION",
    ))
    lock_timeout_seconds >= 0 || throw(ArgumentError(
        "lock_timeout_seconds must be non-negative",
    ))
    return nothing
end

function _pg_command(conn, sql::AbstractString, params=nothing; execute=LibPQ.execute)
    result = isnothing(params) ? execute(conn, String(sql)) : execute(conn, String(sql), params)
    try
        return nothing
    finally
        close(result)
    end
end

function _pg_dataframe(conn, sql::AbstractString, params=nothing; execute=LibPQ.execute)
    result = isnothing(params) ? execute(conn, String(sql)) : execute(conn, String(sql), params)
    try
        return DataFrame(result)
    finally
        close(result)
    end
end

const _CANONICAL_RELATION_SQL = join(
    ["'$(name)'" for name in sort!(collect(keys(POSTGRES_TARGET_MANIFEST.relations)))],
    ", ",
)

function inspect_postgres_manifest(conn)::PostgresDatabaseManifest
    columns = _pg_dataframe(conn, """
        SELECT c.relname AS relation_name,
               c.relkind::text AS relation_kind,
               c.relpersistence::text AS persistence,
               a.attname AS column_name,
               pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
               NOT a.attnotnull AS nullable,
               a.attgenerated::text AS generated,
               a.attidentity::text AS identity,
               (attribute_default.adbin IS NOT NULL) AS has_default,
               a.attnum::integer AS ordinal,
               (c.relowner = expected_owner.oid) AS owner_matches_current_role,
               c.relrowsecurity AS row_security,
               c.relforcerowsecurity AS force_row_security,
               EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_trigger trigger
                   WHERE trigger.tgrelid = c.oid
                     AND NOT trigger.tgisinternal
               ) AS has_unexpected_triggers
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
        LEFT JOIN pg_catalog.pg_attrdef attribute_default
          ON attribute_default.adrelid = a.attrelid
         AND attribute_default.adnum = a.attnum
        CROSS JOIN LATERAL (
            SELECT role.oid
            FROM pg_catalog.pg_roles role
            WHERE role.rolname = CURRENT_USER
        ) expected_owner
        WHERE n.nspname = 'public'
          AND c.relname IN ($(_CANONICAL_RELATION_SQL))
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY c.relname, a.attnum
    """)
    relations = Dict{String,PostgresRelationManifest}()
    for row in eachrow(columns)
        name = String(row.relation_name)
        kind = String(row.relation_kind) == "r" ? :table : Symbol(String(row.relation_kind))
        relation = get!(relations, name) do
            PostgresRelationManifest(
                name,
                kind,
                String(row.persistence) == "p" ? :permanent :
                    Symbol(String(row.persistence)),
                PostgresColumnManifest[],
                PostgresIndexManifest[],
                Bool(row.owner_matches_current_role),
                Bool(row.row_security),
                Bool(row.force_row_security),
                Bool(row.has_unexpected_triggers),
            )
        end
        push!(
            relation.columns,
            PostgresColumnManifest(
                String(row.column_name),
                try
                    normalize_postgres_type(String(row.data_type))
                catch error
                    error isa ArgumentError || rethrow()
                    throw(_unknown_manifest_error())
                end,
                Bool(row.nullable),
                normalize_postgres_generated(String(row.generated)),
                normalize_postgres_identity(String(row.identity)),
                Bool(row.has_default),
            ),
        )
    end

    indexes = _pg_dataframe(conn, """
        SELECT tbl.relname AS relation_name,
               idx.indexrelid::bigint AS index_oid,
               idx.indisunique AS is_unique,
               idx.indisprimary AS is_primary,
               (idx.indpred IS NOT NULL) AS is_partial,
               (idx.indexprs IS NOT NULL) AS is_expression,
               idx.indisvalid AS is_valid,
               idx.indisready AS is_ready,
               access_method.amname AS access_method,
               ord.ordinality::integer AS ordinal,
               ord.attnum::integer AS attnum,
               COALESCE(att.attname, '') AS column_name,
               pg_catalog.format_type(att.atttypid, att.atttypmod)
                   AS column_data_type,
               opclass_namespace.nspname AS opclass_namespace,
               opclass.opcname AS opclass_name,
               COALESCE(
                   (idx.indcollation::oid[])[ord.ordinality - 1] =
                       att.attcollation,
                   false
               )
                   AS collation_matches_column
        FROM pg_catalog.pg_index idx
        JOIN pg_catalog.pg_class tbl ON tbl.oid = idx.indrelid
        JOIN pg_catalog.pg_class index_relation
          ON index_relation.oid = idx.indexrelid
        JOIN pg_catalog.pg_am access_method
          ON access_method.oid = index_relation.relam
        JOIN pg_catalog.pg_namespace n ON n.oid = tbl.relnamespace
        CROSS JOIN LATERAL pg_catalog.unnest(idx.indkey)
            WITH ORDINALITY AS ord(attnum, ordinality)
        JOIN pg_catalog.pg_opclass opclass
          ON opclass.oid = (idx.indclass::oid[])[ord.ordinality - 1]
        JOIN pg_catalog.pg_namespace opclass_namespace
          ON opclass_namespace.oid = opclass.opcnamespace
        LEFT JOIN pg_catalog.pg_attribute att
          ON att.attrelid = tbl.oid AND att.attnum = ord.attnum
        WHERE n.nspname = 'public'
          AND tbl.relname IN ($(_CANONICAL_RELATION_SQL))
        ORDER BY tbl.relname, idx.indexrelid, ord.ordinality
    """)
    if !isempty(indexes)
        for group in groupby(indexes, [:relation_name, :index_oid])
            name = String(group.relation_name[1])
            haskey(relations, name) || continue
            expression = Bool(group.is_expression[1]) || any(group.attnum .<= 0)
            index_columns = Tuple(String.(group.column_name[group.attnum .> 0]))
            default_opclasses = all(
                String(row.opclass_namespace) == "pg_catalog" &&
                String(row.opclass_name) == default_postgres_opclass(
                    normalize_postgres_type(String(row.column_data_type)),
                ) for row in eachrow(group) if Int(row.attnum) > 0
            ) && !expression
            push!(
                relations[name].indexes,
                PostgresIndexManifest(
                    index_columns,
                    Bool(group.is_unique[1]),
                    Bool(group.is_primary[1]),
                    Bool(group.is_partial[1]),
                    expression,
                    Bool(group.is_valid[1]),
                    Bool(group.is_ready[1]),
                    Symbol(String(group.access_method[1])),
                    default_opclasses,
                    all(Bool.(group.collation_matches_column)),
                ),
            )
        end
    end
    return PostgresDatabaseManifest(relations)
end

function _create_ledger!(conn)
    return _pg_command(conn, """
        CREATE TABLE IF NOT EXISTS "public"."tiingojulia_schema_migrations" (
            version INTEGER PRIMARY KEY CHECK (version > 0),
            name TEXT NOT NULL,
            checksum TEXT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            package_version TEXT NOT NULL
        )
    """)
end

function _validate_ledger_relation!(conn; require_write::Bool=false)
    relation = _pg_dataframe(conn, """
        SELECT c.relkind::text AS relation_kind,
               c.relpersistence::text AS persistence,
               (c.relowner = expected_owner.oid) AS owner_matches_current_role,
               c.relrowsecurity AS row_security,
               c.relforcerowsecurity AS force_row_security,
               EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_trigger trigger
                   WHERE trigger.tgrelid = c.oid
                     AND NOT trigger.tgisinternal
               ) AS has_unexpected_triggers,
               EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_index idx
                   JOIN pg_catalog.pg_class index_relation
                     ON index_relation.oid = idx.indexrelid
                   JOIN pg_catalog.pg_am access_method
                     ON access_method.oid = index_relation.relam
                   JOIN pg_catalog.pg_opclass opclass
                     ON opclass.oid = (idx.indclass::oid[])[0]
                   JOIN pg_catalog.pg_namespace opclass_namespace
                     ON opclass_namespace.oid = opclass.opcnamespace
                   JOIN pg_catalog.pg_attribute attribute
                     ON attribute.attrelid = idx.indrelid
                    AND attribute.attname = 'version'
                   WHERE idx.indrelid = c.oid
                     AND idx.indisprimary
                     AND idx.indisunique
                     AND idx.indisvalid
                     AND idx.indisready
                     AND idx.indnkeyatts = 1
                     AND idx.indnatts = 1
                     AND idx.indpred IS NULL
                     AND idx.indexprs IS NULL
                     AND (idx.indkey::smallint[])[0] = attribute.attnum
                     AND access_method.amname = 'btree'
                     AND opclass_namespace.nspname = 'pg_catalog'
                     AND opclass.opcname = 'int4_ops'
                     AND (idx.indcollation::oid[])[0] = attribute.attcollation
               ) AS has_canonical_primary_key,
               (
                   SELECT count(*)
                   FROM pg_catalog.pg_index idx
                   WHERE idx.indrelid = c.oid
               )::integer AS index_count
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL (
            SELECT role.oid
            FROM pg_catalog.pg_roles role
            WHERE role.rolname = CURRENT_USER
        ) expected_owner
        WHERE n.nspname = 'public'
          AND c.relname = 'tiingojulia_schema_migrations'
    """)
    nrow(relation) == 1 || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "migration ledger relation is missing or ambiguous",
    ))
    row = relation[1, :]
    safe_relation = String(row.relation_kind) == "r" &&
        String(row.persistence) == "p" &&
        Bool(row.owner_matches_current_role) &&
        !Bool(row.row_security) &&
        !Bool(row.force_row_security) &&
        !Bool(row.has_unexpected_triggers) &&
        Bool(row.has_canonical_primary_key) &&
        Int(row.index_count) == 1
    safe_relation || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "migration ledger has unsafe relation security metadata",
    ))

    columns = _pg_dataframe(conn, """
        SELECT a.attname AS column_name,
               pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
               NOT a.attnotnull AS nullable,
               a.attgenerated::text AS generated,
               a.attidentity::text AS identity,
               pg_catalog.pg_get_expr(
                   attribute_default.adbin,
                   attribute_default.adrelid
               ) AS default_expression
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_attrdef attribute_default
          ON attribute_default.adrelid = a.attrelid
         AND attribute_default.adnum = a.attnum
        WHERE n.nspname = 'public'
          AND c.relname = 'tiingojulia_schema_migrations'
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
    """)
    actual_columns = [(
        manifest=PostgresColumnManifest(
            String(column.column_name),
            normalize_postgres_type(String(column.data_type)),
            Bool(column.nullable),
            normalize_postgres_generated(String(column.generated)),
            normalize_postgres_identity(String(column.identity)),
            !ismissing(column.default_expression),
        ),
        default_semantic=postgres_default_semantic(column.default_expression),
    ) for column in eachrow(columns)]
    expected_columns = [
        (
            manifest=PostgresColumnManifest("version", :int4, false),
            default_semantic=:none,
        ),
        (
            manifest=PostgresColumnManifest("name", :text, false),
            default_semantic=:none,
        ),
        (
            manifest=PostgresColumnManifest("checksum", :text, false),
            default_semantic=:none,
        ),
        (
            manifest=PostgresColumnManifest(
                "applied_at",
                :timestamptz,
                false,
                :none,
                :none,
                true,
            ),
            default_semantic=:current_timestamp,
        ),
        (
            manifest=PostgresColumnManifest("package_version", :text, false),
            default_semantic=:none,
        ),
    ]
    actual_columns == expected_columns || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "migration ledger columns do not match the canonical manifest",
    ))

    constraints = _pg_dataframe(conn, """
        SELECT constraint_row.contype::text AS constraint_type,
               constraint_row.convalidated AS validated,
               constraint_row.connoinherit AS no_inherit,
               pg_catalog.pg_get_expr(
                   constraint_row.conbin,
                   constraint_row.conrelid
               ) AS expression
        FROM pg_catalog.pg_constraint constraint_row
        JOIN pg_catalog.pg_class relation
          ON relation.oid = constraint_row.conrelid
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = 'tiingojulia_schema_migrations'
        ORDER BY constraint_row.contype, constraint_row.oid
    """)
    primary_constraints = filter(
        constraint -> String(constraint.constraint_type) == "p",
        eachrow(constraints),
    )
    check_constraints = filter(
        constraint -> String(constraint.constraint_type) == "c",
        eachrow(constraints),
    )
    canonical_constraints = nrow(constraints) == 2 &&
        length(primary_constraints) == 1 &&
        length(check_constraints) == 1 &&
        Bool(check_constraints[1].validated) &&
        !Bool(check_constraints[1].no_inherit) &&
        normalize_postgres_expression(String(check_constraints[1].expression)) ==
        "version>0"
    canonical_constraints || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "migration ledger constraints do not match the canonical manifest",
    ))
    return nothing
end

function _read_ledger(conn)::DataFrame
    return _pg_dataframe(conn, """
        SELECT version, name, checksum
        FROM "public"."tiingojulia_schema_migrations"
        ORDER BY version
    """)
end

function _validate_ledger(ledger::DataFrame, migrations=POSTGRES_MIGRATIONS)::Int
    isempty(ledger) && return 0
    versions = Int.(ledger.version)
    versions == collect(1:maximum(versions)) || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "migration ledger is gapped or unordered",
    ))
    maximum(versions) <= length(migrations) || throw(PostgresMigrationError(
        nothing,
        "ledger",
        "database schema is newer than this Tiingo build",
    ))
    for row in eachrow(ledger)
        migration = migrations[Int(row.version)]
        if String(row.name) != migration.name || String(row.checksum) != migration.checksum
            throw(PostgresMigrationError(
                Int(row.version),
                migration.name,
                "migration ledger name/checksum mismatch",
            ))
        end
    end
    return maximum(versions)
end

function postgres_schema_version(conn::LibPQ.Connection)::Int
    try
        relation = _pg_dataframe(
            conn,
            "SELECT pg_catalog.to_regclass('public.tiingojulia_schema_migrations') AS relation",
        )
        (isempty(relation) || ismissing(relation.relation[1])) && return 0
        _validate_ledger_relation!(conn)
        return _validate_ledger(_read_ledger(conn))
    catch error
        error isa InterruptException && rethrow()
        error isa PostgresMigrationError && rethrow()
        throw(postgres_migration_error(nothing, "ledger", error))
    end
end

function _assert_legacy_historical_keys!(conn)
    invalid = _pg_dataframe(conn, """
        SELECT
          count(*) FILTER (WHERE ticker IS NULL OR date IS NULL) AS null_keys,
          count(*) - count(DISTINCT (ticker, date)) AS duplicate_keys
        FROM "public"."historical_data"
    """)
    null_keys = Int(invalid.null_keys[1])
    duplicate_keys = Int(invalid.duplicate_keys[1])
    (null_keys == 0 && duplicate_keys == 0) || throw(PostgresMigrationError(
        1,
        "canonical_v1_baseline",
        "legacy historical_data has null or duplicate keys; take a backup and repair explicitly",
    ))
    return nothing
end

function _assert_compatibility_required_values!(conn)
    invalid = _pg_dataframe(conn, """
        SELECT
          (SELECT count(*) FROM "public"."security_observations"
           WHERE ticker IS NULL OR is_active IS NULL OR join_status IS NULL)
            AS observation_nulls,
          (SELECT count(*) FROM "public"."fundamental_daily_metrics"
           WHERE fetched_at IS NULL) AS metric_nulls
    """)
    (Int(invalid.observation_nulls[1]) == 0 && Int(invalid.metric_nulls[1]) == 0) ||
        throw(PostgresMigrationError(
            1,
            "canonical_v1_baseline",
            "compatibility export has null required values; " *
            "take a backup and repair explicitly",
        ))
    return nothing
end

function _restore_compatibility_required_not_null!(conn)
    _pg_command(conn, """
        ALTER TABLE "public"."security_observations"
          ALTER COLUMN ticker SET NOT NULL,
          ALTER COLUMN is_active SET NOT NULL,
          ALTER COLUMN join_status SET NOT NULL
    """)
    _pg_command(conn, """
        ALTER TABLE "public"."fundamental_daily_metrics"
          ALTER COLUMN fetched_at SET NOT NULL
    """)
    return nothing
end

function _upgrade_compatibility_export!(conn)
    _assert_compatibility_required_values!(conn)
    _pg_command(conn, """
        ALTER TABLE "public"."historical_data"
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
    _restore_compatibility_required_not_null!(conn)
    return nothing
end

function _upgrade_deployed_export!(conn)
    _assert_compatibility_required_values!(conn)
    _pg_command(conn, """
        CREATE UNIQUE INDEX tiingojulia_us_tickers_filtered_ticker_bridge
        ON "public"."us_tickers_filtered" (ticker)
    """)
    primary = _pg_dataframe(conn, """
        SELECT constraint_name
        FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'us_tickers_filtered'
          AND constraint_type = 'PRIMARY KEY'
    """)
    nrow(primary) == 1 || throw(PostgresMigrationError(
        1,
        "canonical_v1_baseline",
        "deployed ticker export must have exactly one primary key constraint",
    ))
    constraint_name = quote_postgres_identifier(String(primary.constraint_name[1]))
    _pg_command(
        conn,
        "ALTER TABLE \"public\".\"us_tickers_filtered\" " *
        "DROP CONSTRAINT $constraint_name",
    )
    _pg_command(conn, """
        ALTER TABLE "public"."us_tickers_filtered"
          ALTER COLUMN ticker DROP NOT NULL
    """)
    _restore_compatibility_required_not_null!(conn)
    return nothing
end

function _has_primary_historical_key(manifest::PostgresDatabaseManifest)
    haskey(manifest.relations, "historical_data") || return false
    return any(
        index -> index.primary && index.columns == ("ticker", "date"),
        manifest.relations["historical_data"].indexes,
    )
end

function _apply_bootstrap_transition!(conn, catalog_entry::Symbol, manifest)
    catalog_entry == :first_party_compatibility_export &&
        _upgrade_compatibility_export!(conn)
    catalog_entry == :deployed_first_party_composition &&
        _upgrade_deployed_export!(conn)
    for statement in POSTGRES_TARGET_DDL
        _pg_command(conn, statement)
    end
    if catalog_entry in (
        :released_1_0_export,
        :released_1_0_plus_preledger_bootstrap,
    ) && haskey(manifest.relations, "historical_data") &&
       !_has_primary_historical_key(manifest)
        _assert_legacy_historical_keys!(conn)
        _pg_command(conn, """
            ALTER TABLE "public"."historical_data"
            ALTER COLUMN ticker SET NOT NULL,
            ALTER COLUMN date SET NOT NULL
        """)
        _pg_command(conn, """
            ALTER TABLE "public"."historical_data"
            ADD CONSTRAINT tiingojulia_historical_data_pkey
            PRIMARY KEY (ticker, date)
        """)
    end
    for statement in POSTGRES_TARGET_INDEX_DDL
        _pg_command(conn, statement)
    end
    return nothing
end

function _validate_target_manifest(manifest::PostgresDatabaseManifest)
    _manifest_matches(manifest, POSTGRES_TARGET_MANIFEST) || throw(PostgresMigrationError(
        POSTGRES_SCHEMA_VERSION,
        "canonical_v1_baseline",
        "PostgreSQL schema does not match the canonical target manifest; take a backup before manual repair",
    ))
    return nothing
end

function _insert_migration!(conn, migration::PostgresMigration)
    _pg_command(
        conn,
        """
        INSERT INTO "public"."tiingojulia_schema_migrations"
            (version, name, checksum, package_version)
        VALUES (\$1, \$2, \$3, \$4)
        """,
        Any[
            migration.version,
            migration.name,
            migration.checksum,
            string(pkgversion(parentmodule(parentmodule(@__MODULE__)))),
        ],
    )
    return nothing
end

function _throw_after_migration_failure(
    error,
    current_migration;
    rollback::Function,
)
    try
        rollback()
    catch
    end
    error isa InterruptException && throw(error)
    error isa PostgresMigrationError && throw(error)
    version = isnothing(current_migration) ? nothing : current_migration.version
    name = isnothing(current_migration) ? "bootstrap" : current_migration.name
    throw(postgres_migration_error(version, name, error))
end

function migrate_postgres!(
    conn::LibPQ.Connection;
    target_version::Integer=POSTGRES_SCHEMA_VERSION,
    lock_timeout_seconds::Integer=30,
)::PostgresMigrationResult
    validate_migration_options(target_version, lock_timeout_seconds)
    LibPQ.transaction_status(conn) == LibPQ.libpq_c.PQTRANS_IDLE || throw(ArgumentError(
        "migrate_postgres! requires an idle PostgreSQL connection; caller-owned transactions are not supported",
    ))

    began = false
    current_migration = nothing
    try
        _pg_command(conn, "BEGIN")
        began = true
        _pg_command(
            conn,
            "SELECT pg_catalog.set_config('search_path', \$1, true)",
            Any["pg_catalog"],
        )
        _pg_command(
            conn,
            "SELECT pg_catalog.set_config('lock_timeout', \$1, true)",
            Any["$(Int(lock_timeout_seconds) * 1000)ms"],
        )
        _pg_command(
            conn,
            "SELECT pg_catalog.pg_advisory_xact_lock(1414089038, 1)",
        )
        _create_ledger!(conn)
        _validate_ledger_relation!(conn; require_write=true)
        ledger = _read_ledger(conn)
        from_version = _validate_ledger(ledger)
        from_version <= target_version || throw(PostgresMigrationError(
            nothing,
            "ledger",
            "database schema version $from_version is newer than requested target $target_version",
        ))
        applied = Int[]

        if from_version == 0
            legacy_manifest = inspect_postgres_manifest(conn)
            catalog_entry = classify_preledger_manifest(legacy_manifest)
            current_migration = POSTGRES_MIGRATIONS[1]
            _apply_bootstrap_transition!(conn, catalog_entry, legacy_manifest)
            _validate_target_manifest(inspect_postgres_manifest(conn))
            _insert_migration!(conn, current_migration)
            push!(applied, 1)
        else
            _validate_target_manifest(inspect_postgres_manifest(conn))
        end

        _pg_command(conn, "COMMIT")
        began = false
        return PostgresMigrationResult(from_version, target_version, applied)
    catch error
        _throw_after_migration_failure(
            error,
            current_migration;
            rollback=() -> began && _pg_command(conn, "ROLLBACK"),
        )
    end
end
