using Test
using Dates
using DataFrames
using DuckDB
using DBInterface
using TiingoJulia

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

    duplicate_ticker = [
        (permaTicker="perm-1", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
        (permaTicker="perm-2", ticker="DUP", isActive=true, isADR=false, dailyLastUpdated=nothing),
    ]
    normalized = normalize_security_observations(duplicate_ticker, universe; observed_at)
    @test all(normalized.join_status .== "duplicate_ticker")
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
