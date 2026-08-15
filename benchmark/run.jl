#!/usr/bin/env julia

using BenchmarkTools
using DataFrames
using Dates
using DBInterface
using DuckDB
using JSON3
using LibPQ
using QuansiftMarketData

include(joinpath(@__DIR__, "common.jl"))
using .QuansiftMarketDataBench

const CANONICAL_EOD_SELECT =
    "ticker, date, close, high, low, open, volume, " *
    "adjclose AS \"adjClose\", adjhigh AS \"adjHigh\", " *
    "adjlow AS \"adjLow\", adjopen AS \"adjOpen\", " *
    "adjvolume AS \"adjVolume\", divcash AS \"divCash\", " *
    "splitfactor AS \"splitFactor\""

function _runtime_dependency_versions()::Dict{String,String}
    return Dict(
        "BenchmarkTools" => string(Base.pkgversion(BenchmarkTools)),
        "DBInterface" => string(Base.pkgversion(DBInterface)),
        "DataFrames" => string(Base.pkgversion(DataFrames)),
        "Dates" => string(Base.pkgversion(Dates)),
        "DuckDB" => string(Base.pkgversion(DuckDB)),
        "JSON3" => string(Base.pkgversion(JSON3)),
        "LibPQ" => string(Base.pkgversion(LibPQ)),
    )
end

function _measure_once(operation::Function)::Dict{String,Any}
    observation = @timed operation()
    return Dict{String,Any}(
        "elapsed_seconds" => observation.time,
        "allocated_bytes" => observation.bytes,
        "gc_seconds" => observation.gctime,
    )
end

function _measure_micro(
    operation::Function,
    samples::Int,
)::Dict{String,Any}
    benchmarkable = BenchmarkTools.@benchmarkable $operation() evals=1
    trial = BenchmarkTools.run(benchmarkable; samples=samples)
    estimate = BenchmarkTools.median(trial)
    return Dict{String,Any}(
        "elapsed_seconds" => estimate.time / 1.0e9,
        "allocated_bytes" => estimate.memory,
        "allocations" => estimate.allocs,
        "samples" => samples,
    )
end

function _normalized_frames(config::BenchmarkConfig)::Vector{DataFrame}
    return [synthetic_eod_frame(config, index) for index in 1:config.ticker_count]
end

function _combined_frame(
    config::BenchmarkConfig,
    frames::Vector{DataFrame},
    ticker_namespace::String,
)::DataFrame
    parts = DataFrame[]
    for (index, frame) in enumerate(frames)
        part = copy(frame)
        ticker = ticker_namespace * lpad(string(index), 4, '0')
        insertcols!(part, 1, :ticker => fill(ticker, nrow(part)))
        push!(parts, part)
    end
    return reduce(vcat, parts)
end

function _expected_stats(combined::DataFrame)
    return (
        rows=nrow(combined),
        digest=canonical_eod_digest(combined),
    )
end

function _stats_match(actual, expected)::Bool
    return actual.rows == expected.rows &&
        actual.digest == expected.digest
end

function _exercise_operation(
    operation::Function,
    inspect::Function,
    expected,
    config::BenchmarkConfig,
)::Tuple{Dict{String,Any},Dict{String,Any}}
    metrics = Dict{String,Any}()
    first_stats = nothing
    second_stats = nothing
    completed_iterations = 0
    started = time_ns()

    if config.mode == :micro
        operation() # warmup and first correctness observation, outside timing
        first_stats = inspect()
        operation() # explicit idempotency repeat, outside timing
        second_stats = inspect()
        merge!(metrics, _measure_micro(operation, config.samples))
        completed_iterations = 2 + config.samples
    elseif config.mode == :load
        first_measurement = _measure_once(operation)
        first_stats = inspect()
        second_measurement = _measure_once(operation)
        second_stats = inspect()
        metrics["first_elapsed_seconds"] = first_measurement["elapsed_seconds"]
        metrics["first_allocated_bytes"] = first_measurement["allocated_bytes"]
        metrics["repeat_elapsed_seconds"] = second_measurement["elapsed_seconds"]
        metrics["repeat_allocated_bytes"] = second_measurement["allocated_bytes"]
        completed_iterations = 2
    else
        operation() # establish state before repeated soak writes
        first_stats = inspect()
        completed_iterations = 1
        total_allocated = 0
        total_operation_seconds = 0.0
        for iteration in 1:config.iterations
            elapsed = (time_ns() - started) / 1.0e9
            iteration > 1 && elapsed >= config.max_elapsed_seconds && break
            observation = _measure_once(operation)
            total_allocated += observation["allocated_bytes"]
            total_operation_seconds += observation["elapsed_seconds"]
            completed_iterations += 1
            second_stats = inspect()
            _stats_match(second_stats, expected) || error(
                "benchmark correctness changed during soak",
            )
        end
        isnothing(second_stats) && (second_stats = inspect())
        metrics["elapsed_seconds"] = total_operation_seconds
        metrics["allocated_bytes"] = total_allocated
    end

    wall_seconds = (time_ns() - started) / 1.0e9
    wall_seconds <= config.max_elapsed_seconds || error(
        "benchmark exceeded TIINGO_BENCH_MAX_ELAPSED_SECONDS",
    )
    first_matches = _stats_match(first_stats, expected)
    second_matches = _stats_match(second_stats, expected)
    correctness = Dict{String,Any}(
        "expected_rows" => expected.rows,
        "stored_rows" => second_stats.rows,
        "expected_digest" => expected.digest,
        "stored_digest" => second_stats.digest,
        "values_match" => first_matches && second_matches,
        "idempotent" => first_stats == second_stats && second_matches,
        "completed_iterations" => completed_iterations,
    )
    all((first_matches, second_matches, correctness["idempotent"])) || error(
        "benchmark correctness or idempotency check failed",
    )
    metrics["wall_seconds"] = wall_seconds
    return metrics, correctness
