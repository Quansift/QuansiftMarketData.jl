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

function _count_values(values)::Dict{String,Int}
    counts = Dict{String,Int}()
    for value in values
        ismissing(value) && continue
        key = String(value)
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
    meta_perma_counts = _count_values(perma_values)
    meta_ticker_counts = _count_tickers(source.ticker)

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
        perma_ticker = _required_payload_string(
            row,
            (:permaTicker, :perma_ticker),
            "permaTicker",
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
    normalize_fundamental_daily_metrics(payload, perma_ticker; fetched_at=Dates.now())

Normalize a Tiingo Daily Metrics payload. Historical `available_at` is kept
missing unless the individual payload row explicitly supplies `availableAt`.
"""
function normalize_fundamental_daily_metrics(
    payload,
    perma_ticker::String;
    fetched_at::DateTime = Dates.now(),
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

    seen_perma = Set{String}()
    seen_ticker = Set{String}()
    for row in eachrow(eligible)
        perma_ticker = String(row.perma_ticker)
        ticker = String(row.ticker)
        perma_ticker in seen_perma && throw(ArgumentError(
            "multiple eligible rows for permaTicker $perma_ticker",
        ))
        ticker in seen_ticker && throw(ArgumentError(
            "multiple eligible rows for ticker $ticker",
        ))
        push!(seen_perma, perma_ticker)
        push!(seen_ticker, ticker)
    end
    return eligible
end

"""
    sync_fundamentals!(conn, meta_payload, universe_payload; ...)

Persist the observed current Tiingo identity mapping, then synchronize `marketCap`
Daily Metrics for active, unambiguous stocks present in the local universe.
Securities without a watermark request a three-year backfill; subsequent runs
start on the day after the stable `permaTicker` watermark. Daily Metrics are
always requested by `permaTicker`, never by the mutable ticker symbol.
"""
function sync_fundamentals!(
    conn::DuckDBConnection,
    meta_payload,
    universe_payload;
    api_key::String = get_api_key(),
    as_of::Date = Date(Dates.now()),
    history_years::Int = 3,
    observed_at::DateTime = Dates.now(),
    fetched_at::DateTime = Dates.now(),
    daily_fetcher::Function = get_daily_fundamental,
    continue_on_error::Bool = true,
)
    history_years > 0 || throw(ArgumentError("history_years must be positive"))

    observations = normalize_security_observations(
        meta_payload,
        universe_payload;
        observed_at,
    )
    eligible_securities = _eligible_backfill_rows(observations)
    observation_rows = upsert_security_observations(conn, observations)
    watermarks = get_fundamental_watermarks(conn)

    requested = String[]
    skipped = String[]
    unchanged = String[]
    unavailable = String[]
    failed = String[]
    metric_rows = 0
    for security in eachrow(eligible_securities)
        perma_ticker = String(security.perma_ticker)
        has_watermark = haskey(watermarks, perma_ticker)
        start_date = has_watermark ?
            watermarks[perma_ticker] + Day(1) :
            as_of - Year(history_years)
        if start_date > as_of
            push!(skipped, perma_ticker)
            continue
        end

        try
            payload = daily_fetcher(
                perma_ticker;
                api_key,
                start_date,
                end_date = as_of,
                columns = ["marketCap"],
                return_type = "original",
            )
            metrics = normalize_fundamental_daily_metrics(
                payload,
                perma_ticker;
                fetched_at,
            )
            if nrow(metrics) == 0
                push!(has_watermark ? unchanged : unavailable, perma_ticker)
                continue
            end
            in_requested_range = (
                (metrics.metric_date .>= start_date) .&
                (metrics.metric_date .<= as_of)
            )
            metrics = metrics[in_requested_range, :]
            if nrow(metrics) == 0
                push!(has_watermark ? unchanged : unavailable, perma_ticker)
                continue
            end
            metric_rows += upsert_fundamental_daily_metrics(conn, metrics)
            push!(requested, perma_ticker)
        catch
            continue_on_error || rethrow()
            push!(failed, perma_ticker)
        end
    end

    status_counts = Dict{String,Int}()
    for status in observations.join_status
        status_counts[status] = get(status_counts, status, 0) + 1
    end
    return (;
        observation_rows,
        metric_rows,
        requested,
        skipped,
        unchanged,
        unavailable,
        failed,
        status_counts,
    )
end
