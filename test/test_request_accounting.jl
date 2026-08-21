using Test
using QuansiftMarketData
using QuansiftMarketData.API: fetch_api_data

# Tiingo meters hourly *requests*, not tickers. One incremental ticker is
# normally one request, but a long date range is chunked and a retryable
# failure is retried, and both spend quota invisibly. Counting at the ticker
# loop would miss exactly the two things nobody can currently see, which is why
# the counter lives at the point requests are issued.
#
# example.invalid cannot resolve — RFC 2606 reserves it — so these exercise the
# real function without reaching a network.
const _UNREACHABLE = "https://example.invalid/prices"

_attempt(; kwargs...) = try
    fetch_api_data(
        _UNREACHABLE,
        Dict{String,String}(),
        Dict{String,String}();
        allow_empty = true,
        kwargs...,
    )
catch
    # Reaching the host is not the point; the attempt is.
    nothing
end

@testset "HTTP requests are counted where they are made" begin
    @testset "the counter can be zeroed before a phase" begin
        reset_api_request_count!()
        @test api_request_count() == 0
    end

    @testset "an attempt counts" begin
        reset_api_request_count!()
        _attempt(max_retries = 1, retry_delay = 0)
        @test api_request_count() == 1
    end

    @testset "retries are counted, not collapsed into one" begin
        # This is the number the operator is missing. A run that retried every
        # ticker twice spent three times the quota its ticker count suggests.
        reset_api_request_count!()
        _attempt(max_retries = 3, retry_delay = 0)
        @test api_request_count() == 3
    end

    @testset "counts accumulate across calls until reset" begin
        reset_api_request_count!()
        _attempt(max_retries = 1, retry_delay = 0)
        _attempt(max_retries = 1, retry_delay = 0)
        @test api_request_count() == 2

        reset_api_request_count!()
        @test api_request_count() == 0
    end
end
