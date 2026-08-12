using Test
using CSV
using DataFrames
using Dates
using Logging
using QuansiftMarketData

struct _UnstringifiableTicker
    secret::String
end

struct _InterruptingHistoricalString
    cancellation::InterruptException
end

Base.String(value::_InterruptingHistoricalString) = throw(value.cancellation)

struct _InterruptingHistoricalEquality
    cancellation::InterruptException
end

Base.:(==)(value::_InterruptingHistoricalEquality, ::String) =
    throw(value.cancellation)

const _legacy_historical_mode = Ref(:delegate)
const _legacy_historical_cancellation = Ref{Union{Nothing,InterruptException}}(nothing)

function _eod_fixture(date, close=100.0)
    return DataFrame(
        date = [date],
        close = [close],
        high = [101.0],
        low = [99.0],
        open = [100.0],
        volume = [1_000],
        adjClose = [close],
        adjHigh = [101.0],
        adjLow = [99.0],
        adjOpen = [100.0],
        adjVolume = [1_000],
        divCash = [0.0],
        splitFactor = [1.0],
    )
end

@testset "Ticker universe collection is canonical and sink neutral" begin
    source = DataFrame(
        ticker = ["SPY", "AAPL", "OLD", "BRK/B", "FOREIGN"],
        exchange = ["NYSE ARCA", "NYSE", "NASDAQ", "NYSE", "LSE"],
        assetType = ["ETF", "Stock", "Stock", "Stock", "Stock"],
        priceCurrency = fill("USD", 5),
        startDate = fill("2020-01-01", 5),
        endDate = [
            "2024-01-03",
            "2024-01-03",
            "2024-01-02",
            "2024-01-03",
            "2024-01-03",
        ],
    )

    result = collect_ticker_universe(source)

    @test keys(result) == (:all, :filtered)
    @test names(result.all) == [
        "ticker",
        "exchange",
        "asset_type",
        "price_currency",
        "start_date",
        "end_date",
    ]
    @test result.all.ticker == ["AAPL", "BRK/B", "FOREIGN", "OLD", "SPY"]
    @test eltype(result.all.start_date) == Union{Missing,Date}
    @test result.filtered.ticker == ["AAPL", "SPY"]
    @test result.filtered.asset_type == ["Stock", "ETF"]

    mktempdir() do directory
        fixture = joinpath(directory, "supported_tickers.csv")
        CSV.write(fixture, source)
        from_file = collect_ticker_universe(
            csv_file = fixture,
            zip_file_path = joinpath(directory, "unused.zip"),
            downloader = nothing,
        )
        @test from_file.all == result.all
        @test from_file.filtered == result.filtered
        @test isfile(fixture)
    end
end

@testset "Historical collection is sink neutral for stocks and ETFs" begin
    tickers = DataFrame(
        ticker = ["AAPL", "SPY", "CURRENT", "EMPTY"],
        asset_type = ["Stock", "ETF", "Stock", "ETF"],
        start_date = fill(Date(2024, 1, 1), 4),
        end_date = fill(Date(2024, 1, 3), 4),
    )
    fetch_calls = NamedTuple[]
    written = Dict{String,DataFrame}()
    fetcher = function (row; kwargs...)
        push!(fetch_calls, (
            ticker = String(row.ticker),
            start_date = get(kwargs, :start_date, nothing),
            end_date = get(kwargs, :end_date, nothing),
        ))
        row.ticker == "EMPTY" && return DataFrame()
        return _eod_fixture(
            "2024-01-03T00:00:00.000Z",
            row.ticker == "AAPL" ? 10.0 : 20.0,
        )
    end
    writer = function (ticker, frame)
        written[ticker] = copy(frame)
        return nrow(frame)
    end

    result = collect_historical(
        tickers,
        "offline-token";
        latest_dates = Dict(
            "AAPL" => Date(2024, 1, 2),
            "CURRENT" => Date(2024, 1, 3),
        ),
        fetcher,
        writer,
    )

    @test result isa HistoricalCollectionResult
    @test result.attempted == ["AAPL", "SPY", "CURRENT", "EMPTY"]
    @test result.updated == ["AAPL", "SPY"]
    @test result.unchanged == ["CURRENT"]
    @test result.unavailable == ["EMPTY"]
    @test isempty(result.failed)
    @test isempty(result.failures)
    @test result.written_rows == 2
    @test sort!(collect(keys(written))) == ["AAPL", "SPY"]
    @test eltype(written["AAPL"].date) == Date
    @test names(written["AAPL"]) == names(_eod_fixture("2024-01-03"))
    @test fetch_calls == [
        (
            ticker = "AAPL",
            start_date = Date(2024, 1, 3),
            end_date = Date(2024, 1, 3),
        ),
        (
            ticker = "SPY",
            start_date = Date(2024, 1, 1),
            end_date = Date(2024, 1, 3),
        ),
        (
            ticker = "EMPTY",
            start_date = Date(2024, 1, 1),
            end_date = Date(2024, 1, 3),
        ),
    ]
