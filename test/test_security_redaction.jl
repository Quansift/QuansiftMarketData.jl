using Test
using DataFrames
using Dates
using Tiingo

@testset "Writer failures redact database credentials" begin
    tickers = DataFrame(
        ticker = ["AAPL"],
        start_date = [Date(2024, 1, 1)],
        end_date = [Date(2024, 1, 2)],
    )
    fetcher = (row; kwargs...) -> DataFrame(
        date = [Date(2024, 1, 2)],
        close = [100.0],
        high = [101.0],
        low = [99.0],
        open = [99.5],
        volume = [1_000],
        adjClose = [100.0],
        adjHigh = [101.0],
        adjLow = [99.0],
        adjOpen = [99.5],
        adjVolume = [1_000],
        divCash = [0.0],
        splitFactor = [1.0],
    )
    writer = function (ticker, frame)
        error(
            "writer timeout " *
            "postgresql://alice:uri-secret@db.example/app " *
            "password=plain-secret PGPASSWORD='env secret' " *
            "{\"password\":\"json-secret\"}",
        )
    end

    result = collect_historical(
        tickers,
        "offline-token";
        fetcher,
        writer,
    )

    failure = only(result.failures)
    @test failure.stage == :write
    @test failure.retryable
    @test occursin("postgresql://[REDACTED]@db.example/app", failure.message)
    @test occursin("password=[REDACTED]", failure.message)
    @test occursin("PGPASSWORD='[REDACTED]'", failure.message)
    @test occursin("\"password\":\"[REDACTED]\"", failure.message)
    for secret in ("alice", "uri-secret", "plain-secret", "env secret", "json-secret")
        @test !occursin(secret, failure.message)
    end
end
