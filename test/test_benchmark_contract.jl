using Test
using DataFrames
using Dates
using DBInterface
using DuckDB
using JSON3
using LibPQ
using QuansiftMarketData

include(joinpath(@__DIR__, "..", "benchmark", "common.jl"))
using .QuansiftMarketDataBench

function _benchmark_test_config(; kwargs...)
    defaults = (
        mode=:micro,
        seed=20260802,
        ticker_count=2,
        trading_day_count=5,
        samples=1,
        iterations=2,
        max_elapsed_seconds=30,
        sink=:local,
        output_path="benchmark-test.json",
    )
    return BenchmarkConfig(; merge(defaults, (; kwargs...))...)
end

@testset "benchmark fixtures are deterministic and canonical" begin
    config = _benchmark_test_config()
    first_frame = synthetic_eod_frame(config, 1)
    second_frame = synthetic_eod_frame(config, 1)
    other_seed = synthetic_eod_frame(
        BenchmarkConfig(;
            mode=:micro,
            seed=config.seed + 1,
            ticker_count=config.ticker_count,
            trading_day_count=config.trading_day_count,
            samples=config.samples,
            iterations=config.iterations,
            max_elapsed_seconds=config.max_elapsed_seconds,
            sink=config.sink,
            output_path=config.output_path,
        ),
        1,
    )

    @test isequal(first_frame, second_frame)
    @test !isequal(first_frame, other_seed)
    @test nrow(first_frame) == config.trading_day_count
    @test names(first_frame) == [
        "date", "close", "high", "low", "open", "volume", "adjClose",
        "adjHigh", "adjLow", "adjOpen", "adjVolume", "divCash",
        "splitFactor", "fetched_at",
    ]
    @test first_frame.fetched_at == fill(DateTime(1970, 1, 1), nrow(first_frame))
    @test issorted(first_frame.date)
    @test allunique(first_frame.date)
end

@testset "canonical benchmark digest covers ordered keys and values" begin
    config = _benchmark_test_config()
    frame = synthetic_eod_frame(config, 1)
    insertcols!(frame, 1, :ticker => fill("SYN0001", nrow(frame)))
    reordered = frame[reverse(axes(frame, 1)), :]
    corrupted = copy(frame)
    corrupted.close[1] += 1.0

    @test canonical_eod_digest(frame) == canonical_eod_digest(reordered)
    @test canonical_eod_digest(frame) != canonical_eod_digest(corrupted)
    @test canonical_eod_digest(frame) != canonical_eod_digest(frame[2:end, :])
end

@testset "benchmark configuration rejects unsafe bounds" begin
    invalid = Dict(
        "TIINGO_BENCH_TICKERS" => ("0", string(MAX_TICKERS + 1)),
        "TIINGO_BENCH_DAYS" => ("-1", string(MAX_TRADING_DAYS + 1)),
        "TIINGO_BENCH_SAMPLES" => ("0", string(MAX_SAMPLES + 1)),
        "TIINGO_BENCH_ITERATIONS" => ("-2", string(MAX_ITERATIONS + 1)),
        "TIINGO_BENCH_MAX_ELAPSED_SECONDS" =>
            ("0", string(MAX_ELAPSED_SECONDS + 1)),
    )
    for (name, values) in invalid, value in values
        @test_throws ArgumentError config_from_env(
            :micro;
            env=Dict(name => value),
        )
    end
    @test_throws ArgumentError config_from_env(:unknown; env=Dict{String,String}())
    @test_throws ArgumentError config_from_env(
        :micro;
        env=Dict("TIINGO_BENCH_SINK" => "network"),
    )
end

@testset "benchmark result JSON is stable metadata only" begin
    config = _benchmark_test_config()
    document = result_document(
        config;
        git_sha="0123456789abcdef",
        metrics=Dict(
            "elapsed_seconds" => 0.25,
            "allocated_bytes" => 1024,
            "rss_before_bytes" => 2048,
            "rss_after_bytes" => 4096,
        ),
        correctness=Dict(
            "row_count" => 10,
            "idempotent" => true,
            "values_match" => true,
            "cleanup" => true,
        ),
        dependency_versions=Dict("BenchmarkTools" => "1.8.0"),
    )

    @test Set(keys(document)) == Set([
        "schema_version", "status", "git_sha", "environment", "config",
        "metrics", "correctness",
    ])
    @test document["schema_version"] == BENCHMARK_RESULT_SCHEMA_VERSION
    @test document["status"] == "passed"
    @test Set(keys(document["environment"])) == Set([
        "julia_version", "package_version", "dependency_versions",
        "os", "architecture", "cpu_threads",
    ])
    @test document["environment"]["dependency_versions"]["BenchmarkTools"] ==
        "1.8.0"
    encoded = JSON3.write(document)
    @test JSON3.read(encoded).schema_version == BENCHMARK_RESULT_SCHEMA_VERSION
    @test !occursin("postgresql://", encoded)
    @test !occursin("TIINGO_API_KEY", encoded)
    @test !occursin("ticker_values", encoded)

    mktempdir() do directory
        destination = joinpath(directory, "nested", "result.json")
        @test write_result(destination, document) == abspath(destination)
        restored = JSON3.read(read(destination, String))
        @test restored.schema_version == BENCHMARK_RESULT_SCHEMA_VERSION
        @test readdir(joinpath(directory, "nested")) == ["result.json"]
    end