end

@testset "Historical collection isolates row normalization failures" begin
    secret = "row-label-secret"
    tickers = DataFrame(
        ticker = Any[
            missing,
            _UnstringifiableTicker(secret),
            "MISSING-END",
            "INVALID-END",
            "MISSING-START",
            "INVALID-START",
            "AFTER",
        ],
        start_date = Any[
            Date(2024, 1, 1),
            Date(2024, 1, 1),
            Date(2024, 1, 1),
            Date(2024, 1, 1),
            missing,
            "not-a-date",
            Date(2024, 1, 1),
        ],
        end_date = Any[
            Date(2024, 1, 2),
            Date(2024, 1, 2),
            missing,
            "not-a-date",
            Date(2024, 1, 2),
            Date(2024, 1, 2),
            Date(2024, 1, 2),
        ],
    )
    fetched = String[]
    fetcher = function (row; kwargs...)
        push!(fetched, String(row.ticker))
        return _eod_fixture("2024-01-02T00:00:00Z", 30.0)
    end

    result = collect_historical(
        tickers,
        "offline-token";
        fetcher,
        writer = (_, frame) -> nrow(frame),
    )

    @test result.attempted == [
        "row[1]",
        "row[2]",
        "MISSING-END",
        "INVALID-END",
        "MISSING-START",
        "INVALID-START",
        "AFTER",
    ]
    @test result.failed == result.attempted[1:6]
    @test result.updated == ["AFTER"]
    @test fetched == ["AFTER"]
    @test result.written_rows == 1
    @test length(result.failures) == 6
    @test all(failure -> failure.stage == :normalize, result.failures)
    @test all(failure -> !failure.retryable, result.failures)
    @test all(failure -> !occursin(secret, failure.message), result.failures)

    empty!(fetched)
    caught = try
        collect_historical(
            tickers,
            "offline-token";
            fetcher,
            writer = (_, frame) -> nrow(frame),
            continue_on_error = false,
            strict = true,
        )
        nothing
    catch error
        error
    end
    @test caught isa SyncIncompleteError
    @test caught.result.attempted == result.attempted
    @test caught.result.failed == result.failed
    @test caught.result.updated == ["AFTER"]
    @test fetched == ["AFTER"]

    empty!(fetched)
    @test_throws ArgumentError collect_historical(
        tickers,
        "offline-token";
        fetcher,
        continue_on_error = false,
        strict = false,
    )
    @test isempty(fetched)
end

@testset "Historical collection preserves absent date-column defaults" begin
    tickers = DataFrame(ticker = ["LEGACY"])
    fetch_kwargs = NamedTuple[]
    fetcher = function (row; kwargs...)
        push!(fetch_kwargs, (; kwargs...))
        return DataFrame()
    end

    result = collect_historical(
        tickers,
        "offline-token";
        fetcher,
        writer = (_, frame) -> nrow(frame),
    )

    @test result.unavailable == ["LEGACY"]
    @test isempty(result.failed)
    @test fetch_kwargs == [(api_key = "offline-token",)]
end

