@testset "Sync failure classification" begin
    sync_failure = QuansiftMarketData._sync_failure

    @testset "an hourly-quota rejection is distinguishable" begin
        # Tiingo answers 429 once the clock-hour quota is spent. The late cycle
        # collects what this run missed, so the caller must be able to tell this
        # apart from a ticker that is actually broken.
        failure = sync_failure("AAPL", :fetch, ApiStatusError(429, "429 Too Many Requests"))
        @test failure.category === :quota
        @test is_quota_failure(failure)
        @test failure.retryable
    end

    @testset "other retryable statuses are transient, not quota" begin
        failure = sync_failure("AAPL", :fetch, ApiStatusError(503, "503 Service Unavailable"))
        @test failure.category === :transient
        @test !is_quota_failure(failure)
        @test failure.retryable
    end

    @testset "an empty response is no-data, not a failure to retry" begin
        failure = sync_failure("AAPL", :fetch, NoDataError("no rows"))
        @test failure.category === :no_data
        @test !is_quota_failure(failure)
        @test !failure.retryable
    end

    @testset "an unavailable security is no-data" begin
        failure = sync_failure("DELISTED", :fetch, ApiStatusError(404, "404 Not Found"))
        @test failure.category === :no_data
        @test !is_quota_failure(failure)
    end

    @testset "anything else is permanent" begin
        failure = sync_failure("AAPL", :fetch, ApiStatusError(400, "400 Bad Request"))
        @test failure.category === :permanent
        @test !is_quota_failure(failure)
        @test !failure.retryable
    end

    @testset "wording alone never earns the quota category" begin
        # Only a status the thrower committed to counts. An ErrorException that
        # happens to mention a rate limit stays unclassified, matching the
        # reasoning behind is_no_data_error.
        failure = sync_failure("AAPL", :fetch, ErrorException("hit the rate limit"))
        @test failure.category !== :quota
        @test !is_quota_failure(failure)
    end

    @testset "a write failure is never retryable and never quota" begin
        failure = sync_failure("AAPL", :write, ApiStatusError(429, "429 Too Many Requests"))
        @test !failure.retryable
        @test !is_quota_failure(failure)
    end

    @testset "four-argument construction still works" begin
        legacy = SyncFailure("BAD", :fetch, "temporary failure", true)
        @test legacy.retryable
        @test legacy.category === :transient

        permanent = SyncFailure("BAD", :fetch, "bad request", false)
        @test permanent.category === :permanent
    end

    @testset "a result can be asked whether the quota was hit" begin
        quota = sync_failure("AAPL", :fetch, ApiStatusError(429, "429 Too Many Requests"))
        other = sync_failure("MSFT", :fetch, ApiStatusError(503, "503"))

        hit = HistoricalCollectionResult(
            ["AAPL", "MSFT"], String[], String[], String[],
            ["AAPL", "MSFT"], [quota, other], 0,
        )
        missed = HistoricalCollectionResult(
            ["MSFT"], String[], String[], String[],
            ["MSFT"], [other], 0,
        )

        @test any(is_quota_failure, hit.failures)
        @test !any(is_quota_failure, missed.failures)
    end
end
