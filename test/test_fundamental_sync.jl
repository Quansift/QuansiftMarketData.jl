using Test
using Dates
using DataFrames
using DuckDB
using DBInterface
using QuansiftMarketData

struct _InterruptDuringFundamentalParse
    cancellation::InterruptException
end

Base.String(value::_InterruptDuringFundamentalParse) = value
Base.length(value::_InterruptDuringFundamentalParse) = throw(value.cancellation)
Base.first(value::_InterruptDuringFundamentalParse, ::Integer) =
    throw(value.cancellation)

struct _TemporaryTimeoutMetric <: Real end
Base.Float64(::_TemporaryTimeoutMetric) = error("temporary timeout while normalizing")

@testset "Official meta reconciles as observations without invented validity" begin
    observed_at = DateTime(2026, 7, 19, 12)
    meta_payload = [
        (
            permaTicker = "perm-aapl",
            ticker = "AAPL",
            isActive = true,
            isADR = false,
            dailyLastUpdated = "2026-07-18T23:00:00Z",
        ),
        (permaTicker = "perm-dead", ticker = "DEAD", isActive = false, isADR = false, dailyLastUpdated = nothing),
        (permaTicker = "perm-missing", ticker = "MISS", isActive = true, isADR = false, dailyLastUpdated = nothing),
    ]
    universe_payload = [
        (
            ticker = "AAPL",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "1980-12-12",
            endDate = "2026-07-19",
        ),
    ]

    normalized = normalize_security_observations(
        meta_payload,
        universe_payload;
        observed_at,
    )
    @test names(normalized) == [
        "perma_ticker",
        "observed_at",
        "ticker",
        "is_active",
        "is_adr",
        "daily_last_updated",
        "exchange",
        "asset_type",
        "price_coverage_start",
        "price_coverage_end",
        "is_leveraged",
        "join_status",
    ]
    aapl = only(eachrow(filter(row -> row.ticker == "AAPL", normalized)))
    @test aapl.observed_at == observed_at
    @test aapl.join_status == "matched"
    @test aapl.exchange == "NASDAQ"
    @test aapl.asset_type == "Stock"
    @test aapl.price_coverage_start == Date(1980, 12, 12)
    @test aapl.price_coverage_end == Date(2026, 7, 19)
    @test ismissing(aapl.is_leveraged)
    @test only(eachrow(filter(row -> row.ticker == "DEAD", normalized))).join_status == "inactive"
    @test only(eachrow(filter(row -> row.ticker == "MISS", normalized))).join_status == "unmatched"
    @test !(:valid_from in propertynames(normalized))
    @test !(:valid_to in propertynames(normalized))
end

@testset "Fundamentals metadata tickers reconcile case-insensitively" begin
    observed_at = DateTime(2026, 7, 22, 12)
    meta_payload = [(
        permaTicker = "perm-googl",
        ticker = "googl",
        isActive = true,
        isADR = false,
        dailyLastUpdated = "2026-07-22T01:52:38Z",
    )]
    universe_payload = [(
        ticker = "GOOGL",
        exchange = "NASDAQ",
        asset_type = "Stock",
        start_date = "2004-08-19",
        end_date = "2026-07-22",
    )]

    normalized = normalize_security_observations(
        meta_payload,
        universe_payload;
        observed_at,
    )

    @test only(normalized.join_status) == "matched"
    @test only(normalized.ticker) == "GOOGL"
    @test only(normalized.asset_type) == "Stock"
    @test only(normalized.price_coverage_start) == Date(2004, 8, 19)
    @test only(normalized.price_coverage_end) == Date(2026, 7, 22)
end