@testset "Historical latest-date frames skip missing lookup rows" begin
    latest_dates = DataFrame(
        ticker=Any["MISSING-DATE", "NOTHING-DATE", missing, nothing, "VALID"],
        latest_date=Any[
            missing,
            nothing,
            Date(2024, 1, 1),
            Date(2024, 1, 1),
            Date(2024, 1, 2),
        ],
    )
    lookup = QuansiftMarketData.Sync.build_latest_date_lookup(latest_dates)
    @test lookup == Dict("VALID" => Date(2024, 1, 2))

    tickers = DataFrame(
        ticker=["MISSING-DATE", "NOTHING-DATE", "VALID"],
        start_date=fill(Date(2024, 1, 1), 3),
        end_date=fill(Date(2024, 1, 3), 3),
    )
    fetch_calls = NamedTuple[]
    fetcher = function (row; kwargs...)
        push!(fetch_calls, (
            ticker=String(row.ticker),
            start_date=kwargs[:start_date],
        ))
        return _eod_fixture("2024-01-03T00:00:00Z", 30.0)
    end

    result = collect_historical(
        tickers,
        "offline-token";
        latest_dates,
        fetcher,
    )

    @test result.updated == ["MISSING-DATE", "NOTHING-DATE", "VALID"]
    @test isempty(result.failed)
    @test fetch_calls == [
        (ticker="MISSING-DATE", start_date=Date(2024, 1, 1)),
        (ticker="NOTHING-DATE", start_date=Date(2024, 1, 1)),
        (ticker="VALID", start_date=Date(2024, 1, 3)),
    ]
end

@testset "EOD normalization enforces schema, dates, uniqueness, and range" begin
    later = _eod_fixture("2024-01-03T00:00:00Z", missing)
    earlier = _eod_fixture("2024-01-02T00:00:00Z", 99.0)
    normalized = normalize_eod_prices(
        vcat(later, earlier);
        start_date = Date(2024, 1, 2),
        end_date = Date(2024, 1, 3),
    )

    @test normalized.date == [Date(2024, 1, 2), Date(2024, 1, 3)]
    @test ismissing(normalized[2, :close])
    @test eltype(normalized.close) == Union{Missing,Float64}
    @test eltype(normalized.volume) == Union{Missing,Int64}
    @test names(normalized) == [
        "date",
        "close",
        "high",
        "low",
        "open",
        "volume",
        "adjClose",
        "adjHigh",
        "adjLow",
        "adjOpen",
        "adjVolume",
        "divCash",
        "splitFactor",
    ]

    incomplete = select(earlier, Not(:high))
    @test_throws ArgumentError normalize_eod_prices(incomplete)
    @test_throws ArgumentError normalize_eod_prices(vcat(earlier, earlier))
    @test_throws ArgumentError normalize_eod_prices(
        later;
        end_date = Date(2024, 1, 2),
    )
    invalid = copy(earlier)
    invalid[!, :volume] = [1.5]
    @test_throws ArgumentError normalize_eod_prices(invalid)
end

@testset "Historical strict mode processes all entities and redacts failures" begin
    tickers = DataFrame(
        ticker = ["FAIL", "AFTER"],
        start_date = fill(Date(2024, 1, 1), 2),
        end_date = fill(Date(2024, 1, 2), 2),
    )
    fetched = String[]
    fetcher = function (row; kwargs...)
        ticker = String(row.ticker)
        push!(fetched, ticker)
        ticker == "FAIL" && error("HTTP 503 token=historical-secret")
        return _eod_fixture("2024-01-02T00:00:00Z", 30.0)
    end

    caught = try
        collect_historical(
            tickers,
            "offline-token";
            fetcher,
            writer = (_, frame) -> nrow(frame),
            strict = true,
        )
        nothing
    catch error
        error
    end

    @test caught isa SyncIncompleteError
    result = caught.result
    @test fetched == ["FAIL", "AFTER"]
    @test result.updated == ["AFTER"]
    @test result.failed == ["FAIL"]
    @test result.written_rows == 1
    @test only(result.failures).stage == :fetch
    @test only(result.failures).retryable
    @test !occursin("historical-secret", only(result.failures).message)
    @test occursin("[REDACTED]", only(result.failures).message)
end

