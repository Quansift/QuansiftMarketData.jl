using Dates
using DataFrames
using DBInterface

function _canonical_security_observation_frame()::DataFrame
    return DataFrame(
        perma_ticker = String[],
        observed_at = DateTime[],
        ticker = String[],
        is_active = Bool[],
        is_adr = Union{Missing,Bool}[],
        daily_last_updated = Union{Missing,DateTime}[],
        exchange = Union{Missing,String}[],
        asset_type = Union{Missing,String}[],
        price_coverage_start = Union{Missing,Date}[],
        price_coverage_end = Union{Missing,Date}[],
        is_leveraged = Union{Missing,Bool}[],
        join_status = String[],
    )
end

function _canonical_daily_metrics_frame()::DataFrame
    return DataFrame(
        perma_ticker = String[],
        metric_date = Date[],
        market_cap = Union{Missing,Float64}[],
        enterprise_value = Union{Missing,Float64}[],
        pe_ratio = Union{Missing,Float64}[],
        available_at = Union{Missing,DateTime}[],
        fetched_at = DateTime[],
        source_revision = Union{Missing,String}[],
    )
end

function _payload_dataframe(payload)::DataFrame
    isempty(payload) && return DataFrame()
    return payload isa DataFrame ? copy(payload) : DataFrame(payload)
end

function _payload_value(row::DataFrameRow, aliases::Tuple)
    for alias in aliases
        if hasproperty(row, alias)
            value = getproperty(row, alias)
            return isnothing(value) ? missing : value
        end
    end
    return missing
end

function _required_payload_string(row::DataFrameRow, aliases::Tuple, field_name::String)::String
    value = _payload_value(row, aliases)
    ismissing(value) && throw(ArgumentError("$field_name is required"))
    normalized = strip(String(value))
    isempty(normalized) && throw(ArgumentError("$field_name cannot be empty"))
    return normalized
end

function _required_payload_date(row::DataFrameRow, aliases::Tuple, field_name::String)::Date
    value = _payload_value(row, aliases)
    ismissing(value) && throw(ArgumentError("$field_name is required"))
    return _canonical_payload_date(value, field_name)
end

function _canonical_payload_date(value, field_name::String)::Date
    value isa Date && return value
    value isa DateTime && return Date(value)
    text = String(value)
    try
        return Date(first(text, 10))
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("invalid $field_name: $error"))
    end
end

function _nullable_payload_date(value, field_name::String)::Union{Missing,Date}
    ismissing(value) && return missing
    return _canonical_payload_date(value, field_name)
end

function _nullable_payload_datetime(value, field_name::String)::Union{Missing,DateTime}
    ismissing(value) && return missing
    value isa DateTime && return value
    value isa Date && return DateTime(value)
    text = String(value)
    try
        return length(text) == 10 ? DateTime(Date(text)) : DateTime(first(text, 19))
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("invalid $field_name: $error"))
    end
end

function _nullable_payload_float(value, field_name::String)::Union{Missing,Float64}
    ismissing(value) && return missing
    value isa Real || throw(ArgumentError("$field_name must be numeric or missing"))
    return Float64(value)
end

function _nullable_payload_string(value)::Union{Missing,String}
    ismissing(value) && return missing
    return String(value)
end

function _nullable_payload_bool(value, field_name::String)::Union{Missing,Bool}
    ismissing(value) && return missing
    value isa Bool && return value
    value isa Integer && value in (0, 1) && return Bool(value)
    if value isa AbstractString
        normalized = lowercase(strip(value))
        normalized == "true" && return true
        normalized == "false" && return false
    end
    throw(ArgumentError("$field_name must be boolean or missing"))
end

function _required_payload_bool(row::DataFrameRow, aliases::Tuple, field_name::String)::Bool
    value = _nullable_payload_bool(_payload_value(row, aliases), field_name)
    ismissing(value) && throw(ArgumentError("$field_name is required"))
    return value
end

function _canonical_perma_ticker(value)::String
    normalized = strip(String(value))
    isempty(normalized) && throw(ArgumentError("permaTicker cannot be empty"))
    return normalized
end

