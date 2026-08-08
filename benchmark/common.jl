module TiingoBench

using DataFrames
using Dates
using JSON3
using SHA
using Tiingo

export BENCHMARK_RESULT_SCHEMA_VERSION
export MAX_TICKERS, MAX_TRADING_DAYS, MAX_SAMPLES, MAX_ITERATIONS
export MAX_ELAPSED_SECONDS
export BenchmarkConfig, config_from_env, validate_config
export synthetic_eod_payload, synthetic_eod_frame, synthetic_ticker
export with_benchmark_tempdir, require_postgres_access
export require_postgres_database, postgres_ticker_namespace
export canonical_eod_digest, POSTGRES_DISPOSABLE_MARKER
export environment_metadata, result_document, write_result
export current_rss_bytes

const BENCHMARK_RESULT_SCHEMA_VERSION = 1
const MAX_TICKERS = 250
const MAX_TRADING_DAYS = 5_000
const MAX_SAMPLES = 20
const MAX_ITERATIONS = 500
const MAX_ELAPSED_SECONDS = 3_600
const POSTGRES_DISPOSABLE_ACK = "I_ACKNOWLEDGE_THIS_DATABASE_IS_DISPOSABLE"
const POSTGRES_DISPOSABLE_MARKER = "tiingo-disposable-benchmark-v1"
const VALID_MODES = (:micro, :load, :soak)
const VALID_SINKS = (:local, :duckdb, :parquet, :postgres)
const CANONICAL_EOD_COLUMNS = [
    :ticker, :date, :close, :high, :low, :open, :volume, :adjClose,
    :adjHigh, :adjLow, :adjOpen, :adjVolume, :divCash, :splitFactor,
]

Base.@kwdef struct BenchmarkConfig
    mode::Symbol = :micro
    seed::Int = 20_260_802
    ticker_count::Int = 2
    trading_day_count::Int = 5
    samples::Int = 1
    iterations::Int = 2
    max_elapsed_seconds::Int = 60
    sink::Symbol = :local
    output_path::String = joinpath("benchmark", "result.json")
end

const MODE_DEFAULTS = Dict(
    :micro => (
        ticker_count=2,
        trading_day_count=5,
        samples=1,
        iterations=2,
        max_elapsed_seconds=90,
    ),
    :load => (
        ticker_count=25,
        trading_day_count=252,
        samples=1,
        iterations=2,
        max_elapsed_seconds=300,
    ),
    :soak => (
        ticker_count=10,
        trading_day_count=60,
        samples=1,
        iterations=20,
        max_elapsed_seconds=900,
    ),
)

function _parse_env_int(env, name::String, default::Int)::Int
    raw = strip(String(get(env, name, string(default))))
    try
        return parse(Int, raw)
    catch
        throw(ArgumentError("$name must be an integer"))
    end
end

function validate_config(config::BenchmarkConfig)::BenchmarkConfig
    config.mode in VALID_MODES || throw(ArgumentError(
        "benchmark mode must be one of $(join(string.(VALID_MODES), ", "))",
    ))
    config.sink in VALID_SINKS || throw(ArgumentError(
        "TIINGO_BENCH_SINK must be one of $(join(string.(VALID_SINKS), ", "))",
    ))
    for (name, value, maximum) in (
        ("TIINGO_BENCH_TICKERS", config.ticker_count, MAX_TICKERS),
        ("TIINGO_BENCH_DAYS", config.trading_day_count, MAX_TRADING_DAYS),
        ("TIINGO_BENCH_SAMPLES", config.samples, MAX_SAMPLES),
        ("TIINGO_BENCH_ITERATIONS", config.iterations, MAX_ITERATIONS),
        (
            "TIINGO_BENCH_MAX_ELAPSED_SECONDS",
            config.max_elapsed_seconds,
            MAX_ELAPSED_SECONDS,
        ),
    )
        1 <= value <= maximum || throw(ArgumentError(
            "$name must be between 1 and $maximum",
        ))
    end
    isempty(strip(config.output_path)) && throw(ArgumentError(
        "TIINGO_BENCH_OUTPUT must not be empty",
    ))
    return config
end