@testset "Duplicate identities are quarantined" begin
    observed_at = DateTime(2026, 7, 19, 12)
    universe = [
        (ticker="DUP", exchange="NYSE", assetType="Stock", startDate="2020-01-01", endDate="2026-07-19"),
    ]
    duplicate_perma = [
        (permaTicker="perm-dup", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-dup", ticker="DUP.NEW", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(duplicate_perma, universe; observed_at)
    @test all(normalized.join_status .== "duplicate_perma_ticker")

    whitespace_duplicate_perma = [
        (permaTicker=" perm-dup ", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-dup", ticker="DUP.NEW", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(
        whitespace_duplicate_perma,
        universe;
        observed_at,
    )
    @test normalized.perma_ticker == ["perm-dup", "perm-dup"]
    @test all(normalized.join_status .== "duplicate_perma_ticker")

    duplicate_ticker = [
        (permaTicker="perm-1", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-2", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(duplicate_ticker, universe; observed_at)
    @test all(normalized.join_status .== "duplicate_ticker")
end

@testset "A delisted predecessor does not quarantine the live security" begin
    # Tiingo keeps every issuer that ever used a symbol. Treating the delisted
    # ones as rival identities dropped PARA and MSGY from the sync for three
    # weeks — their market caps stopped advancing and nothing reported it,
    # because only `matched` rows are eligible for the backfill.
    observed_at = DateTime(2026, 7, 19, 12)
    universe = [
        (ticker="DUP", exchange="NYSE", assetType="Stock", startDate="2020-01-01", endDate="2026-07-19"),
    ]

    recycled_symbol = [
        (permaTicker="perm-older", ticker="DUP", isActive=false, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-old", ticker="DUP", isActive=false, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-live", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(recycled_symbol, universe; observed_at)
    status = Dict(row.perma_ticker => row.join_status for row in eachrow(normalized))
    @test status["perm-live"] == "matched"
    @test status["perm-old"] == "inactive"
    @test status["perm-older"] == "inactive"

    # Same reasoning for a permaTicker that reappears alongside a delisted row.
    recycled_perma = [
        (permaTicker="perm-dup", ticker="DUP", isActive=false, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-dup", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(recycled_perma, universe; observed_at)
    @test sort(normalized.join_status) == ["inactive", "matched"]

    # Two live securities on one symbol stay quarantined: nothing in the payload
    # says which of them the local price series belongs to.
    both_live = [
        (permaTicker="perm-1", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-2", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-gone", ticker="DUP", isActive=false, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(both_live, universe; observed_at)
    status = Dict(row.perma_ticker => row.join_status for row in eachrow(normalized))
    @test status["perm-1"] == "duplicate_ticker"
    @test status["perm-2"] == "duplicate_ticker"
    @test status["perm-gone"] == "inactive"
end

@testset "Daily API payload normalizes nullable metrics and provenance" begin
    fetched_at = DateTime(2026, 7, 19, 12)
    payload = [
        (
            date = "2024-01-31T00:00:00.000Z",
            marketCap = 3.0e12,
            enterpriseVal = nothing,
            peRatio = 25.0,
            availableAt = nothing,
            dailyLastUpdated = "2026-07-19T12:00:00Z",
            sourceRevision = nothing,
        ),
        (
            date = "2024-02-01",
            marketCap = nothing,
            enterpriseVal = 3.1e12,
            peRatio = nothing,
            availableAt = "2024-02-02T14:30:00Z",
            dailyLastUpdated = nothing,
            sourceRevision = "revision-2",
        ),
    ]

    normalized = normalize_fundamental_daily_metrics(
        payload,
        "perm-aapl";
        fetched_at,
    )
    @test names(normalized) == [
        "perma_ticker",
        "metric_date",
        "market_cap",
        "enterprise_value",
        "pe_ratio",
        "available_at",
        "fetched_at",
        "source_revision",
    ]
    @test normalized.perma_ticker == ["perm-aapl", "perm-aapl"]
    @test normalized.metric_date == [Date(2024, 1, 31), Date(2024, 2, 1)]
    @test normalized.market_cap[1] == 3.0e12
    @test ismissing(normalized.market_cap[2])
    @test ismissing(normalized.enterprise_value[1])
    @test normalized.enterprise_value[2] == 3.1e12
    @test normalized.pe_ratio[1] == 25.0
    @test ismissing(normalized.pe_ratio[2])
    @test ismissing(normalized.available_at[1])
    @test normalized.available_at[2] == DateTime(2024, 2, 2, 14, 30)
    @test normalized.fetched_at == fill(fetched_at, 2)
    @test ismissing(normalized.source_revision[1])
    @test normalized.source_revision[2] == "revision-2"
end

@testset "Fundamentals normalization cancellation preserves identity" begin
    for field in (:metric_date, :available_at)
        cancellation = InterruptException()
        value = _InterruptDuringFundamentalParse(cancellation)
        payload = field == :metric_date ?
            [(date=value, marketCap=1.0)] :
            [(date="2024-01-31", marketCap=1.0, availableAt=value)]

        caught = try
            normalize_fundamental_daily_metrics(payload, "perm-cancel")
            nothing
        catch error
            error
        end

        @test caught === cancellation
    end
end

@testset "Fundamentals sync backfills then advances by watermark" begin
    conn = connect_duckdb(":memory:")
    try
        as_of = Date(2026, 7, 19)
        fetched_at = DateTime(2026, 7, 19, 12)
        response_date = Ref(as_of)
        calls = NamedTuple[]
        daily_fetcher = function (
            ticker;
            api_key,
            start_date,
            end_date,
            columns,
            return_type,
        )
            push!(calls, (; ticker, api_key, start_date, end_date, columns, return_type))
            return [
                (date = string(response_date[]), marketCap = 3.0e12),
                (date = string(end_date + Day(1)), marketCap = 4.0e12),
            ]
        end
        meta_payload = [(
            permaTicker = "perm-aapl",
            ticker = "AAPL",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(fetched_at),
        )]
        universe_payload = [(
            ticker = "AAPL",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "1980-12-12",
            endDate = string(as_of),
        )]

        initial = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            history_years = 3,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
        )
        @test initial.observation_rows == 1
        @test initial.metric_rows == 1
        @test initial.requested == ["perm-aapl"]
        @test isempty(initial.skipped)
        @test isempty(initial.failed)
        @test length(calls) == 1
        @test calls[1].ticker == "perm-aapl"
        @test calls[1].start_date == Date(2023, 7, 19)
        @test calls[1].end_date == as_of
        @test calls[1].columns == ["marketCap"]
        @test calls[1].return_type == "original"

        stored_security = DBInterface.execute(conn, "SELECT * FROM security_observations") |> DataFrame
        stored_metrics = DBInterface.execute(
            conn,
            "SELECT * FROM fundamental_daily_metrics",
        ) |> DataFrame
        @test stored_security.perma_ticker == ["perm-aapl"]
        @test stored_metrics.perma_ticker == ["perm-aapl"]
        @test stored_metrics.metric_date == [as_of]
        @test ismissing(stored_metrics.available_at[1])
        @test stored_metrics.fetched_at == [fetched_at]

        repeated = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            history_years = 3,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
        )
        @test repeated.metric_rows == 0
        @test repeated.skipped == ["perm-aapl"]
        @test length(calls) == 1
        @test (
            DBInterface.execute(conn, "SELECT count(*) FROM fundamental_daily_metrics") |>
            DataFrame
        )[1, 1] == 1

        next_as_of = as_of + Day(1)
        response_date[] = next_as_of
        incremental = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of = next_as_of,
            history_years = 3,
            observed_at = fetched_at + Day(1),
            fetched_at = fetched_at + Day(1),
            daily_fetcher,
        )
        @test incremental.metric_rows == 1
        @test length(calls) == 2
        @test calls[2].start_date == next_as_of
        @test calls[2].end_date == next_as_of
        @test (
            DBInterface.execute(conn, "SELECT count(*) FROM fundamental_daily_metrics") |>
            DataFrame
        )[1, 1] == 2
        @test get_fundamental_watermarks(conn) == Dict("perm-aapl" => next_as_of)

        renamed_as_of = next_as_of + Day(1)
        response_date[] = renamed_as_of
        renamed_payload = [
            (
                permaTicker = "perm-aapl",
                ticker = "AAPL.NEW",
                isActive = true,
                isADR = false,
                dailyLastUpdated = string(fetched_at + Day(2)),
            ),
        ]
        renamed_universe = [(
            ticker = "AAPL.NEW",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "1980-12-12",
            endDate = string(renamed_as_of),
        )]
        renamed = sync_fundamentals!(
            conn,
            renamed_payload,
            renamed_universe;
            api_key = "offline-token",
            as_of = renamed_as_of,
            history_years = 3,
            observed_at = fetched_at + Day(2),
            fetched_at = fetched_at + Day(2),
            daily_fetcher,
        )
        @test renamed.metric_rows == 1
        @test calls[end].ticker == "perm-aapl"
        @test calls[end].start_date == renamed_as_of
        @test calls[end].end_date == renamed_as_of
        @test (
            DBInterface.execute(conn, "SELECT count(*) FROM security_observations") |>
            DataFrame
        )[1, 1] == 3
        observations = DBInterface.execute(
            conn,
            "SELECT ticker FROM security_observations ORDER BY observed_at",
        ) |> DataFrame
        @test observations.ticker == ["AAPL", "AAPL", "AAPL.NEW"]
        @test get_fundamental_watermarks(conn) == Dict("perm-aapl" => renamed_as_of)
    finally
        close_duckdb(conn)
    end
end

@testset "Empty daily Fundamentals payload is unavailable, not failed" begin
    conn = connect_duckdb(":memory:")
    try
        as_of = Date(2026, 7, 19)
        observed_at = DateTime(2026, 7, 19, 12)
        meta_payload = [(
            permaTicker = "perm-empty",
            ticker = "EMPTY",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(observed_at),
        )]
        universe_payload = [(
            ticker = "EMPTY",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "2020-01-01",
            endDate = string(as_of),
        )]
        empty_fetcher = function (
            ticker;
            api_key,
            start_date,
            end_date,
            columns,
            return_type,
        )
            return NamedTuple[]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at,
            fetched_at = observed_at,
            daily_fetcher = empty_fetcher,
        )

        @test isempty(result.requested)
        @test result.unavailable == ["perm-empty"]
        @test isempty(result.failed)
        @test result.metric_rows == 0
        @test (
            DBInterface.execute(conn, "SELECT count(*) FROM fundamental_daily_metrics") |>
            DataFrame
        )[1, 1] == 0
    finally
        close_duckdb(conn)
    end
end

@testset "No newer Daily Metrics row is unchanged after a watermark" begin
    conn = connect_duckdb(":memory:")
    try
        as_of = Date(2026, 7, 21)
        observed_at = DateTime(2026, 7, 22, 12)
        meta_payload = [(
            permaTicker = "perm-existing",
            ticker = "EXIST",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(observed_at),
        )]
        universe_payload = [(
            ticker = "EXIST",
            exchange = "NYSE",
            assetType = "Stock",
            startDate = "2020-01-01",
            endDate = "2026-07-22",
        )]
        seeded_fetcher = function (ticker; kwargs...)
            return [(date = string(as_of), marketCap = 10.0)]
        end
        sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at,
            fetched_at = observed_at,
            daily_fetcher = seeded_fetcher,
        )
        empty_fetcher = function (ticker; kwargs...)
            return NamedTuple[]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of = as_of + Day(1),
            observed_at = observed_at + Day(1),
            fetched_at = observed_at + Day(1),
            daily_fetcher = empty_fetcher,
        )

        @test result.unchanged == ["perm-existing"]
        @test isempty(result.unavailable)
        @test isempty(result.failed)
    finally
        close_duckdb(conn)
    end
end

@testset "Daily Fundamentals request errors remain retryable failures" begin
    conn = connect_duckdb(":memory:")
    try
        as_of = Date(2026, 7, 19)
        observed_at = DateTime(2026, 7, 19, 12)
        meta_payload = [(
            permaTicker = "perm-error",
            ticker = "ERROR",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(observed_at),
        )]
        universe_payload = [(
            ticker = "ERROR",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "2020-01-01",
            endDate = string(as_of),
        )]
        error_fetcher = function (ticker; kwargs...)
            error("temporary API failure")
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at,
            fetched_at = observed_at,
            daily_fetcher = error_fetcher,
        )

        @test isempty(result.unavailable)
        @test result.failed == ["perm-error"]
    finally
        close_duckdb(conn)
    end
end

@testset "Normalization wording never enters the fetch retry sweep" begin
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    meta_payload = [(
        permaTicker = "perm-normalize",
        ticker = "NORMALIZE",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    )]
    universe_payload = [(
        ticker = "NORMALIZE",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "2020-01-01",
        endDate = string(as_of),
    )]

    conn = connect_duckdb(":memory:")
    try
        attempts = Ref(0)
        daily_fetcher = function (ticker; kwargs...)
            attempts[] += 1
            return [(date = string(as_of), marketCap = _TemporaryTimeoutMetric())]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
            retry_rounds = 2,
        )

        @test attempts[] == 1
        @test result.failed == ["perm-normalize"]
        @test isempty(result.requested)
        @test isempty(result.unavailable)
    finally
        close_duckdb(conn)
    end
end

@testset "Retryable fetch failures are swept after the main pass" begin
    # The 2026-08-13 run lost 2,368 of 5,404 securities to transient fetch
    # errors. `SyncFailure.retryable` already classified them; nothing acted
    # on it, so every one was dropped until the next night's cron. The sweep
    # runs AFTER the pass, not inline: with 5,400 sequential securities an
    # inline retry stalls the whole run behind one bad security.
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    meta_payload = [
        (
            permaTicker = "perm-flaky",
            ticker = "FLAKY",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(fetched_at),
        ),
        (
            permaTicker = "perm-solid",
            ticker = "SOLID",
            isActive = true,
            isADR = false,
            dailyLastUpdated = string(fetched_at),
        ),
    ]
    universe_payload = [
        (
            ticker = "FLAKY",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "2020-01-01",
            endDate = string(as_of),
        ),
        (
            ticker = "SOLID",
            exchange = "NASDAQ",
            assetType = "Stock",
            startDate = "2020-01-01",
            endDate = string(as_of),
        ),
    ]

    conn = connect_duckdb(":memory:")
    try
        order = String[]
        attempts = Dict{String,Int}()
        daily_fetcher = function (ticker; kwargs...)
            push!(order, ticker)
            attempts[ticker] = get(attempts, ticker, 0) + 1
            ticker == "perm-flaky" && attempts[ticker] == 1 &&
                error("HTTP 503 upstream timeout")
            return [(date = string(as_of), marketCap = 1.0e9)]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
        )

        @test isempty(result.failed)
        @test sort(result.requested) == ["perm-flaky", "perm-solid"]
        @test result.metric_rows == 2
        # The sweep trails the pass; it does not re-fetch inline.
        @test order == ["perm-flaky", "perm-solid", "perm-flaky"]
        @test attempts["perm-solid"] == 1
        stored = DBInterface.execute(
            conn,
            "SELECT count(*) AS n FROM fundamental_daily_metrics",
        ) |> DataFrame
        @test stored[1, :n] == 2
    finally
        close_duckdb(conn)
    end

    # retry_rounds = 0 restores the previous single-pass behaviour exactly.
    conn = connect_duckdb(":memory:")
    try
        attempts = Dict{String,Int}()
        daily_fetcher = function (ticker; kwargs...)
            attempts[ticker] = get(attempts, ticker, 0) + 1
            ticker == "perm-flaky" && attempts[ticker] == 1 &&
                error("HTTP 503 upstream timeout")
            return [(date = string(as_of), marketCap = 1.0e9)]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
            retry_rounds = 0,
        )

        @test result.failed == ["perm-flaky"]
        @test result.requested == ["perm-solid"]
        @test attempts["perm-flaky"] == 1
    finally
        close_duckdb(conn)
    end

    # A negative round count is a caller error, not a silent no-op.
    conn = connect_duckdb(":memory:")
    try
        @test_throws ArgumentError sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher = (ticker; kwargs...) ->
                [(date = string(as_of), marketCap = 1.0e9)],
            retry_rounds = -1,
        )
    finally
        close_duckdb(conn)
    end
