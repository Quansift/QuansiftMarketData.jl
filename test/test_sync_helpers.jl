using Test
using Dates
using DataFrames
using QuansiftMarketData

@testset "Latest-date lookup" begin
    latest_dates_df = DataFrame(
        ticker = ["AAPL", "MSFT"],
        latest_date = [Date("2024-01-02"), Date("2024-01-03")],
    )
    latest_dates_lookup = QuansiftMarketData.Sync.build_latest_date_lookup(latest_dates_df)
    @test latest_dates_lookup["AAPL"] == Date("2024-01-02")
    @test latest_dates_lookup["MSFT"] == Date("2024-01-03")
end
