using Test
using Dates
using DataFrames
using Tiingo

@testset "Sink-neutral split refresh targets cover an inclusive missed-run range" begin
    observations = DataFrame(
        ticker = Union{Missing,String}[
            "MSFT", "AAPL", "AAPL", "AAPL", "MSFT", missing, "IGNORED",
        ],
        date = Union{Missing,Date}[
            Date(2024, 1, 4),
            Date(2024, 1, 2),
            Date(2024, 1, 3),
            Date(2024, 1, 5),
            missing,
            Date(2024, 1, 3),
            Date(2024, 1, 3),
        ],
        splitFactor = Union{Missing,Float64}[2.0, 2.0, 3.0, 4.0, 2.0, 2.0, missing],
    )

    targets = find_split_refresh_targets(
        observations;
        start_date=Date(2024, 1, 2),
        end_date=Date(2024, 1, 4),
    )

    @test targets == DataFrame(
        ticker=["AAPL", "MSFT"],
        split_date=[Date(2024, 1, 3), Date(2024, 1, 4)],
    )
end

@testset "Sink-neutral split refresh target validation" begin
    valid = DataFrame(
        ticker=["AAPL", "MSFT"],
        date=[Date(2024, 1, 2), Date(2024, 1, 3)],
        splitFactor=[1.0, 2.0],
    )

    @test find_split_refresh_targets(valid) == DataFrame(
        ticker=["MSFT"],
        split_date=[Date(2024, 1, 3)],
    )
    empty_targets = find_split_refresh_targets(valid[1:0, :])
    @test names(empty_targets) == ["ticker", "split_date"]
    @test eltype(empty_targets.ticker) == String
    @test eltype(empty_targets.split_date) == Date
    @test_throws ArgumentError find_split_refresh_targets(
        select(valid, Not(:splitFactor)),
    )
    @test_throws ArgumentError find_split_refresh_targets(
        valid;
        start_date=Date(2024, 1, 4),
        end_date=Date(2024, 1, 3),
    )
end
