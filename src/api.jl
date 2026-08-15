using HTTP
using JSON3
using DataFrames
using TimeSeries
using Dates
using DotEnv
using Random

using ..Config

const ENV_LOAD_ATTEMPTED = Ref(false)

function resolve_env_path(env_file::String)::String
    return isabspath(env_file) ? env_file : joinpath(dirname(@__DIR__), env_file)
end

"""
    load_env_file(env_path::String)::Bool

Load environment variables from .env file.
Returns true if successful, false otherwise.
"""
function load_env_file(env_path::String; override::Bool=false)::Bool
    try
        if isfile(env_path)
            DotEnv.load!(env_path; override=override)
            return true
        end
        return false
    catch e
        @warn "Failed to load .env file" exception=e
        return false
    end
end

"""
    get_api_key(; env_path::Union{String,Nothing}=nothing, reload_env::Bool=false)::String

Retrieve the Tiingo API key from environment variables or .env file.
Throws an error if the API key is not found.
"""
function get_api_key(; env_path::Union{String,Nothing}=nothing, reload_env::Bool=false)::String
    resolved_env_path = isnothing(env_path) ? resolve_env_path(Config.API.ENV_FILE) : env_path

    if reload_env || !ENV_LOAD_ATTEMPTED[]
        load_env_file(resolved_env_path)
        ENV_LOAD_ATTEMPTED[] = true
    end

    api_key = strip(get(ENV, Config.API.API_KEY_NAME, ""))
    if isempty(api_key)
        error("""
            $(Config.API.API_KEY_NAME) not found in environment variables.
            Set it in your shell environment or in: $resolved_env_path
        """)
    end

    return api_key
end

function _redact_api_error(error)::String
    message = error isa AbstractString ? String(error) : sprint(showerror, error)
    message = replace(
        message,
        r"(?i)((?:[\"']|%22)?authorization(?:[\"']|%22)?(?:\s|%20)*(?::|=>|=|%3d|%3a)(?:\s|%20)*(?:[\"']|%22)?(?:token|bearer)(?:\s+|%20))[^\s,;}\"'<>#]+" => s"\1[REDACTED]",
    )
    return replace(
        message,
        r"(?i)((?:[\"']|%22)?(?:token|apikey|api(?:_|-|%5f|%2d)key)(?:[\"']|%22)?(?:\s|%20)*(?::|=>|=|%3d|%3a)(?:\s|%20)*(?:[\"']|%22)?)[^&\s,;}\"'<>#]+" => s"\1[REDACTED]",
    )
end

"""
    ApiStatusError(status, message)

A non-success HTTP response, carrying the status alongside the sanitized
message. Downstream classification used to recover the status by matching
English substrings in the message, which made an upstream wording change
enough to silently reclassify every failure of that kind.
"""
struct ApiStatusError <: Exception
    status::Int
    message::String
end

Base.showerror(io::IO, error::ApiStatusError) = print(io, error.message)

"""
    _is_retryable_status(status)

Whether a status is worth another attempt: rate limiting and server-side
failures are transient, everything else is the caller's problem.
"""
_is_retryable_status(status::Integer)::Bool =
    status == 429 || (500 <= status <= 599)

"""
    _is_unavailable_status(status)

Whether a status means the security has no data to give, as opposed to the
request having failed. Unavailable is a recorded outcome, not a failure.
"""
_is_unavailable_status(status::Integer)::Bool = status == 404 || status == 410

function _http_status_error(status, url, _body)::ApiStatusError
    safe_url = _redact_api_error(url)
    return ApiStatusError(
        Int(status),
        "HTTP $status for $safe_url; response body omitted",
    )
end

const _MAX_RETRY_DELAY_SECONDS = 300

# Fraction of the computed delay that jitter may add.
const _RETRY_JITTER_FRACTION = 0.25

"""
    _jittered_delay_seconds(delay; rng=Random.default_rng())

Spread a retry delay so concurrent callers do not re-burst in lockstep.

The jitter is additive only. `Retry-After` is an instruction from the server,
and a jitter able to undercut it would turn politeness into a second wave of
429s — so the wait may grow, never shrink, and never past the ceiling.
"""
function _jittered_delay_seconds(
    delay::Real;
    rng::Random.AbstractRNG = Random.default_rng(),
)::Float64
    delay <= 0 && return float(delay)
    jitter = rand(rng) * _RETRY_JITTER_FRACTION * delay
    return min(float(delay) + jitter, float(_MAX_RETRY_DELAY_SECONDS))
end

# Ceiling on a response body before it is handed to the JSON parser. The body
# is one allocation; parsing it into JSON3 and then a DataFrame multiplies it
# many times over, so the useful place to stop is between the two. This does
# NOT bound the socket read — HTTP.get returns with the body already in
# memory — it bounds the blow-up that follows.
const _MAX_RESPONSE_BYTES = 64 * 1024 * 1024