end

function _duckdb_stats(connection)::NamedTuple
    frame = DBInterface.execute(
        connection,
        "SELECT $CANONICAL_EOD_SELECT " *
        "FROM historical_data ORDER BY ticker, date",
    ) |> DataFrame
    return (rows=nrow(frame), digest=canonical_eod_digest(frame))
end

function _run_duckdb(
    config::BenchmarkConfig,
    frames::Vector{DataFrame},
    expected,
)::Tuple{Dict{String,Any},Dict{String,Any}}
    return with_benchmark_tempdir() do directory
        connection = connect_duckdb(joinpath(directory, "state.duckdb"))
        try
            operation = function ()
                for (index, frame) in enumerate(frames)
                    upsert_stock_data_bulk(
                        connection,
                        frame,
                        synthetic_ticker(index),
                    )
                end
                return nothing
            end
            return _exercise_operation(
                operation,
                () -> _duckdb_stats(connection),
                expected,
                config,
            )
        finally
            close_duckdb(connection)
        end
    end
end

function _parquet_stats(path::String)::NamedTuple
    connection = DBInterface.connect(DuckDB.DB)
    try
        escaped = replace(path, "'" => "''")
        frame = DBInterface.execute(
            connection,
            "SELECT $CANONICAL_EOD_SELECT " *
            "FROM read_parquet('$escaped') ORDER BY ticker, date",
        ) |> DataFrame
        return (rows=nrow(frame), digest=canonical_eod_digest(frame))
    finally
        DBInterface.close!(connection)
    end
end

function _run_parquet(
    config::BenchmarkConfig,
    combined::DataFrame,
    expected,
)::Tuple{Dict{String,Any},Dict{String,Any}}
    return with_benchmark_tempdir() do directory
        destination = joinpath(directory, "prices.parquet")
        operation = () -> write_parquet(combined, destination; overwrite=true)
        return _exercise_operation(
            operation,
            () -> _parquet_stats(destination),
            expected,
            config,
        )
    end
end

function _postgres_command(
    connection::LibPQ.Connection,
    sql::String,
    tickers::Vector{String},
)
    close(LibPQ.execute(connection, sql, tickers))
    return nothing
end

function _postgres_placeholders(count::Int)::String
    count > 0 || throw(ArgumentError("PostgreSQL benchmark ticker set is empty"))
    return join(("\$$(index)" for index in 1:count), ", ")
end

function _verify_postgres_disposable!(
    connection::LibPQ.Connection,
    expected_database::String,
)
    result = LibPQ.execute(
        connection,
        "SELECT pg_catalog.current_database() AS database_name, " *
        "pg_catalog.shobj_description(oid, 'pg_database') AS marker " *
        "FROM pg_catalog.pg_database " *
        "WHERE datname = pg_catalog.current_database()",
    )
    try
        frame = DataFrame(result)
        nrow(frame) == 1 || throw(ArgumentError(
            "PostgreSQL benchmark could not verify database identity",
        ))
        String(frame.database_name[1]) == expected_database || throw(ArgumentError(
            "PostgreSQL benchmark database identity mismatch",
        ))
        marker = frame.marker[1]
        !ismissing(marker) && String(marker) == POSTGRES_DISPOSABLE_MARKER ||
            throw(ArgumentError(
                "PostgreSQL benchmark server is missing the disposable marker",
            ))
    finally
        close(result)
    end
    return nothing
end

