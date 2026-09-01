using HTTP
using JSON3
using DataFrames
using TimeSeries
using Dates
using DotEnv
using Random

using ..Config

const ENV_LOAD_ATTEMPTED = Ref(false)

"""
Tiingo HTTP requests issued since the last reset.

Tiingo meters hourly *requests*, not tickers, and the two diverge exactly where
nobody can see: a date range longer than the chunk size becomes several
requests, and a retryable failure becomes several more. A phase that fetched
8,013 tickers may have spent well over 8,013 requests, and until this counter
existed there was no way to know by how much — the only estimate in the system
was an unmeasured `tickers * 5` upper bound.

Counted here rather than at a collection loop because this is where a request is
actually issued, so chunking and retries are included without any caller having
to remember them.

Atomic because a future caller may fetch concurrently; the cost is negligible
against an HTTP round trip and the alternative is a counter that silently
undercounts the day someone parallelises.
"""
const API_REQUEST_COUNT = Threads.Atomic{Int}(0)

"""Requests issued since the last `reset_api_request_count!`."""
api_request_count()::Int = API_REQUEST_COUNT[]

"""Zero the request counter, so one phase can be measured on its own."""
function reset_api_request_count!()::Nothing
    API_REQUEST_COUNT[] = 0
    return nothing
end

"""
Where a relative `.env` is looked for, in order: the directory the caller is
running from, then the package's own directory.

The package directory used to be the only root. For a repository checkout that
is the project root and the right answer; for a `Pkg`-installed package it is
`~/.julia/packages/<name>/<hash>/`, a directory `Pkg` owns, re-hashes on every
version change, and may garbage-collect. Naming that as the place to keep an
API key is advice nobody should follow, so the caller is consulted first. The
package directory stays as a fallback so an existing checkout keeps working.
"""
_env_search_roots() = (pwd(), dirname(@__DIR__))

function resolve_env_path(
    env_file::String;
    search_roots=_env_search_roots(),
)::String
    isabspath(env_file) && return env_file
    for root in search_roots
        candidate = joinpath(root, env_file)
        isfile(candidate) && return candidate
    end
    # Nothing on disk. Name the caller's directory, because that is where the
    # operator should create the file.
    return joinpath(first(search_roots), env_file)
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
            Set it in your shell environment, or create $resolved_env_path
            containing $(Config.API.API_KEY_NAME)=your-key. Pass env_path= to
            read a specific file instead.
        """)
    end

    return api_key
end

function _redact_api_error(error)::String
    message = error isa AbstractString ? String(error) : sprint(showerror, error)
    message = replace(
        message,
        r"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@" => s"\1[REDACTED]@",
    )
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
    NoDataError(message)

A successful response that carried no rows. The request did not fail and the
security is not broken, so this is a recorded absence rather than an error to
retry. It used to be an `ErrorException`, which left callers recovering the
fact by matching an English substring in the message. `message` is already
redacted.
"""
struct NoDataError <: Exception
    message::String
end

Base.showerror(io::IO, error::NoDataError) = print(io, error.message)

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

"""
    is_no_data_error(error)::Bool

Whether an error means the security had nothing to give, as opposed to the
request having failed. True for `NoDataError` and for an `ApiStatusError`
carrying 404 or 410, false for everything else — including an `ErrorException`
whose wording happens to mention 404 or no data, because wording is not a fact
the thrower committed to.
"""
is_no_data_error(error)::Bool =
    error isa NoDataError ||
    (error isa ApiStatusError && _is_unavailable_status(error.status))

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

# Ceiling enforced by the response stream while bytes arrive from the socket.
# The post-response check remains as a fallback for injected HTTP layers that
# return a synthetic body instead of writing to the supplied stream.
const _MAX_RESPONSE_BYTES = 64 * 1024 * 1024

struct _ResponseTooLargeError <: Exception
    received_bytes::Int
    max_bytes::Int
end

mutable struct _BoundedResponseBuffer <: IO
    buffer::IOBuffer
    max_bytes::Int
    received_bytes::Int
end

_BoundedResponseBuffer(max_bytes::Int) =
    _BoundedResponseBuffer(IOBuffer(), max_bytes, 0)

function Base.unsafe_write(
    destination::_BoundedResponseBuffer,
    pointer::Ptr{UInt8},
    byte_count::UInt,
)::Int
    received_bytes = Base.Checked.checked_add(
        destination.received_bytes,
        Int(byte_count),
    )
    if destination.max_bytes > 0 && received_bytes > destination.max_bytes
        throw(_ResponseTooLargeError(received_bytes, destination.max_bytes))
    end
    written = unsafe_write(destination.buffer, pointer, byte_count)
    destination.received_bytes += written
    return written
end

function _response_too_large_error(error)
    error isa _ResponseTooLargeError && return error
    error isa HTTP.RequestError && return _response_too_large_error(error.error)
    error isa TaskFailedException &&
        return _response_too_large_error(error.task.result)
    if error isa CompositeException
        for nested in error.exceptions
            found = _response_too_large_error(nested)
            !isnothing(found) && return found
        end
    end
    return nothing
end

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
        Threads.atomic_add!(API_REQUEST_COUNT, 1)
        @info "API request attempt $attempt for URL: $safe_url"
        response = nothing
        response_buffer = _BoundedResponseBuffer(max_response_bytes)
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
                response_stream=response_buffer,
            )
        catch e
            e isa InterruptException && rethrow()
            oversized = _response_too_large_error(e)
            if !isnothing(oversized)
                throw(ErrorException(
                    "Response from $safe_url is $(oversized.received_bytes) bytes, " *
                    "over the $(oversized.max_bytes) byte limit; refusing to read",
                ))
            end
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
            body = response.body === response_buffer ?
                take!(response_buffer.buffer) :
                response.body
            body_bytes = length(body)
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
                JSON3.read(String(body))
            catch error
                error isa InterruptException && rethrow()
                throw(ErrorException("Invalid JSON response from $safe_url"))
            end
            if isempty(data) && !allow_empty
                throw(NoDataError("No data returned from $safe_url"))
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