end

@testset "benchmark DuckDB upsert is idempotent" begin
    config = _benchmark_test_config()
    frame = synthetic_eod_frame(config, 1)
    run_fetched_at = DateTime(2026, 8, 16, 12)
    frame[!, :fetched_at] = fill(run_fetched_at, nrow(frame))
    with_benchmark_tempdir() do directory
        connection = connect_duckdb(joinpath(directory, "state.duckdb"))
        try
            @test upsert_stock_data_bulk(connection, frame, "SYN0001") == nrow(frame)
            @test upsert_stock_data_bulk(connection, frame, "SYN0001") == nrow(frame)
            stored = DBInterface.execute(
                connection,
                "SELECT date, close, fetched_at FROM historical_data " *
                "WHERE ticker = 'SYN0001' ORDER BY date",
            ) |> DataFrame
            @test nrow(stored) == nrow(frame)
            @test stored.date == frame.date
            @test all(isapprox.(stored.close, frame.close; rtol=1e-6))
            @test stored.fetched_at == fill(run_fetched_at, nrow(frame))
        finally
            close_duckdb(connection)
        end
    end
end

@testset "benchmark temporary state is unique and always cleaned" begin
    success_path = Ref("")
    with_benchmark_tempdir() do directory
        success_path[] = directory
        @test isdir(directory)
    end
    @test !ispath(success_path[])

    failure_path = Ref("")
    @test_throws ErrorException with_benchmark_tempdir() do directory
        failure_path[] = directory
        error("injected failure")
    end
    @test !ispath(failure_path[])

    interrupt_path = Ref("")
    @test_throws InterruptException with_benchmark_tempdir() do directory
        interrupt_path[] = directory
        throw(InterruptException())
    end
    @test !ispath(interrupt_path[])

    first_path = Ref("")
    second_path = Ref("")
    with_benchmark_tempdir() do directory
        first_path[] = directory
    end
    with_benchmark_tempdir() do directory
        second_path[] = directory
    end
    @test first_path[] != second_path[]
end

@testset "PostgreSQL benchmark requires isolated disposable acknowledgement" begin
    config = _benchmark_test_config(sink=:postgres)
    connection = "postgresql://postgres:secret@localhost/tiingojulia_benchmark"
    base_env = Dict("TIINGO_BENCH_PG_CONNECTION" => connection)

    @test_throws ArgumentError require_postgres_access(config; env=Dict{String,String}())
    @test_throws ArgumentError require_postgres_access(config; env=base_env)
    @test_throws ArgumentError require_postgres_access(
        config;
        env=merge(base_env, Dict(
            "TIINGO_BENCH_POSTGRES_ISOLATED" => "true",
        )),
    )
    approved = merge(base_env, Dict(
        "TIINGO_BENCH_POSTGRES_ISOLATED" => "true",
        "TIINGO_BENCH_POSTGRES_DISPOSABLE" =>
            "I_ACKNOWLEDGE_THIS_DATABASE_IS_DISPOSABLE",
        "TIINGO_BENCH_PG_DATABASE" => "tiingojulia_benchmark",
        "TIINGO_BENCH_RUN_ID" => "contract-access",
    ))
    @test require_postgres_access(config; env=approved) == connection
    @test require_postgres_access(config; env=approved) isa String
    @test isnothing(require_postgres_access(_benchmark_test_config(); env=Dict()))
end