@testset "Historical fetch failures warn with sanitized result data before continuing" begin
    secret = "fetch-warning-secret"
    tickers = DataFrame(
        ticker=["FAIL", "AFTER"],
        start_date=fill(Date(2024, 1, 1), 2),
        end_date=fill(Date(2024, 1, 2), 2),
    )
    fetcher = function (row; kwargs...)
        row.ticker == "FAIL" && error("HTTP 503 token=$secret")
        return _eod_fixture("2024-01-02T00:00:00Z", 30.0)
    end

    for (continue_on_error, strict) in ((true, false), (false, true))
        log_buffer = IOBuffer()
        caught = with_logger(SimpleLogger(log_buffer, Logging.Warn)) do
            try
                collect_historical(
                    tickers,
                    "offline-token";
                    fetcher,
                    writer=(_, frame) -> nrow(frame),
                    continue_on_error,
                    strict,
                )
            catch error
                error
            end
        end
        result = caught isa SyncIncompleteError ? caught.result : caught
        failure = only(result.failures)
        warning = String(take!(log_buffer))

        @test result.updated == ["AFTER"]
        @test result.failed == ["FAIL"]
        @test failure.stage == :fetch
        @test occursin("FAIL", warning)
        @test occursin(failure.message, warning)
        @test occursin("[REDACTED]", warning)
        @test !occursin(secret, warning)
        @test !occursin("Stacktrace", warning)
        @test strict ? caught isa SyncIncompleteError : caught === result
    end

    immediate_buffer = IOBuffer()
    immediate = with_logger(SimpleLogger(immediate_buffer, Logging.Warn)) do
        try
            collect_historical(
                tickers,
                "offline-token";
                fetcher,
                continue_on_error=false,
                strict=false,
            )
            nothing
        catch error
            error
        end
    end
    @test immediate isa ErrorException
    @test isempty(String(take!(immediate_buffer)))

    unavailable_buffer = IOBuffer()
    unavailable = with_logger(SimpleLogger(unavailable_buffer, Logging.Warn)) do
        collect_historical(
            tickers[1:1, :],
            "offline-token";
            fetcher=(row; kwargs...) -> error("HTTP 404 ticker not found"),
        )
    end
    @test unavailable.unavailable == ["FAIL"]
    @test isempty(String(take!(unavailable_buffer)))
end

@testset "Historical fetch cancellation is rethrown immediately" begin
    tickers = DataFrame(
        ticker = ["CANCEL", "AFTER"],
        start_date = fill(Date(2024, 1, 1), 2),
        end_date = fill(Date(2024, 1, 2), 2),
    )

    for continue_on_error in (false, true), strict in (false, true)
        fetched = String[]
        cancellation = InterruptException()
        fetcher = function (row; kwargs...)
            ticker = String(row.ticker)
            push!(fetched, ticker)
            ticker == "CANCEL" && throw(cancellation)
            return _eod_fixture("2024-01-02T00:00:00Z", 30.0)
        end

        caught = try
            collect_historical(
                tickers,
                "offline-token";
                fetcher,
                writer=(_, frame) -> nrow(frame),
                continue_on_error,
                strict,
            )
            nothing
        catch error
            error
        end

        @test caught === cancellation
        @test fetched == ["CANCEL"]
    end
end

@testset "Historical writer cancellation is rethrown immediately" begin
    tickers = DataFrame(
        ticker=["CANCEL", "AFTER"],
        start_date=fill(Date(2024, 1, 1), 2),
        end_date=fill(Date(2024, 1, 2), 2),
    )

    for continue_on_error in (false, true), strict in (false, true)
        fetched = String[]
        written = String[]
        cancellation = InterruptException()
        fetcher = function (row; kwargs...)
            push!(fetched, String(row.ticker))
            return _eod_fixture("2024-01-02T00:00:00Z", 30.0)
        end
        writer = function (ticker, frame)
            push!(written, ticker)
            ticker == "CANCEL" && throw(cancellation)
            return nrow(frame)
        end

        caught = try
            collect_historical(
                tickers,
                "offline-token";
                fetcher,
                writer,
                continue_on_error,
                strict,
            )
            nothing
        catch error
            error
        end

        @test caught === cancellation
        @test fetched == ["CANCEL"]
        @test written == ["CANCEL"]
    end
end