function _count_perma_tickers(values)::Dict{String,Int}
    counts = Dict{String,Int}()
    for value in values
        (ismissing(value) || isnothing(value)) && continue
        key = _canonical_perma_ticker(value)
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function _canonical_ticker(value)::String
    normalized = uppercase(strip(String(value)))
    isempty(normalized) && throw(ArgumentError("ticker cannot be empty"))
    return normalized
end

function _count_tickers(values)::Dict{String,Int}
    counts = Dict{String,Int}()
    for value in values
        (ismissing(value) || isnothing(value)) && continue
        ticker = _canonical_ticker(value)
        counts[ticker] = get(counts, ticker, 0) + 1
    end
    return counts
end

"""
    normalize_security_observations(meta_payload, universe_payload; observed_at=Dates.now())

Reconcile Tiingo's current Fundamentals metadata snapshot with the local ticker
universe. Price coverage dates are retained only as coverage facts and are never
invented as ticker-validity dates. Every meta row is retained with a deterministic
`join_status` so unmatched, inactive, and ambiguous identities stay auditable.
"""
function normalize_security_observations(
    meta_payload,
    universe_payload;
    observed_at::DateTime = Dates.now(),
)::DataFrame
    source = _payload_dataframe(meta_payload)
    nrow(source) == 0 && return _canonical_security_observation_frame()
    universe = _payload_dataframe(universe_payload)

    :ticker in propertynames(source) || throw(ArgumentError("meta payload is missing ticker"))
    perma_values = if :permaTicker in propertynames(source)
        source.permaTicker
    elseif :perma_ticker in propertynames(source)
        source.perma_ticker
    else
        throw(ArgumentError("meta payload is missing permaTicker"))
    end
    # Ambiguity is decided among the active securities only. `!is_active` is the
    # first branch below, so an inactive row is already excluded and can never be
    # the identity this one is confused with — counting it anyway disqualifies a
    # live security for sharing a symbol with its own delisted predecessor.
    # Measured 2026-08-15: PARA had three meta rows and MSGY two, with exactly one
    # active each, and both had been dropped from the sync for three weeks. Their
    # market caps simply stopped advancing, with nothing reporting it.
    active_flags = [
        _required_payload_bool(row, (:isActive, :is_active), "isActive")
        for row in eachrow(source)
    ]
    meta_perma_counts = _count_perma_tickers(
        value for (value, active) in zip(perma_values, active_flags) if active
    )
    meta_ticker_counts = _count_tickers(
        value for (value, active) in zip(source.ticker, active_flags) if active
    )

    universe_ticker_counts = :ticker in propertynames(universe) ?
        _count_tickers(universe.ticker) : Dict{String,Int}()
    universe_by_ticker = Dict{String,DataFrameRow}()
    if :ticker in propertynames(universe)
        for row in eachrow(universe)
            (ismissing(row.ticker) || isnothing(row.ticker)) && continue
            ticker = _canonical_ticker(row.ticker)
            get(universe_ticker_counts, ticker, 0) == 1 || continue
            universe_by_ticker[ticker] = row
        end
    end

    result = _canonical_security_observation_frame()
    for row in eachrow(source)
        perma_ticker = _canonical_perma_ticker(
            _required_payload_string(
                row,
                (:permaTicker, :perma_ticker),
                "permaTicker",
            ),
        )
        ticker = _canonical_ticker(_required_payload_string(row, (:ticker,), "ticker"))
        is_active = _required_payload_bool(row, (:isActive, :is_active), "isActive")
        local_count = get(universe_ticker_counts, ticker, 0)
        local_row = get(universe_by_ticker, ticker, nothing)
        join_status = if !is_active
            "inactive"
        elseif get(meta_perma_counts, perma_ticker, 0) > 1
            "duplicate_perma_ticker"
        elseif get(meta_ticker_counts, ticker, 0) > 1
            "duplicate_ticker"
        elseif local_count == 0
            "unmatched"
        elseif local_count > 1
            "ambiguous_universe"
        else
            "matched"
        end

        local_value = aliases -> isnothing(local_row) ? missing : _payload_value(local_row, aliases)
        push!(result, (
            perma_ticker = perma_ticker,
            observed_at = observed_at,
            ticker = ticker,
            is_active = is_active,
            is_adr = _nullable_payload_bool(
                _payload_value(row, (:isADR, :is_adr)),
                "isADR",
            ),
            daily_last_updated = _nullable_payload_datetime(
                _payload_value(row, (:dailyLastUpdated, :daily_last_updated)),
                "dailyLastUpdated",
            ),
            exchange = _nullable_payload_string(local_value((:exchange,))),
            asset_type = _nullable_payload_string(
                local_value((:assetType, :assettype, :asset_type)),
            ),
            price_coverage_start = _nullable_payload_date(
                local_value((:startDate, :startdate, :start_date, :price_coverage_start)),
                "price coverage start",
            ),
            price_coverage_end = _nullable_payload_date(
                local_value((:endDate, :enddate, :end_date, :price_coverage_end)),
                "price coverage end",
            ),
            is_leveraged = _nullable_payload_bool(
                local_value((:isLeveraged, :is_leveraged)),
                "isLeveraged",
            ),
            join_status = join_status,
        ))
    end
    sort!(result, [:perma_ticker, :observed_at])
    return result