@testset "PostgreSQL benchmark requires exact server identity inputs" begin
    config = _benchmark_test_config(sink=:postgres)
    base_env = Dict(
        "TIINGO_BENCH_PG_CONNECTION" =>
            "postgresql://postgres:secret@localhost/tiingojulia_benchmark",
        "TIINGO_BENCH_POSTGRES_ISOLATED" => "true",
        "TIINGO_BENCH_POSTGRES_DISPOSABLE" =>
            "I_ACKNOWLEDGE_THIS_DATABASE_IS_DISPOSABLE",
    )
    @test_throws ArgumentError require_postgres_access(config; env=base_env)
    @test_throws ArgumentError require_postgres_access(
        config;
        env=merge(base_env, Dict(
            "TIINGO_BENCH_PG_DATABASE" => "tiingojulia_benchmark",
        )),
    )
    approved = merge(base_env, Dict(
        "TIINGO_BENCH_PG_DATABASE" => "tiingojulia_benchmark",
        "TIINGO_BENCH_RUN_ID" => "contract-123",
    ))
    @test require_postgres_database(approved) == "tiingojulia_benchmark"
    @test startswith(postgres_ticker_namespace(approved), "TB")
    @test_throws ArgumentError postgres_ticker_namespace(
        merge(approved, Dict("TIINGO_BENCH_RUN_ID" => "unsafe/run")),
    )
end

@testset "benchmark source and workflow contracts" begin
    benchmark_directory = joinpath(@__DIR__, "..", "benchmark")
    source = join([
        read(joinpath(benchmark_directory, "common.jl"), String),
        read(joinpath(benchmark_directory, "run.jl"), String),
    ], "\n")
    for forbidden in (
        "get_api_key",
        "fetch_api_data",
        "TIINGO_API_KEY",
        "performance_test.duckdb",
        "update_historical(",
        "update_historical_parallel",
        "update_historical_sequential",
        "download_tickers_duckdb",
        "add_historical_data",
        "update_split_ticker",
        "export_to_postgres",
        "INSTALL postgres",
    )
        @test !occursin(forbidden, source)
    end

    project = read(joinpath(benchmark_directory, "Project.toml"), String)
    for dependency in (
        "BenchmarkTools", "DataFrames", "Dates", "DBInterface", "DuckDB",
        "JSON3", "LibPQ", "QuansiftMarketData",
    )
        @test occursin(dependency, project)
    end
    benchmark_readme = read(joinpath(benchmark_directory, "README.md"), String)
    @test occursin("intentionally has no committed", benchmark_readme)
    @test occursin("Julia 1.9", benchmark_readme)
    @test occursin("Julia 1.12", benchmark_readme)
    @test occursin("Pkg.resolve()", benchmark_readme)

    @test !occursin("LIKE 'SYN%'", source)
    @test !occursin(r"DELETE FROM.*LIKE"s, source)
    @test occursin("POSTGRES_DISPOSABLE_MARKER", source)
    @test occursin("pg_catalog.current_database()", source)
    @test occursin("pg_catalog.shobj_description", source)
    @test occursin("FROM pg_catalog.pg_database", source)
    @test occursin("LibPQ.execute(connection, sql, tickers)", source)

    workflow = read(
        joinpath(@__DIR__, "..", ".github", "workflows", "performance.yml"),
        String,
    )
    @test !occursin("pull_request:", workflow)
    @test occursin("schedule:", workflow)
    @test occursin("workflow_dispatch:", workflow)
    @test !occursin("julia-version:", workflow)
    @test count(
        line -> occursin(r"version:\s*[\"']1\.12[\"']", strip(line)),
        split(workflow, '\n'),
    ) == 3
    @test count(
        line -> occursin(r"version:\s*[\"']1\.9[\"']", strip(line)),
        split(workflow, '\n'),
    ) == 1
    @test occursin("resolver-floor-smoke:", workflow)
    @test count("Pkg.resolve()", workflow) == 4
    action_lines = filter(
        line -> occursin(r"^\s*(?:-\s+)?uses:", line),
        split(workflow, '\n'),
    )
    @test !isempty(action_lines)
    @test all(
        line -> occursin(
            r"uses:\s*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}\s+#\s+\S+",
            line,
        ),
        action_lines,
    )
    @test occursin("retention-days:", workflow)
    @test occursin("cancel-in-progress: true", workflow)
    @test occursin("postgres:17", workflow)
    @test occursin("postgres-load:", workflow)
    @test occursin("local-soak:", workflow)
    @test occursin("COMMENT ON DATABASE tiingojulia_benchmark", workflow)
    @test occursin("TIINGO_BENCH_PG_DATABASE", workflow)
    @test occursin("TIINGO_BENCH_RUN_ID", workflow)
end