@testset "Historical normalization cancellation preserves identity" begin
    for stage in (:ticker, :end_date, :start_date, :eod_date)
        cancellation = InterruptException()
        value = _InterruptingHistoricalString(cancellation)
        tickers = DataFrame(
            ticker=Any[stage == :ticker ? value : "CANCEL"],
            start_date=Any[stage == :start_date ? value : Date(2024, 1, 1)],
            end_date=Any[stage == :end_date ? value : Date(2024, 1, 2)],
        )
        fetcher = stage == :eod_date ?
            ((row; kwargs...) -> _eod_fixture(value, 30.0)) :
            ((row; kwargs...) -> DataFrame())

        caught = try
            collect_historical(tickers, "offline-token"; fetcher)
            nothing
        catch error
            error
        end

        @test caught === cancellation
    end
end

@testset "Legacy historical exports rethrow cancellation" begin
    row_type = typeof(DataFrame(ticker=["TYPE"])[1, :])
    @eval QuansiftMarketData.API function get_ticker_data(row::$row_type; kwargs...)
        if row.ticker == "__LEGACY_CANCEL__"
            cancellation = Main._legacy_historical_cancellation[]
            Main._legacy_historical_mode[] == :fetch && throw(cancellation)
            if Main._legacy_historical_mode[] == :write
                frame = Main._eod_fixture(Date(2024, 1, 2), 30.0)
                frame.ticker = [Main._InterruptingHistoricalEquality(cancellation)]
                return frame
            end
        end
        return invoke(get_ticker_data, Tuple{DataFrameRow}, row; kwargs...)
    end
    injected_method = which(QuansiftMarketData.API.get_ticker_data, (row_type,))
    conn = connect_duckdb(":memory:")

    try
        create_tables(conn)
        tickers = DataFrame(
            ticker=["__LEGACY_CANCEL__"],
            start_date=[Date(2024, 1, 1)],
            end_date=[Date(2024, 1, 2)],
        )

        _legacy_historical_mode[] = :fetch
        for operation in (
            () -> update_historical(
                conn,
                tickers,
                "offline-token";
                latest_dates_df=DataFrame(
                    ticker=["__LEGACY_CANCEL__"],
                    latest_date=[Date(2024, 1, 1)],
                ),
            ),
            () -> update_historical_sequential(conn, tickers, "offline-token"),
            () -> update_historical_parallel(
                conn,
                tickers,
                "offline-token";
                batch_size=1,
                max_concurrent=1,
            ),
        )
            cancellation = InterruptException()
            _legacy_historical_cancellation[] = cancellation
            caught = try
                operation()
                nothing
            catch error
                error
            end
            @test caught === cancellation
        end

        cancellation = InterruptException()
        _legacy_historical_cancellation[] = cancellation
        _legacy_historical_mode[] = :write
        caught = try
            update_historical_parallel(
                conn,
                tickers,
                "offline-token";
                batch_size=1,
                max_concurrent=1,
            )
            nothing
        catch error
            error
        end
        @test caught === cancellation
    finally
        _legacy_historical_mode[] = :delegate
        _legacy_historical_cancellation[] = nothing
        close_duckdb(conn)
        Base.delete_method(injected_method)
    end
end

@testset "Ticker and split normalization preserve cancellation" begin
    cancellation = InterruptException()
    caught = try
        collect_ticker_universe(DataFrame(
            ticker=["CANCEL"],
            exchange=["NYSE"],
            assetType=["Stock"],
            priceCurrency=["USD"],
            startDate=Any[_InterruptingHistoricalString(cancellation)],
            endDate=["2024-01-02"],
        ))
        nothing
    catch error
        error
    end
    @test caught === cancellation

    cancellation = InterruptException()
    caught = try
        find_split_refresh_targets(DataFrame(
            ticker=Any[_InterruptingHistoricalString(cancellation)],
            date=[Date(2024, 1, 2)],
            splitFactor=[2.0],
        ))
        nothing
    catch error
        error
    end
    @test caught === cancellation
end