end

@testset "Non-retryable fetch failures are not swept" begin
    # Sweeping a permanent failure just burns API quota. `retryable` already
    # distinguishes them; the sweep has to honour it.
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    meta_payload = [(
        permaTicker = "perm-gone",
        ticker = "GONE",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    )]
    universe_payload = [(
        ticker = "GONE",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "2020-01-01",
        endDate = string(as_of),
    )]

    conn = connect_duckdb(":memory:")
    try
        attempts = Ref(0)
        daily_fetcher = function (ticker; kwargs...)
            attempts[] += 1
            error("HTTP 404 for security")
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
        )

        @test result.failed == ["perm-gone"]
        @test attempts[] == 1
    finally
        close_duckdb(conn)
    end
end

@testset "Write failures are never swept" begin
    # A DuckDB checkpoint FATAL invalidates the whole database, so every
    # later write is guaranteed to fail. Re-driving writes through the sweep
    # would reproduce exactly the cascade that turned one checkpoint failure
    # into 3,458 failures on 2026-08-13 — real API quota spent writing to a
    # dead connection. The sweep re-attempts fetch-stage failures only.
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    meta_payload = [(
        permaTicker = "perm-write",
        ticker = "WRITE",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    )]
    universe_payload = [(
        ticker = "WRITE",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "2020-01-01",
        endDate = string(as_of),
    )]

    conn = connect_duckdb(":memory:")
    try
        # Narrow the write target so every metrics upsert fails on its column
        # list, while the watermark query, the observation upsert, and the
        # fetch all still succeed.
        DBInterface.execute(conn, "DROP TABLE fundamental_daily_metrics")
        DBInterface.execute(conn, """
            CREATE TABLE fundamental_daily_metrics (
                perma_ticker VARCHAR,
                metric_date DATE
            )
        """)
        attempts = Ref(0)
        daily_fetcher = function (ticker; kwargs...)
            attempts[] += 1
            return [(date = string(as_of), marketCap = 1.0e9)]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
        )

        @test result.failed == ["perm-write"]
        @test isempty(result.requested)
        @test attempts[] == 1
    finally
        close_duckdb(conn)
    end