@testset "PostgreSQL benchmark disposable end-to-end" begin
    connection_string = get(ENV, "TIINGO_TEST_BENCH_PG_CONNECTION", "")
    if isempty(connection_string)
        @test_skip "Set TIINGO_TEST_BENCH_PG_CONNECTION for the opt-in regression"
    else
        expected_database = get(
            ENV,
            "TIINGO_TEST_BENCH_PG_DATABASE",
            "tiingojulia_benchmark",
        )
        mktempdir() do directory
            output_path = joinpath(directory, "postgres-load.json")
            inherited_env = Dict{String,String}(
                name => ENV[name] for name in (
                    "HOME", "PATH", "TMPDIR", "LANG", "LC_ALL",
                    "JULIA_DEPOT_PATH", "TIINGO_LOGGER",
                ) if haskey(ENV, name)
            )
            benchmark_env = merge(
                inherited_env,
                Dict(
                    "TIINGO_BENCH_TICKERS" => "2",
                    "TIINGO_BENCH_DAYS" => "3",
                    "TIINGO_BENCH_SAMPLES" => "1",
                    "TIINGO_BENCH_ITERATIONS" => "2",
                    "TIINGO_BENCH_MAX_ELAPSED_SECONDS" => "90",
                    "TIINGO_BENCH_SINK" => "postgres",
                    "TIINGO_BENCH_OUTPUT" => output_path,
                    "TIINGO_BENCH_PG_CONNECTION" => connection_string,
                    "TIINGO_BENCH_PG_DATABASE" => expected_database,
                    "TIINGO_BENCH_RUN_ID" => "contract-e2e",
                    "TIINGO_BENCH_POSTGRES_ISOLATED" => "true",
                    "TIINGO_BENCH_POSTGRES_DISPOSABLE" =>
                        "I_ACKNOWLEDGE_THIS_DATABASE_IS_DISPOSABLE",
                ),
            )
            command = `$(Base.julia_cmd()) --startup-file=no --project=benchmark benchmark/run.jl load`

            connection = LibPQ.Connection(connection_string)
            hostile_schema = "tiingo_bench_hostile"
            try
                for statement in (
                    "CREATE SCHEMA $hostile_schema",
                    "CREATE FUNCTION $hostile_schema.current_database() " *
                    "RETURNS name LANGUAGE sql IMMUTABLE AS " *
                    "'SELECT ''tiingojulia_benchmark''::name'",
                    "CREATE FUNCTION $hostile_schema.shobj_description(oid, text) " *
                    "RETURNS text LANGUAGE sql IMMUTABLE AS " *
                    "'SELECT ''tiingo-disposable-benchmark-v1''::text'",
                    "CREATE TABLE $hostile_schema.pg_database " *
                    "(oid oid, datname name)",
                    "INSERT INTO $hostile_schema.pg_database " *
                    "VALUES (1, 'tiingojulia_benchmark')",
                    "COMMENT ON DATABASE tiingojulia_benchmark IS NULL",
                )
                    close(LibPQ.execute(connection, statement))
                end
                hostile_env = merge(benchmark_env, Dict(
                    "TIINGO_BENCH_OUTPUT" =>
                        joinpath(directory, "hostile-postgres-load.json"),
                    "TIINGO_BENCH_PG_CONNECTION" => connection_string *
                        "&options=-csearch_path%3D$hostile_schema%2Cpg_catalog%2Cpublic",
                    "TIINGO_BENCH_RUN_ID" => "contract-hostile-search-path",
                ))
                hostile_process = run(ignorestatus(setenv(command, hostile_env)))
                @test !success(hostile_process)
                mutation_check = LibPQ.execute(
                    connection,
                    "SELECT pg_catalog.to_regclass(" *
                    "'public.tiingojulia_schema_migrations') IS NULL AS absent",
                ) |> DataFrame
                @test mutation_check.absent[1]
            finally
                close(LibPQ.execute(
                    connection,
                    "COMMENT ON DATABASE tiingojulia_benchmark IS " *
                    "'tiingo-disposable-benchmark-v1'",
                ))
                close(LibPQ.execute(
                    connection,
                    "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                ))
                close(connection)
            end

            run(setenv(command, benchmark_env))
            result = JSON3.read(read(output_path, String))
            @test result.status == "passed"
            @test result.correctness.postgres.values_match

            connection = LibPQ.Connection(connection_string)
            try
                namespace = postgres_ticker_namespace(benchmark_env)
                leaked = LibPQ.execute(
                    connection,
                    "SELECT COUNT(*) AS rows FROM public.historical_data " *
                    "WHERE ticker IN (\$1, \$2)",
                    [namespace * "0001", namespace * "0002"],
                ) |> DataFrame
                @test leaked.rows[1] == 0
            finally
                close(connection)
            end
        end
    end
end