@testset "Fundamentals collection separates normalization and writers" begin
    as_of = Date(2024, 1, 3)
    observed_at = DateTime(2024, 1, 3, 12)
    meta_payload = [
        (permaTicker = "perm-current", ticker = "CUR", isActive = true, isADR = false, dailyLastUpdated = string(observed_at)),
        (permaTicker = "perm-empty", ticker = "EMP", isActive = true, isADR = false, dailyLastUpdated = string(observed_at)),
        (permaTicker = "perm-new", ticker = "NEW", isActive = true, isADR = false, dailyLastUpdated = string(observed_at)),
        (permaTicker = "perm-etf", ticker = "ETF", isActive = true, isADR = false, dailyLastUpdated = string(observed_at)),
    ]
    universe_payload = [
        (ticker = "CUR", exchange = "NYSE", assetType = "Stock", startDate = "2020-01-01", endDate = string(as_of)),
        (ticker = "EMP", exchange = "NASDAQ", assetType = "Stock", startDate = "2020-01-01", endDate = string(as_of)),
        (ticker = "NEW", exchange = "NYSE", assetType = "Stock", startDate = "2020-01-01", endDate = string(as_of)),
        (ticker = "ETF", exchange = "NYSE ARCA", assetType = "ETF", startDate = "2020-01-01", endDate = string(as_of)),
    ]
    fetch_calls = NamedTuple[]
    metric_frames = Dict{String,DataFrame}()
    daily_fetcher = function (perma_ticker; kwargs...)
        push!(fetch_calls, (
            perma_ticker,
            start_date = kwargs[:start_date],
            columns = kwargs[:columns],
        ))
        perma_ticker == "perm-empty" && return NamedTuple[]
        return [(
            date = string(as_of),
            marketCap = 100.0,
            enterpriseVal = 120.0,
            peRatio = 15.0,
        )]
    end
    metric_writer = function (perma_ticker, frame)
        metric_frames[perma_ticker] = copy(frame)
        return nrow(frame)
    end

    result = collect_fundamentals(
        meta_payload,
        universe_payload;
        watermarks = Dict("perm-current" => as_of),
        api_key = "offline-token",
        as_of,
        observed_at,
        fetched_at = observed_at,
        daily_fetcher,
        observation_writer = nrow,
        metric_writer,
    )

    @test result isa FundamentalCollectionResult
    @test result.attempted == ["perm-current", "perm-empty", "perm-new"]
    @test result.updated == ["perm-new"]
    @test result.unchanged == ["perm-current"]
    @test result.unavailable == ["perm-empty"]
    @test isempty(result.failed)
    @test result.observation_rows == 4
    @test result.metric_rows == 1
    @test fetch_calls == [
        (perma_ticker = "perm-empty", start_date = nothing, columns = nothing),
        (perma_ticker = "perm-new", start_date = nothing, columns = nothing),
    ]
    @test collect(keys(metric_frames)) == ["perm-new"]
    @test only(metric_frames["perm-new"].perma_ticker) == "perm-new"
    @test only(metric_frames["perm-new"].enterprise_value) == 120.0
    @test only(metric_frames["perm-new"].pe_ratio) == 15.0
    @test result.status_counts == Dict("matched" => 4)
end

@testset "Fundamentals collection supports explicit initial range and columns" begin
    as_of = Date(2024, 1, 3)
    initial_start_date = Date(2020, 1, 1)
    meta_payload = [(
        permaTicker = "perm-bounded",
        ticker = "BOUND",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(as_of),
    )]
    universe_payload = [(
        ticker = "BOUND",
        exchange = "NYSE",
        assetType = "Stock",
        startDate = "2010-01-01",
        endDate = string(as_of),
    )]
    calls = NamedTuple[]
    daily_fetcher = function (perma_ticker; kwargs...)
        push!(calls, (
            perma_ticker,
            start_date = kwargs[:start_date],
            columns = kwargs[:columns],
        ))
        return [(date = string(as_of), marketCap = 10.0, peRatio = 11.0)]
    end

    result = collect_fundamentals(
        meta_payload,
        universe_payload;
        api_key = "offline-token",
        as_of,
        initial_start_date,
        columns = ["marketCap", "peRatio"],
        daily_fetcher,
    )

    @test result.updated == ["perm-bounded"]
    @test calls == [(
        perma_ticker = "perm-bounded",
        start_date = initial_start_date,
        columns = ["marketCap", "peRatio"],
    )]
    @test_throws ArgumentError collect_fundamentals(
        meta_payload,
        universe_payload;
        as_of,
        initial_start_date = as_of + Day(1),
        api_key = "offline-token",
        daily_fetcher,
    )
end