function config_from_env(mode::Symbol; env=ENV)::BenchmarkConfig
    mode in VALID_MODES || throw(ArgumentError(
        "benchmark mode must be one of $(join(string.(VALID_MODES), ", "))",
    ))
    defaults = MODE_DEFAULTS[mode]
    config = BenchmarkConfig(
        mode=mode,
        seed=_parse_env_int(env, "TIINGO_BENCH_SEED", 20_260_802),
        ticker_count=_parse_env_int(
            env,
            "TIINGO_BENCH_TICKERS",
            defaults.ticker_count,
        ),
        trading_day_count=_parse_env_int(
            env,
            "TIINGO_BENCH_DAYS",
            defaults.trading_day_count,
        ),
        samples=_parse_env_int(env, "TIINGO_BENCH_SAMPLES", defaults.samples),
        iterations=_parse_env_int(
            env,
            "TIINGO_BENCH_ITERATIONS",
            defaults.iterations,
        ),
        max_elapsed_seconds=_parse_env_int(
            env,
            "TIINGO_BENCH_MAX_ELAPSED_SECONDS",
            defaults.max_elapsed_seconds,
        ),
        sink=Symbol(lowercase(strip(String(get(
            env,
            "TIINGO_BENCH_SINK",
            "local",
        ))))),
        output_path=String(get(
            env,
            "TIINGO_BENCH_OUTPUT",
            joinpath("benchmark", "$(mode)-result.json"),
        )),
    )
    return validate_config(config)
end

synthetic_ticker(index::Integer)::String = "SYN" * lpad(string(index), 4, '0')

function _canonical_digest_value(value)::String
    if ismissing(value)
        return "missing"
    elseif value isa AbstractFloat
        return bitstring(Float32(value))
    elseif value isa Date
        return Dates.format(value, dateformat"yyyy-mm-dd")
    end
    return string(value)
end

"""Return a deterministic digest of every ordered canonical EOD key/value."""
function canonical_eod_digest(frame::AbstractDataFrame)::String
    missing_columns = setdiff(CANONICAL_EOD_COLUMNS, propertynames(frame))
    isempty(missing_columns) || throw(ArgumentError(
        "canonical benchmark frame is missing: $(join(missing_columns, ", "))",
    ))
    ordered = sort(select(frame, CANONICAL_EOD_COLUMNS), [:ticker, :date])
    buffer = IOBuffer()
    for column in CANONICAL_EOD_COLUMNS
        label = String(column)
        write(buffer, string(ncodeunits(label)), ':', label, ';')
    end
    write(buffer, '\n')
    for row in eachrow(ordered), column in CANONICAL_EOD_COLUMNS
        encoded = _canonical_digest_value(row[column])
        write(buffer, string(ncodeunits(encoded)), ':', encoded, ';')
    end
    return bytes2hex(SHA.sha256(take!(buffer)))
end

function _trading_dates(start_date::Date, count::Int)::Vector{Date}
    dates = Date[]
    candidate = start_date
    while length(dates) < count
        dayofweek(candidate) <= 5 && push!(dates, candidate)
        candidate += Day(1)
    end
    return dates
end

function synthetic_eod_payload(
    config::BenchmarkConfig,
    ticker_index::Integer,
)::DataFrame
    validate_config(config)
    1 <= ticker_index <= config.ticker_count || throw(ArgumentError(
        "ticker_index must be between 1 and $(config.ticker_count)",
    ))
    start_date = Date(2010, 1, 4) + Day(mod(config.seed, 3_650))
    dates = _trading_dates(start_date, config.trading_day_count)
    seed_component = mod(config.seed, 10_000) / 10_000
    base = 40.0 + 5.0 * ticker_index + seed_component
    closes = [base + 0.125 * row for row in eachindex(dates)]
    volumes = Int64[
        100_000 + mod(config.seed + 1_009 * ticker_index + 97 * row, 900_000)
        for row in eachindex(dates)
    ]
    return DataFrame(
        date=dates,
        close=closes,
        high=closes .+ 1.0,
        low=closes .- 1.0,
        open=closes .- 0.25,
        volume=volumes,
        adjClose=closes,
        adjHigh=closes .+ 1.0,
        adjLow=closes .- 1.0,
        adjOpen=closes .- 0.25,
        adjVolume=volumes,
        divCash=zeros(Float64, length(dates)),
        splitFactor=ones(Float64, length(dates)),
    )
end

function synthetic_eod_frame(
    config::BenchmarkConfig,
    ticker_index::Integer,
)::DataFrame
    payload = synthetic_eod_payload(config, ticker_index)
    return normalize_eod_prices(
        payload;
        start_date=first(payload.date),
        end_date=last(payload.date),
    )
end

function with_benchmark_tempdir(f::Function)
    directory = mktempdir(; prefix="tiingo-benchmark-")
    try
        return f(directory)
    finally
        ispath(directory) && rm(directory; recursive=true, force=true)
    end
end

function _strict_true(env, name::String)::Bool
    return lowercase(strip(String(get(env, name, "")))) == "true"