end

"""
    normalize_fundamental_daily_metrics(payload, perma_ticker; fetched_at=Dates.now(Dates.UTC))

Normalize a Tiingo Daily Metrics payload. Historical `available_at` is kept
missing unless the individual payload row explicitly supplies `availableAt`.
"""
function normalize_fundamental_daily_metrics(
    payload,
    perma_ticker::String;
    fetched_at::DateTime = Dates.now(Dates.UTC),
)::DataFrame
    normalized_perma_ticker = strip(perma_ticker)
    isempty(normalized_perma_ticker) && throw(ArgumentError("perma_ticker cannot be empty"))

    source = _payload_dataframe(payload)
    nrow(source) == 0 && return _canonical_daily_metrics_frame()

    result = _canonical_daily_metrics_frame()
    for row in eachrow(source)
        push!(result, (
            perma_ticker = normalized_perma_ticker,
            metric_date = _required_payload_date(
                row,
                (:date, :metricDate, :metric_date),
                "date",
            ),
            market_cap = _nullable_payload_float(
                _payload_value(row, (:marketCap, :market_cap)),
                "marketCap",
            ),
            enterprise_value = _nullable_payload_float(
                _payload_value(
                    row,
                    (:enterpriseVal, :enterpriseValue, :enterprise_value),
                ),
                "enterpriseVal",
            ),
            pe_ratio = _nullable_payload_float(
                _payload_value(row, (:peRatio, :pe_ratio)),
                "peRatio",
            ),
            available_at = _nullable_payload_datetime(
                _payload_value(row, (:availableAt, :available_at)),
                "availableAt",
            ),
            fetched_at = fetched_at,
            source_revision = _nullable_payload_string(
                _payload_value(row, (:sourceRevision, :source_revision)),
            ),
        ))
    end
    sort!(result, :metric_date)
    DB.Operations.validate_fundamental_daily_metrics_keys(result)
    return result
end

"""
    get_fundamental_watermarks(conn) -> Dict{String,Date}

Return the latest persisted metric date for each stable Tiingo identity.
"""
function get_fundamental_watermarks(
    conn::DBInterface.Connection,
)::Dict{String,Date}
    rows = DBInterface.execute(conn, """
        SELECT perma_ticker, MAX(metric_date) AS metric_date
        FROM fundamental_daily_metrics
        GROUP BY perma_ticker
        ORDER BY perma_ticker
    """) |> DataFrame
    return Dict(
        String(row.perma_ticker) => Date(row.metric_date)
        for row in eachrow(rows)
        if !ismissing(row.perma_ticker) && !ismissing(row.metric_date)
    )
end

function _eligible_backfill_rows(observations::DataFrame)::DataFrame
    eligible = filter(observations) do row
        row.is_active && row.join_status == "matched" &&
            !ismissing(row.asset_type) && lowercase(String(row.asset_type)) == "stock"
    end
    sort!(eligible, [:perma_ticker, :observed_at])

    return eligible
end

function _fundamental_status_counts(observations::DataFrame)::Dict{String,Int}
    status_counts = Dict{String,Int}()
    for status in observations.join_status
        status_counts[status] = get(status_counts, status, 0) + 1
    end
    return status_counts