function _postgres_stats(
    connection::LibPQ.Connection,
    tickers::Vector{String},
)::NamedTuple
    placeholders = _postgres_placeholders(length(tickers))
    sql = "SELECT $CANONICAL_EOD_SELECT FROM \"public\".\"historical_data\" " *
          "WHERE ticker IN ($placeholders) ORDER BY ticker, date"
    result = LibPQ.execute(connection, sql, tickers)
    try
        frame = DataFrame(result)
        return (rows=nrow(frame), digest=canonical_eod_digest(frame))
    finally
        close(result)
    end
end

function _cleanup_postgres_tickers!(
    connection::LibPQ.Connection,
    tickers::Vector{String},
)
    placeholders = _postgres_placeholders(length(tickers))
    sql = "DELETE FROM \"public\".\"historical_data\" " *
          "WHERE ticker IN ($placeholders)"
    return _postgres_command(connection, sql, tickers)
end

function _run_postgres(
    config::BenchmarkConfig,
    frames::Vector{DataFrame},
    expected;
    tickers::Vector{String},
    env=ENV,
)::Tuple{Dict{String,Any},Dict{String,Any}}
    connection_string = require_postgres_access(config; env)
    expected_database = require_postgres_database(env)
    connection = connect_postgres(connection_string; max_retries=1)
    schema_ready = false
    try
        _verify_postgres_disposable!(connection, expected_database)
        migrate_postgres!(connection)
        schema_ready = true
        _cleanup_postgres_tickers!(connection, tickers)
        operation = function ()
            for (ticker, frame) in zip(tickers, frames)
                upsert_stock_data_bulk(
                    connection,
                    frame,
                    ticker,
                )
            end
            return nothing
        end
        return _exercise_operation(
            operation,
            () -> _postgres_stats(connection, tickers),
            expected,
            config,
        )
    finally
        try
            schema_ready && _cleanup_postgres_tickers!(connection, tickers)
        finally
            close_postgres(connection)
        end
    end
end

function run_benchmark(config::BenchmarkConfig; env=ENV)::Dict{String,Any}
    validate_config(config)
    rss_before = current_rss_bytes()
    payloads = [
        synthetic_eod_payload(config, index) for index in 1:config.ticker_count
    ]
    normalization = () -> [
        normalize_eod_prices(
            payload;
            start_date=first(payload.date),
            end_date=last(payload.date),
        ) for payload in payloads
    ]
    normalization() # compile/warm outside timed expression
    normalization_metrics = config.mode == :micro ?
        _measure_micro(normalization, config.samples) : _measure_once(normalization)

    frames = _normalized_frames(config)
    ticker_namespace = config.sink == :postgres ?
        postgres_ticker_namespace(env) : "SYN"
    tickers = [
        ticker_namespace * lpad(string(index), 4, '0')
        for index in 1:config.ticker_count
    ]
    combined = _combined_frame(config, frames, ticker_namespace)
    expected = _expected_stats(combined)
    metrics = Dict{String,Any}(
        "normalization" => normalization_metrics,
        "rss_before_bytes" => rss_before,
        "observations_report_only" => true,
    )
    correctness = Dict{String,Any}(
        "expected_rows" => expected.rows,
        "cleanup" => true,
    )

    selected_sinks = config.sink == :local ? (:duckdb, :parquet) : (config.sink,)
    for sink in selected_sinks
        sink_metrics, sink_correctness = if sink == :duckdb
            _run_duckdb(config, frames, expected)
        elseif sink == :parquet
            _run_parquet(config, combined, expected)
        else
            _run_postgres(config, frames, expected; tickers, env)
        end
        metrics[string(sink)] = sink_metrics
        correctness[string(sink)] = sink_correctness
    end
    metrics["rss_after_bytes"] = current_rss_bytes()
    return result_document(
        config;
        metrics,
        correctness,
        dependency_versions=_runtime_dependency_versions(),
    )
end

function main(args=ARGS; env=ENV)::Int
    length(args) == 1 || throw(ArgumentError(
        "usage: julia --project=benchmark benchmark/run.jl micro|load|soak",
    ))
    mode = Symbol(lowercase(args[1]))
    config = config_from_env(mode; env)
    try
        document = run_benchmark(config; env)
        destination = write_result(config.output_path, document)
        println("benchmark status=passed mode=$(config.mode) sink=$(config.sink) " *
                "result=$destination")
        return 0
    catch error
        failure = result_document(
            config;
            status="failed",
            metrics=Dict(
                "rss_after_bytes" => current_rss_bytes(),
                "observations_report_only" => true,
            ),
            correctness=Dict(
                "error_type" => string(nameof(typeof(error))),
                "cleanup" => false,
            ),
            dependency_versions=_runtime_dependency_versions(),
        )
        try
            write_result(config.output_path, failure)
        catch
        end
        rethrow()
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
