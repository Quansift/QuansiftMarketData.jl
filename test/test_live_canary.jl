using DataFrames
using Dates
using Test

include(joinpath(@__DIR__, "..", "scripts", "live_canary.jl"))

function _canary_eod_fixture(date::Date, close::Float64=100.0)
    timestamp = string(date, "T00:00:00Z")
    return DataFrame(
        date = [timestamp],
        close = [close],
        high = [close + 1],
        low = [close - 1],
        open = [close],
        volume = [1_000],
        adjClose = [close],
        adjHigh = [close + 1],
        adjLow = [close - 1],
        adjOpen = [close],
        adjVolume = [1_000],
        divCash = [0.0],
        splitFactor = [1.0],
    )
end

@testset "Live canary observes normalized frames without persistence" begin
    requested_end = Date(2026, 7, 31)
    fetch_calls = NamedTuple[]
    fetcher = function (row; start_date, end_date, api_key)
        push!(fetch_calls, (
            ticker = String(row.ticker),
            start_date,
            end_date,
            api_key,
        ))
        return _canary_eod_fixture(end_date, row.ticker == "AAPL" ? 100.0 : 200.0)
    end

    report = run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL", "SPY"],
        window_days = 14,
        end_date = requested_end,
        fetcher = fetcher,
    )

    @test report.success
    @test report.start_date == Date(2026, 7, 18)
    @test report.end_date == requested_end
    @test report.collection.attempted == ["AAPL", "SPY"]
    @test report.collection.updated == ["AAPL", "SPY"]
    @test isempty(report.collection.unavailable)
    @test isempty(report.collection.failed)
    @test report.collection.written_rows == 0
    @test length(report.observations) == 2
    @test [observation.ticker for observation in report.observations] == ["AAPL", "SPY"]
    @test all(observation -> observation.row_count == 1, report.observations)
    @test all(observation -> observation.first_date == requested_end, report.observations)
    @test all(observation -> observation.last_date == requested_end, report.observations)
    @test fetch_calls == [
        (
            ticker = "AAPL",
            start_date = Date(2026, 7, 18),
            end_date = requested_end,
            api_key = "offline-token",
        ),
        (
            ticker = "SPY",
            start_date = Date(2026, 7, 18),
            end_date = requested_end,
            api_key = "offline-token",
        ),
    ]
end

@testset "Live canary rejects incomplete collection" begin
    requested_end = Date(2026, 7, 31)

    empty_report = run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL"],
        end_date = requested_end,
        fetcher = (row; kwargs...) -> DataFrame(),
    )
    @test !empty_report.success
    @test empty_report.collection.unavailable == ["AAPL"]
    @test isempty(empty_report.observations)

    unavailable_report = run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL", "SPY"],
        end_date = requested_end,
        fetcher = function (row; kwargs...)
            row.ticker == "AAPL" && error("HTTP 404 token=canary-secret")
            return _canary_eod_fixture(requested_end)
        end,
    )
    @test !unavailable_report.success
    @test unavailable_report.collection.unavailable == ["AAPL"]
    @test unavailable_report.collection.updated == ["SPY"]
    @test [observation.ticker for observation in unavailable_report.observations] == ["SPY"]

    failed_report = run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL", "SPY"],
        end_date = requested_end,
        fetcher = function (row; kwargs...)
            row.ticker == "AAPL" && error("HTTP 503 token=canary-secret")
            return _canary_eod_fixture(requested_end)
        end,
    )
    @test !failed_report.success
    @test failed_report.collection.failed == ["AAPL"]
    @test !occursin("canary-secret", only(failed_report.collection.failures).message)

    malformed_report = run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL"],
        end_date = requested_end,
        fetcher = (row; kwargs...) -> DataFrame(
            date = ["not-a-date"],
            close = [100.0],
        ),
    )
    @test !malformed_report.success
    @test malformed_report.collection.failed == ["AAPL"]
    @test only(malformed_report.collection.failures).stage == :normalize
    @test isempty(malformed_report.observations)
end

@testset "Live canary propagates cancellation" begin
    @test_throws InterruptException run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL", "SPY"],
        end_date = Date(2026, 7, 31),
        fetcher = (row; kwargs...) -> throw(InterruptException()),
    )
end

@testset "Live canary CLI fails without leaking configuration or secret" begin
    mktemp() do _, errors
        code = withenv(
            "TIINGO_API_KEY" => "canary-cli-secret",
            "TIINGO_CANARY_WINDOW_DAYS" => "not-an-integer",
        ) do
            redirect_stderr(errors) do
                live_canary_main()
            end
        end
        flush(errors)
        seekstart(errors)
        captured = read(errors, String)
        @test code == 1
        @test occursin("status=FAILED", captured)
        @test !occursin("canary-cli-secret", captured)
        @test !occursin("TIINGO_API_KEY", captured)
        @test !occursin("not-an-integer", captured)
        # A bare status=FAILED made an expired key, an outage and a malformed
        # env var indistinguishable — in the one job whose purpose is telling
        # you which. The exception type discriminates without echoing input.
        @test occursin("reason=ArgumentError", captured)
    end
end

@testset "Live canary validates hard bounds and secret" begin
    fetcher = (row; end_date, kwargs...) -> _canary_eod_fixture(end_date)
    @test_throws ArgumentError run_live_canary(api_key = "", fetcher = fetcher)
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        tickers = String[],
        fetcher = fetcher,
    )
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        tickers = ["AAPL", "AAPL"],
        fetcher = fetcher,
    )
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        tickers = ["NOT-ALLOWLISTED"],
        fetcher = fetcher,
    )
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        window_days = 0,
        fetcher = fetcher,
    )
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        window_days = 31,
        fetcher = fetcher,
    )
    @test_throws ArgumentError run_live_canary(
        api_key = "offline-token",
        end_date = Date(2026, 8, 2),
        utc_today = Date(2026, 8, 2),
        fetcher = fetcher,
    )
end

@testset "Live canary source excludes application persistence" begin
    source = read(joinpath(@__DIR__, "..", "scripts", "live_canary.jl"), String)
    for forbidden in (
        "connect_postgres",
        "connect_duckdb",
        "write_parquet",
        "upsert_stock_data",
        "download_tickers",
        "update_historical",
        "export_to_postgres",
    )
        @test !occursin(forbidden, source)
    end
    @test occursin("writer = observer_writer", source)
    @test !occursin("apiKey", source)
    @test !occursin("writer = nothing", source)

    workflow = read(
        joinpath(@__DIR__, "..", ".github", "workflows", "live-canary.yml"),
        String,
    )
    run_step = findfirst("- name: Run advisory live canary", workflow)
    @test !isnothing(run_step)
    if !isnothing(run_step)
        @test !occursin("TIINGO_API_KEY", workflow[1:(first(run_step) - 1)])
        @test occursin("TIINGO_API_KEY", workflow[first(run_step):end])
    end
end