end

function require_postgres_database(env=ENV)::String
    database = String(strip(String(get(env, "TIINGO_BENCH_PG_DATABASE", ""))))
    occursin(r"^[a-z][a-z0-9_]{0,62}$", database) || throw(ArgumentError(
        "TIINGO_BENCH_PG_DATABASE must be an exact lowercase database identity",
    ))
    return database
end

function postgres_ticker_namespace(env=ENV)::String
    run_id = String(strip(String(get(env, "TIINGO_BENCH_RUN_ID", ""))))
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", run_id) || throw(ArgumentError(
        "TIINGO_BENCH_RUN_ID must contain 1-64 safe identifier characters",
    ))
    digest = uppercase(bytes2hex(SHA.sha256(codeunits(run_id)))[1:16])
    return "TB" * digest
end

function require_postgres_access(config::BenchmarkConfig; env=ENV)
    config.sink == :postgres || return nothing
    connection = String(strip(String(get(env, "TIINGO_BENCH_PG_CONNECTION", ""))))
    isempty(connection) && throw(ArgumentError(
        "PostgreSQL benchmarks require TIINGO_BENCH_PG_CONNECTION",
    ))
    _strict_true(env, "TIINGO_BENCH_POSTGRES_ISOLATED") || throw(ArgumentError(
        "PostgreSQL benchmarks require TIINGO_BENCH_POSTGRES_ISOLATED=true",
    ))
    acknowledgement = String(get(env, "TIINGO_BENCH_POSTGRES_DISPOSABLE", ""))
    acknowledgement == POSTGRES_DISPOSABLE_ACK || throw(ArgumentError(
        "PostgreSQL benchmarks require explicit disposable-database acknowledgement",
    ))
    require_postgres_database(env)
    postgres_ticker_namespace(env)
    return connection
end

function _package_version(package)::String
    version = Base.pkgversion(package)
    return isnothing(version) ? "unknown" : string(version)
end

function environment_metadata(
    additional_dependency_versions::AbstractDict=Dict{String,String}(),
)::Dict{String,Any}
    dependencies = Dict{String,Any}(
        "DataFrames" => _package_version(DataFrames),
        "JSON3" => _package_version(JSON3),
    )
    merge!(
        dependencies,
        Dict(string(name) => string(version) for
             (name, version) in additional_dependency_versions),
    )
    return Dict{String,Any}(
        "julia_version" => string(VERSION),
        "package_version" => _package_version(Tiingo),
        "dependency_versions" => dependencies,
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "cpu_threads" => Sys.CPU_THREADS,
    )
end

function _config_metadata(config::BenchmarkConfig)::Dict{String,Any}
    return Dict{String,Any}(
        "mode" => string(config.mode),
        "seed" => config.seed,
        "ticker_count" => config.ticker_count,
        "trading_day_count" => config.trading_day_count,
        "samples" => config.samples,
        "iterations" => config.iterations,
        "max_elapsed_seconds" => config.max_elapsed_seconds,
        "sink" => string(config.sink),
    )
end

function result_document(
    config::BenchmarkConfig;
    git_sha::AbstractString=get(ENV, "GITHUB_SHA", "unknown"),
    metrics::AbstractDict=Dict{String,Any}(),
    correctness::AbstractDict=Dict{String,Any}(),
    status::AbstractString="passed",
    dependency_versions::AbstractDict=Dict{String,String}(),
)::Dict{String,Any}
    validate_config(config)
    status in ("passed", "failed") || throw(ArgumentError(
        "benchmark result status must be passed or failed",
    ))
    return Dict{String,Any}(
        "schema_version" => BENCHMARK_RESULT_SCHEMA_VERSION,
        "status" => String(status),
        "git_sha" => String(git_sha),
        "environment" => environment_metadata(dependency_versions),
        "config" => _config_metadata(config),
        "metrics" => Dict{String,Any}(string(key) => value for (key, value) in metrics),
        "correctness" =>
            Dict{String,Any}(string(key) => value for (key, value) in correctness),
    )
end

function write_result(path::AbstractString, document::AbstractDict)::String
    destination = abspath(String(path))
    mkpath(dirname(destination))
    temporary, io = mktemp(dirname(destination); cleanup=false)
    try
        JSON3.write(io, document)
        write(io, '\n')
        close(io)
        mv(temporary, destination; force=true)
    catch
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary; force=true)
        rethrow()
    end
    return destination
end

function current_rss_bytes()::Int
    try
        return Int(Sys.maxrss())
    catch
        return 0
    end
end

end