end

"""
    collect_fundamentals(meta_payload, universe_payload; ...)

Normalize identity observations and collect Tiingo Daily Metrics without
choosing a database backend. `observation_writer` receives the complete
observation frame. `metric_writer` is called as
`metric_writer(perma_ticker, frame)`. Writers must return persisted row counts.
By default, securities without a watermark request all available history and
all supported response fields. Use `initial_start_date` or `columns` to bound
new-security requests explicitly.
Strict mode processes every eligible security and then throws
`SyncIncompleteError` if any required operation failed.
`retry_rounds` (default 0) sweeps securities whose FETCH failed with a
retryable classification after the main pass; recovered securities leave
`failed` and `failures`. It is opt-in because this entrypoint is sink-neutral
and reports complete failure records for the caller to act on.
"""
function collect_fundamentals(
    meta_payload,
    universe_payload;
    watermarks::AbstractDict = Dict{String,Date}(),
    api_key::String = get_api_key(),
    as_of::Date = Date(Dates.now()),
    initial_start_date::Union{Date,Nothing} = nothing,
    columns::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    observed_at::DateTime = Dates.now(),
    fetched_at::DateTime = Dates.now(Dates.UTC),
    daily_fetcher = get_daily_fundamental,
    observation_writer = nothing,
    metric_writer = nothing,
    continue_on_error::Bool = true,
    strict::Bool = false,
    retry_rounds::Int = 0,
)::FundamentalCollectionResult
    retry_rounds >= 0 ||
        throw(ArgumentError("retry_rounds must be non-negative"))
    !isnothing(initial_start_date) && initial_start_date > as_of &&
        throw(ArgumentError("initial_start_date must be on or before as_of"))
    normalized_watermarks = Dict(
        String(perma_ticker) => Date(metric_date)
        for (perma_ticker, metric_date) in watermarks
        if !ismissing(perma_ticker) && !isnothing(perma_ticker) &&
            !ismissing(metric_date) && !isnothing(metric_date)
    )

    observations = normalize_security_observations(
        meta_payload,
        universe_payload;
        observed_at,
    )
    eligible_securities = _eligible_backfill_rows(observations)
    attempted = String[]
    updated = String[]
    unchanged = String[]
    unavailable = String[]
    failed = String[]
    failures = SyncFailure[]
    observation_rows = 0
    metric_rows = 0

    function record_failure!(
        failure::SyncFailure,
        failure_index::Union{Int,Nothing},
    )::Int
        if isnothing(failure_index)
            push!(failed, failure.entity)
            push!(failures, failure)
            return length(failures)
        end
        failures[failure_index] = failure
        return failure_index
    end

    if !isnothing(observation_writer)
        try
            rows = observation_writer(observations)
            rows isa Integer ||
                throw(ArgumentError("observation_writer must return an integer row count"))
            rows >= 0 ||
                throw(ArgumentError("observation_writer row count must be non-negative"))
            rows <= nrow(observations) || throw(ArgumentError(
                "observation_writer row count must not exceed frame row count",
            ))
            observation_rows = rows
        catch error
            error isa InterruptException && rethrow()
            entity = "security_observations"
            push!(failed, entity)
            push!(failures, _sync_failure(entity, :write, error))
            (!continue_on_error && !strict) && rethrow()
        end
    end

    # Securities whose FETCH failed with a retryable classification, swept
    # after the main pass when `retry_rounds > 0`. Write and normalization
    # failures are never swept — a normalization failure is deterministic, and
    # re-driving writes is what turns one dead sink into a full-run cascade.
    retry_queue = Tuple{DataFrameRow,Int}[]
    recovered_failure_indices = Set{Int}()

    function record_recovery!(failure_index::Union{Int,Nothing})
        !isnothing(failure_index) && push!(recovered_failure_indices, failure_index)
        return nothing
    end

    function process_security!(
        security,
        failure_index::Union{Int,Nothing},
    )
        sweeping = !isnothing(failure_index)
        perma_ticker = String(security.perma_ticker)
        sweeping || push!(attempted, perma_ticker)
        has_watermark = haskey(normalized_watermarks, perma_ticker)
        start_date = has_watermark ?
            normalized_watermarks[perma_ticker] + Day(1) :
            initial_start_date
        if !isnothing(start_date) && start_date > as_of
            push!(unchanged, perma_ticker)
            record_recovery!(failure_index)
            return nothing
        end

        payload = try
            daily_fetcher(
                perma_ticker;
                api_key,
                start_date,
                end_date = as_of,
                columns,
                return_type = "original",
            )
        catch error
            error isa InterruptException && rethrow()
            failure = _sync_failure(perma_ticker, :fetch, error)
            failure_index = record_failure!(failure, failure_index)
            failure.retryable && push!(retry_queue, (security, failure_index))
            (!continue_on_error && !strict) && rethrow()
            return nothing
        end

        metrics = try
            normalize_fundamental_daily_metrics(
                payload,
                perma_ticker;
                fetched_at,
            )
        catch error
            error isa InterruptException && rethrow()
            record_failure!(
                _sync_failure(
                    perma_ticker,
                    :normalize,
                    error;
                    retryable = false,
                ),
                failure_index,
            )
            (!continue_on_error && !strict) && rethrow()
            return nothing
        end
        if nrow(metrics) > 0
            in_requested_range = metrics.metric_date .<= as_of
            if !isnothing(start_date)
                in_requested_range .&= metrics.metric_date .>= start_date
            end
            metrics = metrics[in_requested_range, :]
        end
        if nrow(metrics) == 0
            push!(has_watermark ? unchanged : unavailable, perma_ticker)
            record_recovery!(failure_index)
            return nothing
        end

        if !isnothing(metric_writer)
            try
                rows = metric_writer(perma_ticker, metrics)
                rows isa Integer ||
                    throw(ArgumentError("metric_writer must return an integer row count"))
                rows >= 0 ||
                    throw(ArgumentError("metric_writer row count must be non-negative"))
                rows <= nrow(metrics) || throw(ArgumentError(
                    "metric_writer row count must not exceed frame row count",
                ))
                metric_rows += rows
            catch error
                error isa InterruptException && rethrow()
                record_failure!(
                    _sync_failure(perma_ticker, :write, error; retryable=false),
                    failure_index,
                )
                (!continue_on_error && !strict) && rethrow()
                return nothing
            end
        end
        push!(updated, perma_ticker)
        record_recovery!(failure_index)
        return nothing
    end

    for security in eachrow(eligible_securities)
        process_security!(security, nothing)
    end

    for round in 1:retry_rounds
        isempty(retry_queue) && break
        round_queue = retry_queue
        # Rebinding is what makes a repeat failure land in the NEXT round's
        # queue instead of the one currently being drained.
        retry_queue = Tuple{DataFrameRow,Int}[]
        @info "Sweeping retryable Fundamentals fetch failures" round securities=length(round_queue)
        for (security, failure_index) in round_queue
            process_security!(security, failure_index)
        end
    end
    for failure_index in sort!(collect(recovered_failure_indices); rev=true)
        deleteat!(failed, failure_index)
        deleteat!(failures, failure_index)
    end

    result = FundamentalCollectionResult(
        observations,
        attempted,
        updated,
        unchanged,
        unavailable,
        failed,
        failures,
        observation_rows,
        metric_rows,
        _fundamental_status_counts(observations),
    )
    return _finish_collection(result, strict)