@testset "Fundamentals strict mode retains later successes" begin
    as_of = Date(2024, 1, 3)
    meta_payload = [
        (permaTicker = "perm-fail", ticker = "FAIL", isActive = true, isADR = false, dailyLastUpdated = string(as_of)),
        (permaTicker = "perm-pass", ticker = "PASS", isActive = true, isADR = false, dailyLastUpdated = string(as_of)),
    ]
    universe_payload = [
        (ticker = "FAIL", exchange = "NYSE", assetType = "Stock", startDate = "2020-01-01", endDate = string(as_of)),
        (ticker = "PASS", exchange = "NYSE", assetType = "Stock", startDate = "2020-01-01", endDate = string(as_of)),
    ]
    fetched = String[]
    daily_fetcher = function (perma_ticker; kwargs...)
        push!(fetched, perma_ticker)
        perma_ticker == "perm-fail" &&
            error("temporary api_key=fundamental-secret")
        return [(date = string(as_of), marketCap = 200.0)]
    end

    caught = try
        collect_fundamentals(
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            daily_fetcher,
            metric_writer = (_, frame) -> nrow(frame),
            strict = true,
        )
        nothing
    catch error
        error
    end

    @test caught isa SyncIncompleteError
    result = caught.result
    @test fetched == ["perm-fail", "perm-pass"]
    @test result.updated == ["perm-pass"]
    @test result.failed == ["perm-fail"]
    @test result.metric_rows == 1
    @test only(result.failures).stage == :fetch
    @test only(result.failures).retryable
    @test !occursin("fundamental-secret", only(result.failures).message)
end

@testset "Fundamentals cancellation is rethrown immediately" begin
    as_of = Date(2024, 1, 3)
    meta_payload = [
        (permaTicker="perm-a-cancel", ticker="CANCEL", isActive=true, isADR=false, dailyLastUpdated=string(as_of)),
        (permaTicker="perm-z-after", ticker="AFTER", isActive=true, isADR=false, dailyLastUpdated=string(as_of)),
    ]
    universe_payload = [
        (ticker="CANCEL", exchange="NYSE", assetType="Stock", startDate="2020-01-01", endDate=string(as_of)),
        (ticker="AFTER", exchange="NYSE", assetType="Stock", startDate="2020-01-01", endDate=string(as_of)),
    ]
    metric_payload = [(date=string(as_of), marketCap=200.0)]

    for continue_on_error in (false, true), strict in (false, true)
        cancellation = InterruptException()
        fetched = String[]
        daily_fetcher = function (perma_ticker; kwargs...)
            push!(fetched, perma_ticker)
            perma_ticker == "perm-a-cancel" && throw(cancellation)
            return metric_payload
        end
        caught = try
            collect_fundamentals(
                meta_payload,
                universe_payload;
                api_key="offline-token",
                as_of,
                daily_fetcher,
                continue_on_error,
                strict,
            )
            nothing
        catch error
            error
        end
        @test caught === cancellation
        @test fetched == ["perm-a-cancel"]
    end

    # Defaults exercise continue_on_error=true and strict=false.
    cancellation = InterruptException()
    fetched = String[]
    caught = try
        collect_fundamentals(
            meta_payload,
            universe_payload;
            api_key="offline-token",
            as_of,
            daily_fetcher=(perma_ticker; kwargs...) -> begin
                push!(fetched, perma_ticker)
                metric_payload
            end,
            observation_writer=_ -> throw(cancellation),
        )
        nothing
    catch error
        error
    end
    @test caught === cancellation
    @test isempty(fetched)

    cancellation = InterruptException()
    fetched = String[]
    written = String[]
    caught = try
        collect_fundamentals(
            meta_payload,
            universe_payload;
            api_key="offline-token",
            as_of,
            daily_fetcher=(perma_ticker; kwargs...) -> begin
                push!(fetched, perma_ticker)
                metric_payload
            end,
            metric_writer=(perma_ticker, frame) -> begin
                push!(written, perma_ticker)
                perma_ticker == "perm-a-cancel" && throw(cancellation)
                nrow(frame)
            end,
        )
        nothing
    catch error
        error
    end
    @test caught === cancellation
    @test fetched == ["perm-a-cancel"]
    @test written == ["perm-a-cancel"]
end