end

@testset "Retry recovery ending in a write failure records one failed security" begin
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    meta_payload = [(
        permaTicker = "perm-retry-write",
        ticker = "RETRYWRITE",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    )]
    universe_payload = [(
        ticker = "RETRYWRITE",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "2020-01-01",
        endDate = string(as_of),
    )]

    conn = connect_duckdb(":memory:")
    try
        DBInterface.execute(conn, "DROP TABLE fundamental_daily_metrics")
        DBInterface.execute(conn, """
            CREATE TABLE fundamental_daily_metrics (
                perma_ticker VARCHAR,
                metric_date DATE
            )
        """)
        attempts = Ref(0)
        daily_fetcher = function (ticker; kwargs...)
            attempts[] += 1
            attempts[] == 1 && error("connection reset")
            return [(date = string(as_of), marketCap = 1.0e9)]
        end

        result = sync_fundamentals!(
            conn,
            meta_payload,
            universe_payload;
            api_key = "offline-token",
            as_of,
            observed_at = fetched_at,
            fetched_at,
            daily_fetcher,
            retry_rounds = 1,
        )

        @test attempts[] == 2
        @test result.failed == ["perm-retry-write"]
        @test isempty(result.requested)
    finally
        close_duckdb(conn)
    end
end

@testset "Legacy Fundamentals sync rethrows cancellation" begin
    conn = connect_duckdb(":memory:")
    try
        as_of = Date(2026, 7, 19)
        observed_at = DateTime(2026, 7, 19, 12)
        meta_payload = [(
            permaTicker="perm-cancel",
            ticker="CANCEL",
            isActive=true,
            isADR=false,
            dailyLastUpdated=string(observed_at),
        )]
        universe_payload = [(
            ticker="CANCEL",
            exchange="NASDAQ",
            assetType="Stock",
            startDate="2020-01-01",
            endDate=string(as_of),
        )]
        cancellation = InterruptException()

        caught = try
            sync_fundamentals!(
                conn,
                meta_payload,
                universe_payload;
                api_key="offline-token",
                as_of,
                observed_at,
                fetched_at=observed_at,
                daily_fetcher=(ticker; kwargs...) -> throw(cancellation),
            )
            nothing
        catch error
            error
        end

        @test caught === cancellation
    finally
        close_duckdb(conn)
    end
