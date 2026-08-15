using Test
using Dates
using DataFrames
using DBInterface
using QuansiftMarketData

@testset "Sync Helper Lookups" begin
    latest_dates_df = DataFrame(
        ticker = ["AAPL", "MSFT"],
        latest_date = [Date("2024-01-02"), Date("2024-01-03")],
    )
    latest_dates_lookup = QuansiftMarketData.Sync.build_latest_date_lookup(latest_dates_df)
    @test latest_dates_lookup["AAPL"] == Date("2024-01-02")
    @test latest_dates_lookup["MSFT"] == Date("2024-01-03")

    tickers = DataFrame(
        ticker = ["AAPL", "MSFT"],
        exchange = ["NASDAQ", "NASDAQ"],
        asset_type = ["Stock", "Stock"],
        start_date = [Date("2020-01-01"), Date("2021-01-01")],
        end_date = [Date("2024-01-05"), Date("2024-01-05")],
    )
    ticker_lookup = QuansiftMarketData.Sync.build_ticker_row_lookup(tickers)
    @test ticker_lookup["AAPL"].start_date == Date("2020-01-01")
    @test ticker_lookup["MSFT"].end_date == Date("2024-01-05")
end

@testset "Split Refresh Targets" begin
    db_path = tempname() * "_split_targets.duckdb"
    conn = connect_duckdb(db_path)

    try
        DBInterface.execute(
            conn,
            """
            INSERT INTO historical_data
                (ticker, date, close, high, low, open, volume, adjClose, adjHigh, adjLow, adjOpen, adjVolume, divCash, splitFactor)
            VALUES
                ('AAPL', '2024-06-10', 100, 101, 99, 100, 1000, 100, 101, 99, 100, 1000, 0, 2.0),
                ('AAPL', '2024-06-09', 99, 100, 98, 99, 900, 99, 100, 98, 99, 900, 0, 1.0),
                ('MSFT', '2024-06-10', 200, 201, 199, 200, 2000, 200, 201, 199, 200, 2000, 0, 1.0),
                ('NVDA', '2024-06-10', 300, 301, 299, 300, 3000, 300, 301, 299, 300, 3000, 0, 10.0)
            """,
        )

        split_targets = QuansiftMarketData.Sync.get_split_refresh_targets(conn, Date("2024-06-10"))
        @test nrow(split_targets) == 2
        @test split_targets.ticker == ["AAPL", "NVDA"]
        @test all(split_targets.split_date .== Date("2024-06-10"))
    finally
        close_duckdb(conn)
        rm(db_path; force=true)
    end
end