function _retry_delay_seconds(
    base_delay::Int,
    attempt::Int,
    retry_after,
    now::DateTime,
)::Int
    fallback = clamp(base_delay, 0, _MAX_RETRY_DELAY_SECONDS)
    remaining_doublings = max(attempt - 1, 0)
    while fallback > 0 && fallback < _MAX_RETRY_DELAY_SECONDS && remaining_doublings > 0
        fallback = min(fallback * 2, _MAX_RETRY_DELAY_SECONDS)
        remaining_doublings -= 1
    end
    server_delay = nothing

    if retry_after !== nothing
        value = strip(String(retry_after))
        delta_seconds = tryparse(Int, value)
        if delta_seconds !== nothing
            delta_seconds >= 0 && (server_delay = delta_seconds)
        elseif endswith(value, " GMT")
            retry_at = tryparse(
                DateTime,
                chop(value; tail=4),
                Dates.RFC1123Format,
            )
            if retry_at !== nothing && retry_at > now
                server_delay = ceil(Int, Dates.value(retry_at - now) / 1_000)
            end
        end
    end

    return clamp(max(fallback, something(server_delay, fallback)), 0, _MAX_RETRY_DELAY_SECONDS)
end


"""
    get_ticker_data(
        ticker_info::DataFrameRow;
        start_date::Union{Date,Nothing} = nothing,
        end_date::Union{Date,Nothing} = nothing,
        api_key::String = get_api_key(),
        base_url::String = "https://api.tiingo.com/tiingo/daily"
    )::DataFrame

Get historical data for a given ticker from Tiingo API.
"""
function get_ticker_data(
    ticker_info::DataFrameRow;
    start_date::Union{Date,Nothing} = nothing,
    end_date::Union{Date,Nothing} = nothing,
    api_key::String = get_api_key(),
    base_url::String = Config.API.BASE_URL
)::DataFrame
    ticker = ticker_info.ticker
    actual_start_date = something(start_date, ticker_info.start_date)
    actual_end_date = something(end_date, ticker_info.end_date)

    headers = Dict("Authorization" => "Token $api_key")
    url = "$base_url/$ticker/prices"
    query = Dict(
        "startDate" => Dates.format(actual_start_date, "yyyy-mm-dd"),
        "endDate" => Dates.format(actual_end_date, "yyyy-mm-dd")
    )

    @info "Fetching price data for $ticker from $actual_start_date to $actual_end_date"
    data = fetch_api_data(url, query, headers)

    return DataFrame(data)
end


"""
    fetch_api_data(url::String, query::Dict, headers::Dict; max_retries::Int=3, allow_empty::Bool=false)

Fetch data from API with retry logic and error handling.
"""
function fetch_api_data(
    url::String,
    query::Dict,
    headers::Dict;
    max_retries::Int = Config.API.MAX_RETRIES,
    retry_delay::Int = Config.API.RETRY_DELAY,
    connect_timeout::Real = 10,
    readtimeout::Real = 30,
    allow_empty::Bool = false,
    max_response_bytes::Int = _MAX_RESPONSE_BYTES,
)
    last_error = nothing

    if max_retries < 1
        throw(ArgumentError("max_retries must be >= 1"))
    end

    if max_response_bytes < 0
        throw(ArgumentError("max_response_bytes must be non-negative"))
    end

    safe_url = _redact_api_error(url)

    for attempt in 1:max_retries
        @info "API request attempt $attempt for URL: $safe_url"
        response = nothing
        try
            response = HTTP.get(
                url,
                query=query,
                headers=headers,
                connect_timeout=connect_timeout,
                readtimeout=readtimeout,
                status_exception=false,
                retry=false,
                redirect=false,
            )
        catch e
            e isa InterruptException && rethrow()
            safe_error = ErrorException(_redact_api_error(e))
            last_error = safe_error
            @warn "API request attempt $attempt failed" error=safe_error.msg

            if attempt < max_retries
                delay = _retry_delay_seconds(
                    retry_delay,
                    attempt,
                    nothing,
                    Dates.now(Dates.UTC),
                )
                sleep(_jittered_delay_seconds(delay))
                continue
            else
                throw(safe_error)
            end
        end

        status = response.status
        if status == 200
            body_bytes = length(response.body)
            if max_response_bytes > 0 && body_bytes > max_response_bytes
                # Permanent for this request, so it is thrown rather than
                # retried: re-downloading an oversized response is the one
                # thing that makes an oversized response worse.
                throw(ErrorException(
                    "Response from $safe_url is $body_bytes bytes, over the " *
                    "$max_response_bytes byte limit; refusing to parse",
                ))
            end
            data = try
                JSON3.read(String(response.body))
            catch error
                error isa InterruptException && rethrow()
                throw(ErrorException("Invalid JSON response from $safe_url"))
            end
            if isempty(data) && !allow_empty
                throw(ErrorException("No data returned from $safe_url"))
            end
            return data
        end

        retryable = _is_retryable_status(status)
        err = _http_status_error(status, url, response.body)
        last_error = err

        if retryable && attempt < max_retries
            retry_after = HTTP.header(response, "Retry-After")
            delay = _retry_delay_seconds(
                retry_delay,
                attempt,
                retry_after,
                Dates.now(Dates.UTC),
            )
            @warn "API request retryable failure" status=status delay_seconds=delay
            sleep(_jittered_delay_seconds(delay))
        else
            throw(err)
        end
    end

    # Fallback; this should be unreachable but keeps return path explicit
    if last_error !== nothing
        throw(last_error)
    end
end