end

"""
    sync_fundamentals!(conn, meta_payload, universe_payload; ...)

Persist the observed current Tiingo identity mapping, then synchronize `marketCap`
Daily Metrics for active, unambiguous stocks present in the local universe.
Securities without a watermark request a three-year backfill; subsequent runs
start on the day after the stable `permaTicker` watermark. Daily Metrics are
always requested by `permaTicker`, never by the mutable ticker symbol.

`checkpoint_every` (default 100, or `FUNDAMENTALS_CHECKPOINT_EVERY`) bounds
DuckDB's memory by checkpointing after that many upsert ATTEMPTS; 0 disables
it. Without periodic checkpoints the buffer manager grows with the size of
the universe and eventually cannot allocate. The counter deliberately tracks
attempts rather than successes: when memory is tight the upserts fail, and a
success-keyed counter would stop advancing exactly when the checkpoint is
most needed.

A failed checkpoint aborts the run. DuckDB invalidates the entire database
on a checkpoint FATAL, so every later write is guaranteed to fail; carrying
on only burns API quota and buries the one useful error. Committed rows stay
in the DuckDB for the next resume.

`batch_size` (default 100, or `FUNDAMENTALS_UPSERT_BATCH`) is how many
securities are buffered per DuckDB write. Writing once per security is what
exhausted memory in production: each write registers a DataFrame with the
driver and the registration is not fully released (~2.9 MB apiece, against
33 KB for the same statement issued as pure SQL). If a batched write fails
it is retried one security at a time, so batching never coarsens which
security gets recorded as failed.

`retry_rounds` (default 1, or `FUNDAMENTALS_RETRY_ROUNDS`) sweeps securities
whose FETCH failed with a retryable classification once the main pass has
finished; 0 disables it. The sweep trails the pass instead of retrying inline
because one slow security must not stall a 5,400-security sequential run.
Write failures are never swept: after a checkpoint FATAL the database is
invalidated, so re-driving writes only reproduces the cascade.
"""
function sync_fundamentals!(
    conn::DuckDBConnection,
    meta_payload,
    universe_payload;
    api_key::String = get_api_key(),
    as_of::Date = Date(Dates.now()),
    history_years::Int = 3,
    observed_at::DateTime = Dates.now(),
    fetched_at::DateTime = Dates.now(Dates.UTC),
    daily_fetcher::Function = get_daily_fundamental,
    continue_on_error::Bool = true,
    # 100, not 500: the buffer manager was exhausted after roughly 460
    # securities on a 3.8 GiB host, so an interval anywhere near that leaves
    # no headroom. Small checkpoints are cheap; running out of memory is not.
    checkpoint_every::Int = parse(
        Int, get(ENV, "FUNDAMENTALS_CHECKPOINT_EVERY", "100"),
    ),
    # Securities buffered per DuckDB write. The driver leaks ~2.9 MB per
    # registration, so this divides the leak: 100 turns ~5,400 registrations
    # into ~54. Larger batches hold more rows in Julia memory before the
    # write, which is cheap by comparison (a batch is ~25k small rows).
    batch_size::Int = parse(
        Int, get(ENV, "FUNDAMENTALS_UPSERT_BATCH", "100"),
    ),
    # Sweeps over securities whose FETCH failed with a retryable
    # classification, after the main pass has finished. 0 disables it.
    retry_rounds::Int = parse(
        Int, get(ENV, "FUNDAMENTALS_RETRY_ROUNDS", "1"),
    ),
    checkpointer::Function = connection -> DBInterface.execute(connection, "CHECKPOINT"),
)
    history_years > 0 || throw(ArgumentError("history_years must be positive"))
    checkpoint_every >= 0 ||
        throw(ArgumentError("checkpoint_every must be non-negative"))
    batch_size > 0 || throw(ArgumentError("batch_size must be positive"))
    retry_rounds >= 0 ||
        throw(ArgumentError("retry_rounds must be non-negative"))

    observations = normalize_security_observations(
        meta_payload,
        universe_payload;
        observed_at,
    )
    observation_rows = upsert_security_observations(conn, observations)
    eligible_securities = _eligible_backfill_rows(observations)
    watermarks = get_fundamental_watermarks(conn)

    requested = String[]
    skipped = String[]
    unchanged = String[]
    unavailable = String[]
    failed = String[]
    metric_rows = 0
    # Metrics are buffered and written in batches. One DuckDB write per
    # security is what actually exhausted memory in production: each write
    # registers a DataFrame with the driver, and that registration is not
    # fully released. Measured on 2026-08-13 against the same table and the
    # same 1 GiB limit — the pure-SQL equivalent of this loop used 33 KB per
    # upsert and ran 600 iterations on 16 MB, while the Julia
    # register_data_frame path used ~2.9 MB per upsert and died at 359.
    # Batching cuts the number of registrations by batch_size, and with it
    # the leaked memory.
    pending_metrics = DataFrame[]
    pending_tickers = String[]
    # Counts securities whose metrics have been WRITTEN (attempted, not
    # necessarily stored) — the unit the checkpoint cadence is measured in.
    # Keying anything here off the success count deadlocks: once memory is
    # tight the writes start failing, the success count stops advancing, and
    # the checkpoint that would release the memory can never fire. Measured
    # on 2026-08-13 — two runs stalled at completed=461 and completed=459
    # against a 500 interval, so not one checkpoint ran.
    upsert_attempts = 0
    since_checkpoint = 0

    record_failed!(ticker::String) = ticker in failed ? nothing : push!(failed, ticker)

    # Write the buffer as one statement. On failure, retry the batch one
    # security at a time: batching must not coarsen failure attribution, or a
    # single malformed security would take out the other batch_size-1 with it
    # and the caller could not tell which one was bad. The retry only runs on
    # the failure path, so the happy path still pays for exactly one write.
    function flush_pending!()
        isempty(pending_tickers) && return nothing
        n = length(pending_tickers)
        try
            metric_rows += upsert_fundamental_daily_metrics(
                conn, reduce(vcat, pending_metrics),
            )
            append!(requested, pending_tickers)
        catch batch_error
            @warn "Batched metrics write failed; retrying one security at a time" securities=n error=sprint(showerror, batch_error)
            for (frame, ticker) in zip(pending_metrics, pending_tickers)
                try
                    metric_rows += upsert_fundamental_daily_metrics(conn, frame)
                    push!(requested, ticker)
                catch write_error
                    record_failed!(ticker)
                    if length(failed) <= 5
                        @warn "Fundamentals write failed" perma_ticker=ticker exception=(write_error, catch_backtrace())
                    else
                        @warn "Fundamentals write failed" perma_ticker=ticker error=sprint(showerror, write_error)
                    end
                end
            end
        finally
            empty!(pending_metrics)
            empty!(pending_tickers)
            upsert_attempts += n
            since_checkpoint += n
        end
        return nothing
    end

    # DuckDB holds written changes in memory until a checkpoint puts them in
    # the database file, so the buffer manager grows across a run:
    #   Out of Memory Error: failed to allocate data of size 4.0 KiB
    # Checkpointing bounds that by the interval rather than by the size of
    # the universe.
    #
    # The cadence counts securities WRITTEN, not stored, deliberately: when
    # memory is tight the writes fail, so a success-keyed counter stops
    # advancing and the checkpoint that would release the memory can never
    # run. Measured on 2026-08-13 — two runs stalled at 461 and 459 successes
    # against a 500 interval, fired zero checkpoints, and lost ~95% of
    # securities to OOM.
    #
    # A failed CHECKPOINT is NOT recoverable, so this stops the run. DuckDB
    # invalidates the whole database, not just the statement:
    #   FATAL Error: database has been invalidated because of a previous
    #   fatal error. The database must be restarted prior to being used
    #   again.
    # An earlier version warned and carried on. That turned one checkpoint
    # failure at attempt 1,400 into 3,458 failures: every later security was
    # still fetched from the API — real quota, real time — and then written to
    # a dead connection, burying the single line that explained the run under
    # ~3,300 identical cascade errors. Stopping immediately keeps the
    # diagnosis legible and leaves committed rows intact for the next resume.
    function run_checkpoint!()
        try
            checkpointer(conn)
        catch checkpoint_error
            @error "DuckDB checkpoint failed; aborting run (the database is now invalidated, so every later write would fail)" upsert_attempts securities_completed=length(requested) exception=checkpoint_error
            rethrow()
        end
        return nothing
    end

    function maybe_checkpoint!()
        if checkpoint_every > 0 && since_checkpoint >= checkpoint_every
            run_checkpoint!()
            since_checkpoint = 0
        end
        return nothing
    end

    # Securities whose FETCH failed with a retryable classification. They are
    # swept after the pass rather than retried inline: with ~5,400 sequential
    # securities an inline retry stalls the entire run behind one slow
    # security, and the nightly window does not stretch.
    #
    # Only fetch-stage failures land here. A write failure is not swept: after
    # a checkpoint FATAL the database is invalidated, so re-driving writes
    # reproduces exactly the 3,458-failure cascade described above.
    retry_queue = DataFrameRow[]

    # `sweeping` securities are already recorded in `failed`; a repeat failure
    # must not record them twice, and a recovery is removed from `failed` by
    # the caller once the flush that stores their rows has run.
    function process_security!(security, sweeping::Bool)
        perma_ticker = String(security.perma_ticker)
        has_watermark = haskey(watermarks, perma_ticker)
        start_date = has_watermark ?
            watermarks[perma_ticker] + Day(1) :
            as_of - Year(history_years)
        if start_date > as_of
            push!(skipped, perma_ticker)
            return nothing
        end

        payload = try
            daily_fetcher(
                perma_ticker;
                api_key,
                start_date,
                end_date = as_of,
                columns = ["marketCap"],
                return_type = "original",
            )
        catch error
            error isa InterruptException && rethrow()
            continue_on_error || rethrow()
            failure = _sync_failure(perma_ticker, :fetch, error)
            sweeping || record_failed!(perma_ticker)
            failure.retryable && push!(retry_queue, security)
            # Log the reason. Swallowing it silently made a 44%-failure run
            # (2,368 of 5,404 securities on 2026-08-13) indistinguishable from
            # a healthy one in the log: the caller only sees a count, and
            # FUNDAMENTALS_MAX_EXPORT_FAILURES then withholds the export with
            # no way to tell an API outage from a data bug. Only the first few
            # are logged in full — thousands of identical stacktraces would
            # bury everything else — after which one line per failure keeps
            # the record without the noise.
            if length(failed) <= 5
                @warn "Fundamentals fetch failed" perma_ticker start_date exception=(error, catch_backtrace())
            else
                @warn "Fundamentals fetch failed" perma_ticker start_date error=sprint(showerror, error)
            end
            return nothing
        end

        metrics = try
            metrics = normalize_fundamental_daily_metrics(
                payload,
                perma_ticker;
                fetched_at,
            )
            if nrow(metrics) == 0
                push!(has_watermark ? unchanged : unavailable, perma_ticker)
                return nothing
            end
            in_requested_range = (
                (metrics.metric_date .>= start_date) .&
                (metrics.metric_date .<= as_of)
            )
            metrics = metrics[in_requested_range, :]
            if nrow(metrics) == 0
                push!(has_watermark ? unchanged : unavailable, perma_ticker)
                return nothing
            end
            metrics
        catch error
            error isa InterruptException && rethrow()
            continue_on_error || rethrow()
            failure = _sync_failure(
                perma_ticker,
                :normalize,
                error;
                retryable=false,
            )
            sweeping || record_failed!(perma_ticker)
            @warn "Fundamentals normalization failed" perma_ticker start_date failure_stage=failure.stage failure_message=failure.message retryable=failure.retryable
            return nothing
        end
        push!(pending_metrics, metrics)
        push!(pending_tickers, perma_ticker)
        return nothing
    end

    for security in eachrow(eligible_securities)
        process_security!(security, false)
        length(pending_tickers) >= batch_size && flush_pending!()
        maybe_checkpoint!()
    end

    # Whatever the last partial batch holds still has to be written.
    flush_pending!()

    for round in 1:retry_rounds
        isempty(retry_queue) && break
        round_queue = retry_queue
        # Rebinding is what makes a repeat failure land in the NEXT round's
        # queue instead of the one currently being drained.
        retry_queue = DataFrameRow[]
        @info "Sweeping retryable Fundamentals fetch failures" round securities=length(round_queue)
        for security in round_queue
            process_security!(security, true)
            length(pending_tickers) >= batch_size && flush_pending!()
            maybe_checkpoint!()
        end
        flush_pending!()
        recovered = Set{String}(vcat(requested, unchanged, unavailable))
        filter!(perma_ticker -> !(perma_ticker in recovered), failed)
    end

    # Then flush DuckDB itself, so the caller's validation and export steps
    # start from a clean buffer rather than inheriting this loop's high-water
    # mark.
    if checkpoint_every > 0
        run_checkpoint!()
    end

    return (;
        observation_rows,
        metric_rows,
        requested,
        skipped,
        unchanged,
        unavailable,
        failed,
        status_counts = _fundamental_status_counts(observations),
    )
end
