"""
    SyncFailure

Machine-readable failure for one collection or persistence operation. `message`
is sanitized before storage so API and database credentials are not exposed to
callers.
"""
struct SyncFailure
    entity::String
    stage::Symbol
    message::String
    retryable::Bool
end

"""
    HistoricalCollectionResult

Completion details for a sink-neutral EOD collection run.
"""
struct HistoricalCollectionResult
    attempted::Vector{String}
    updated::Vector{String}
    unchanged::Vector{String}
    unavailable::Vector{String}
    failed::Vector{String}
    failures::Vector{SyncFailure}
    written_rows::Int
end

"""
    FundamentalCollectionResult

Completion details for a sink-neutral Fundamentals collection run.
`observation_rows` and `metric_rows` count rows accepted by the supplied
writers; both are zero when no writer is supplied.
"""
struct FundamentalCollectionResult
    observations::DataFrame
    attempted::Vector{String}
    updated::Vector{String}
    unchanged::Vector{String}
    unavailable::Vector{String}
    failed::Vector{String}
    failures::Vector{SyncFailure}
    observation_rows::Int
    metric_rows::Int
    status_counts::Dict{String,Int}
end

"""
    SyncIncompleteError(result)

Raised by strict collection entrypoints after all eligible entities have been
processed and at least one required operation failed.
"""
struct SyncIncompleteError <: Exception
    result::Union{HistoricalCollectionResult,FundamentalCollectionResult}
end

function Base.showerror(io::IO, error::SyncIncompleteError)
    result = error.result
    print(
        io,
        "sync incomplete: ",
        length(result.failed),
        " failed entit",
        length(result.failed) == 1 ? "y" : "ies",
    )
end

function _sync_failure(
    entity::AbstractString,
    stage::Symbol,
    error;
    retryable::Union{Bool,Nothing} = nothing,
)::SyncFailure
    message = API._redact_api_error(error)
    message = replace(
        message,
        r"(?i)(postgres(?:ql)?://)[^@\s]+@" => s"\1[REDACTED]@",
    )
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
    normalized = lowercase(message)
    # Prefer the status the error carries. Substring matching is the fallback
    # for errors that never had one — an injected fetcher, a driver error, a
    # normalization failure — and is fragile by nature: an upstream wording
    # change would otherwise silently reclassify every failure of that kind.
    inferred_retryable = if error isa API.ApiStatusError
        API._is_retryable_status(error.status)
    else
        occursin("timeout", normalized) ||
            occursin("timed out", normalized) ||
            occursin("temporary", normalized) ||
            occursin("connection reset", normalized) ||
            occursin("rate limit", normalized) ||
            occursin(r"\b(?:429|5\d\d)\b", normalized)
    end
    return SyncFailure(
        String(entity),
        stage,
        message,
        stage == :write ? false : something(retryable, inferred_retryable),
    )
end

function _finish_collection(result, strict::Bool)
    strict && !isempty(result.failures) && throw(SyncIncompleteError(result))
    return result
end