end

@testset "Fundamentals sync checkpoints periodically to bound DuckDB memory" begin
    # Regression guard for the 2026-08-13 incident: without periodic
    # checkpoints DuckDB accumulates every upsert in the buffer manager and
    # dies part-way through the universe ("Out of Memory Error: failed to
    # allocate data of size 4.0 KiB (1.5 GiB/1.5 GiB used)"). Asserting the
    # checkpoints actually fire is the only way to keep that from silently
    # regressing — the memory behaviour itself is not observable in a test.
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    security_count = 7

    daily_fetcher = function (ticker; api_key, start_date, end_date, columns, return_type)
        return [(date = string(as_of), marketCap = 1.0e9)]
    end
    meta_payload = [(
        permaTicker = "perm-t$(lpad(i, 3, '0'))",
        ticker = "T$(lpad(i, 3, '0'))",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    ) for i in 1:security_count]
    universe_payload = [(
        ticker = "T$(lpad(i, 3, '0'))",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "1980-12-12",
        endDate = string(as_of),
    ) for i in 1:security_count]

    # Count CHECKPOINT statements by wrapping the connection's execute path.
    function run_with_counter(checkpoint_every)
        conn = connect_duckdb(":memory:")
        checkpoints = Ref(0)
        try
            create_tables(conn)
            checkpointer = function (connection)
                checkpoints[] += 1
                return DBInterface.execute(connection, "CHECKPOINT")
            end
            result = sync_fundamentals!(
                conn,
                meta_payload,
                universe_payload;
                api_key = "offline-token",
                as_of,
                history_years = 3,
                observed_at = fetched_at,
                fetched_at,
                daily_fetcher,
                checkpoint_every,
                batch_size = 1,
                checkpointer,
            )
            return (; result, conn, checkpoints = checkpoints[])
        finally
        end
    end

    # checkpoint_every = 2 over 7 securities must not change the outcome:
    # every security is still fetched and stored exactly once.
    got = run_with_counter(2)
    @test length(got.result.requested) == security_count
    @test isempty(got.result.failed)
    @test got.checkpoints == 4
    stored = DBInterface.execute(
        got.conn, "SELECT count(*) AS n FROM fundamental_daily_metrics",
    ) |> DataFrame
    @test stored[1, :n] == security_count
    close_duckdb(got.conn)

    # Disabling checkpoints (0) must also be valid and produce the same data.
    off = run_with_counter(0)
    @test length(off.result.requested) == security_count
    @test off.checkpoints == 0
    stored_off = DBInterface.execute(
        off.conn, "SELECT count(*) AS n FROM fundamental_daily_metrics",
    ) |> DataFrame
    @test stored_off[1, :n] == security_count
    close_duckdb(off.conn)

    # A negative interval is a caller error, not a silent no-op.
    conn = connect_duckdb(":memory:")
    try
        create_tables(conn)
        @test_throws ArgumentError sync_fundamentals!(
            conn, meta_payload, universe_payload;
            api_key = "offline-token", as_of, history_years = 3,
            observed_at = fetched_at, fetched_at, daily_fetcher,
            checkpoint_every = -1,
        )
    finally
        close_duckdb(conn)
    end

    conn = connect_duckdb(":memory:")
    checkpoint_error = ErrorException("injected final checkpoint failure")
    try
        caught = try
            sync_fundamentals!(
                conn,
                meta_payload[[1]],
                universe_payload[[1]];
                api_key = "offline-token",
                as_of,
                observed_at = fetched_at,
                fetched_at,
                daily_fetcher,
                checkpoint_every = 100,
                checkpointer = _ -> throw(checkpoint_error),
            )
            nothing
        catch error
            error
        end
        @test caught === checkpoint_error
    finally
        close_duckdb(conn)
    end
