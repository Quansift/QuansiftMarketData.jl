#!/usr/bin/env julia

using DataFrames
using Dates
using QuansiftMarketData

const LIVE_CANARY_ALLOWED_TICKERS = ("AAPL", "SPY")
const LIVE_CANARY_DEFAULT_WINDOW_DAYS = 14
const LIVE_CANARY_MAX_WINDOW_DAYS = 30

struct CanaryObservation
    ticker::String
    row_count::Int
    first_date::Date
    last_date::Date
end

struct LiveCanaryReport
    success::Bool
    collection::HistoricalCollectionResult
    observations::Vector{CanaryObservation}
    start_date::Date
    end_date::Date
    elapsed_seconds::Float64
end

function _validate_live_canary_inputs(
    api_key::AbstractString,
    tickers,
    window_days::Integer,
    end_date::Date,
    utc_today::Date,
)
    isempty(strip(api_key)) && throw(ArgumentError("TIINGO_API_KEY is required"))
    1 <= window_days <= LIVE_CANARY_MAX_WINDOW_DAYS || throw(ArgumentError(
        "window_days must be between 1 and $LIVE_CANARY_MAX_WINDOW_DAYS",
    ))
    end_date < utc_today || throw(ArgumentError("end_date must be before today in UTC"))

    symbols = String[String(ticker) for ticker in tickers]
    isempty(symbols) && throw(ArgumentError("at least one canary ticker is required"))
    length(symbols) <= length(LIVE_CANARY_ALLOWED_TICKERS) || throw(ArgumentError(
        "too many canary tickers",
    ))
    length(unique(symbols)) == length(symbols) || throw(ArgumentError(
        "canary tickers must be unique",
    ))
    allowed = Set(LIVE_CANARY_ALLOWED_TICKERS)
    all(symbol -> symbol in allowed, symbols) || throw(ArgumentError(
        "canary ticker is not allowlisted",
    ))
    return symbols
end

function _live_canary_succeeded(
    symbols::Vector{String},
    collection::HistoricalCollectionResult,
    observations::Vector{CanaryObservation},
)::Bool
    observed = [observation.ticker for observation in observations]
    return collection.attempted == symbols &&
           collection.updated == symbols &&
           isempty(collection.unchanged) &&
           isempty(collection.unavailable) &&
           isempty(collection.failed) &&
           isempty(collection.failures) &&
           collection.written_rows == 0 &&
           observed == symbols &&
           length(unique(observed)) == length(symbols)
end

"""
    run_live_canary(; ...)

Collect a small allowlisted Tiingo sample through the sink-neutral collection
API. The mandatory in-memory observer records normalized frame facts and always
reports zero written rows; this function never selects an application sink.
"""
function run_live_canary(;
    api_key::AbstractString = get(ENV, "TIINGO_API_KEY", ""),
    tickers = collect(LIVE_CANARY_ALLOWED_TICKERS),
    window_days::Integer = LIVE_CANARY_DEFAULT_WINDOW_DAYS,
    end_date::Date = Date(now(UTC)) - Day(1),
    utc_today::Date = Date(now(UTC)),
    fetcher = QuansiftMarketData.get_ticker_data,
)::LiveCanaryReport
    symbols = _validate_live_canary_inputs(
        api_key,
        tickers,
        window_days,
        end_date,
        utc_today,
    )
    start_date = end_date - Day(window_days - 1)
    ticker_frame = DataFrame(
        ticker = symbols,
        start_date = fill(start_date, length(symbols)),
        end_date = fill(end_date, length(symbols)),
    )
    observations = CanaryObservation[]
    observed_symbols = Set{String}()
    observer_writer = function (ticker, frame)
        ticker in observed_symbols && throw(ArgumentError(
            "observer called more than once for a ticker",
        ))
        nrow(frame) > 0 || throw(ArgumentError("observer received an empty frame"))
        :date in propertynames(frame) || throw(ArgumentError(
            "observer frame is missing date",
        ))
        first_date = minimum(frame.date)
        last_date = maximum(frame.date)
        first_date isa Date && last_date isa Date || throw(ArgumentError(
            "observer frame dates must be normalized Dates",
        ))
        start_date <= first_date <= last_date <= end_date || throw(ArgumentError(
            "observer frame dates exceed canary bounds",
        ))
        push!(observed_symbols, ticker)
        push!(observations, CanaryObservation(ticker, nrow(frame), first_date, last_date))
        return 0
    end

    started = time_ns()
    collection = collect_historical(
        ticker_frame,
        String(api_key);
        latest_dates = Dict{String,Date}(),
        add_missing = true,
        fetcher,
        writer = observer_writer,
        continue_on_error = true,
        strict = false,
    )
    elapsed_seconds = (time_ns() - started) / 1.0e9
    success = _live_canary_succeeded(symbols, collection, observations)
    return LiveCanaryReport(
        success,
        collection,
        observations,
        start_date,
        end_date,
        elapsed_seconds,
    )
end

function _live_canary_tickers(value::AbstractString)::Vector{String}
    return String[strip(ticker) for ticker in split(value, ',') if !isempty(strip(ticker))]
end

function live_canary_main()::Int
    try
        report = run_live_canary(
            api_key = get(ENV, "TIINGO_API_KEY", ""),
            tickers = _live_canary_tickers(get(
                ENV,
                "TIINGO_CANARY_TICKERS",
                join(LIVE_CANARY_ALLOWED_TICKERS, ','),
            )),
            window_days = parse(Int, get(
                ENV,
                "TIINGO_CANARY_WINDOW_DAYS",
                string(LIVE_CANARY_DEFAULT_WINDOW_DAYS),
            )),
        )
        rows = join(
            ("$(observation.ticker):$(observation.row_count)" for observation in report.observations),
            ',',
        )
        status = report.success ? "SUCCESS" : "FAILED"
        println(
            "status=$status tickers=$(join(report.collection.attempted, ',')) " *
            "start=$(report.start_date) end=$(report.end_date) rows=$rows " *
            "elapsed_seconds=$(round(report.elapsed_seconds; digits=3))",
        )
        return report.success ? 0 : 1
    catch error
        error isa InterruptException && rethrow()
        println(stderr, "status=FAILED")
        return 1
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(live_canary_main())
end
