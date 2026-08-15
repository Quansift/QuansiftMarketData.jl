using Test
using QuansiftMarketData

staging_smoke_script = joinpath(@__DIR__, "..", "scripts", "staging_smoke_test.jl")
include(staging_smoke_script)

function _historical_result(;
    attempted = ["AAPL"],
    updated = String[],
    unchanged = ["AAPL"],
    unavailable = String[],
    failed = String[],
    failures = SyncFailure[],
    written_rows = 0,
)
    return HistoricalCollectionResult(
        attempted,
        updated,
        unchanged,
        unavailable,
        failed,
        failures,
        written_rows,
    )
end

@testset "Staging historical smoke gate accepts persisted unchanged tickers" begin
    result = _historical_result()
    @test validate_staging_historical!(result, 10; sampled_active_tickers=["AAPL"]) === result
end

@testset "Staging historical smoke gate rejects incomplete collection" begin
    failed_result = _historical_result(
        failed=["BAD"],
        failures=[SyncFailure("BAD", :fetch, "temporary failure", true)],
    )
    unavailable_result = _historical_result(
        attempted=["MISSING"],
        unchanged=String[],
        unavailable=["MISSING"],
    )

    @test_throws ErrorException validate_staging_historical!(failed_result, 10)
    @test_throws ErrorException validate_staging_historical!(
        unavailable_result,
        10;
        sampled_active_tickers=["MISSING"],
    )
    @test_throws ErrorException validate_staging_historical!(
        _historical_result(attempted=String[], unchanged=String[]),
        10,
    )
    @test_throws ErrorException validate_staging_historical!(_historical_result(), 0)

    @test_throws ErrorException validate_staging_historical!(
        _historical_result(),
        10;
        sampled_active_tickers=["AAPL", "MSFT"],
    )

    unclassified_result = _historical_result(
        attempted=["AAPL", "MSFT"],
        unchanged=["AAPL"],
    )
    duplicate_classification_result = _historical_result(
        updated=["AAPL"],
        unchanged=["AAPL"],
    )
    @test_throws ErrorException validate_staging_historical!(unclassified_result, 10)
    @test_throws ErrorException validate_staging_historical!(
        duplicate_classification_result,
        10,
    )
end

@testset "Staging export callback runs only after historical gate" begin
    events = Symbol[]
    export_callback = () -> begin
        push!(events, :export)
        return :published
    end

    @test publish_after_staging_gate!(
        _historical_result(),
        10,
        export_callback;
        sampled_active_tickers=["AAPL"],
    ) == :published
    @test events == [:export]

    empty!(events)
    @test_throws ErrorException publish_after_staging_gate!(
        _historical_result(attempted=String[], unchanged=String[]),
        10,
        export_callback,
    )
    @test isempty(events)
end

@testset "Staging smoke uses sink-neutral historical collection" begin
    source = read(staging_smoke_script, String)
    @test occursin("collect_historical(", source)
    @test occursin("upsert_stock_data_bulk", source)
    @test !occursin(r"\bupdate_historical\(", source)
    @test !occursin("TIINGO_SMOKE_USE_PARALLEL", source)
    @test !occursin("TIINGO_SMOKE_BATCH_SIZE", source)
    @test !occursin("TIINGO_SMOKE_MAX_CONCURRENT", source)
end