end

@testset "Batched writes keep per-security accounting" begin
    # Writing once per security is what exhausted DuckDB memory in production
    # (~2.9 MB leaked per driver registration), so metrics are buffered and
    # written batch_size at a time. The risk that introduces is attribution:
    # a batch is one statement, so one bad security could fail the other
    # batch_size-1 with it. These assert the counts stay per-security.
    as_of = Date(2026, 7, 19)
    fetched_at = DateTime(2026, 7, 19, 12)
    count = 7

    fetcher = function (ticker; api_key, start_date, end_date, columns, return_type)
        return [(date = string(as_of), marketCap = 1.0e9)]
    end
    meta = [(
        permaTicker = "perm-b$(lpad(i, 3, '0'))",
        ticker = "B$(lpad(i, 3, '0'))",
        isActive = true,
        isADR = false,
        dailyLastUpdated = string(fetched_at),
    ) for i in 1:count]
    universe = [(
        ticker = "B$(lpad(i, 3, '0'))",
        exchange = "NASDAQ",
        assetType = "Stock",
        startDate = "1980-12-12",
        endDate = string(as_of),
    ) for i in 1:count]

    # A batch size that does not divide the universe evenly, so the trailing
    # partial batch has to be flushed after the loop or rows go missing.
    for bs in (1, 3, 100)
        conn = connect_duckdb(":memory:")
        try
            create_tables(conn)
            result = sync_fundamentals!(
                conn, meta, universe;
                api_key = "offline-token", as_of, history_years = 3,
                observed_at = fetched_at, fetched_at, daily_fetcher = fetcher,
                batch_size = bs,
            )
            @test length(result.requested) == count
            @test isempty(result.failed)
            @test result.metric_rows == count
            stored = DBInterface.execute(
                conn, "SELECT count(*) AS n FROM fundamental_daily_metrics",
            ) |> DataFrame
            @test stored[1, :n] == count
        finally
            close_duckdb(conn)
        end
    end

    # batch_size must be positive: 0 would buffer forever and never flush.
    conn = connect_duckdb(":memory:")
    try
        create_tables(conn)
        @test_throws ArgumentError sync_fundamentals!(
            conn, meta, universe;
            api_key = "offline-token", as_of, history_years = 3,
            observed_at = fetched_at, fetched_at, daily_fetcher = fetcher,
            batch_size = 0,
        )
    finally
        close_duckdb(conn)
    end
end
