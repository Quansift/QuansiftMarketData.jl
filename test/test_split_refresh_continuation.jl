using Test
using Dates
using DataFrames
using DBInterface
using QuansiftMarketData

function _split_refresh_fixture(date::Date, close::Float64)
    return DataFrame(
        date = [date],
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

@testset "Split refresh isolates unavailable and failed tickers" begin
    db_path = tempname() * "_split_refresh.duckdb"
    conn = connect_duckdb(db_path)

    try
        DBInterface.execute(
            conn,
            """
            INSERT INTO historical_data
                (ticker, date, close, high, low, open, volume, adjClose,
                 adjHigh, adjLow, adjOpen, adjVolume, divCash, splitFactor)
            VALUES
                ('GONE', '2024-01-01', 10, 11, 9, 10, 1000, 10, 11, 9, 10, 1000, 0, 1),
                ('EMPTY', '2024-01-01', 20, 21, 19, 20, 1000, 20, 21, 19, 20, 1000, 0, 1),
                ('BROKEN', '2024-01-01', 30, 31, 29, 30, 1000, 30, 31, 29, 30, 1000, 0, 1),
                ('GOOD', '2024-01-01', 40, 41, 39, 40, 1000, 40, 41, 39, 40, 1000, 0, 1)
            """,
        )

        tickers = DataFrame(
            ticker = ["GONE", "EMPTY", "BROKEN", "GOOD"],
            start_date = fill(Date(2024, 1, 1), 4),
            end_date = fill(Date(2024, 1, 2), 4),
        )
        split_targets = DataFrame(
            ticker = ["GONE", "EMPTY", "BROKEN", "GOOD"],
            split_date = fill(Date(2024, 1, 2), 4),
        )
        fetched = String[]
        fetcher = function (row; kwargs...)
            symbol = String(row.ticker)
            push!(fetched, symbol)
            symbol == "GONE" && error("HTTP 404 for unavailable ticker")
            symbol == "EMPTY" && return DataFrame()
            symbol == "BROKEN" && error("HTTP 503 temporary failure")
            return _split_refresh_fixture(Date(2024, 1, 2), 50.0)
        end

        result = QuansiftMarketData.Sync._collect_split_historical(
            conn,
            split_targets,
            tickers,
            "offline-token";
            fetcher,
        )

        @test result isa HistoricalCollectionResult
        @test result.attempted == ["GONE", "EMPTY", "BROKEN", "GOOD"]
        @test fetched == result.attempted
        @test result.updated == ["GOOD"]
        @test result.unavailable == ["GONE", "EMPTY"]
        @test result.failed == ["BROKEN"]
        @test result.written_rows == 1
        @test only(result.failures).entity == "BROKEN"
        @test only(result.failures).stage == :fetch

        preserved = DBInterface.execute(
            conn,
            """
            SELECT ticker, close
            FROM historical_data
            WHERE ticker IN ('GONE', 'EMPTY', 'BROKEN')
            ORDER BY ticker
            """,
        ) |> DataFrame
        @test preserved.ticker == ["BROKEN", "EMPTY", "GONE"]
        @test preserved.close == [30.0, 20.0, 10.0]

        good_rows = DBInterface.execute(
            conn,
            "SELECT date, close FROM historical_data WHERE ticker = 'GOOD' ORDER BY date",
        ) |> DataFrame
        @test good_rows.date == [Date(2024, 1, 1), Date(2024, 1, 2)]
        @test good_rows.close == [40.0, 50.0]
    finally
        close_duckdb(conn)
        rm(db_path; force=true)
    end
end

@testset "Split refresh returns an empty structured result" begin
    db_path = tempname() * "_no_split_refresh.duckdb"
    conn = connect_duckdb(db_path)
    tickers = DataFrame(
        ticker = ["GOOD"],
        start_date = [Date(2024, 1, 1)],
        end_date = [Date(2024, 1, 2)],
    )

    try
        result = update_split_ticker(conn, tickers, "offline-token")
        @test result isa HistoricalCollectionResult
        @test isempty(result.attempted)
        @test isempty(result.updated)
        @test isempty(result.unavailable)
        @test isempty(result.failed)
        @test result.written_rows == 0
    finally
        close_duckdb(conn)
        rm(db_path; force=true)
    end
end

@testset "Split refresh reports targets absent from the current universe" begin
    db_path = tempname() * "_orphan_split_refresh.duckdb"
    conn = connect_duckdb(db_path)
    tickers = DataFrame(
        ticker = ["GOOD"],
        start_date = [Date(2024, 1, 1)],
        end_date = [Date(2024, 1, 2)],
    )

    try
        DBInterface.execute(
            conn,
            """
            INSERT INTO historical_data
                (ticker, date, close, high, low, open, volume, adjClose,
                 adjHigh, adjLow, adjOpen, adjVolume, divCash, splitFactor)
            VALUES
                ('ORPHAN', '2024-01-02', 10, 11, 9, 10, 1000, 10, 11, 9, 10, 1000, 0, 2)
            """,
        )

        result = update_split_ticker(conn, tickers, "offline-token")

        @test result.attempted == ["ORPHAN"]
        @test result.failed == ["ORPHAN"]
        @test isempty(result.updated)
        @test isempty(result.unavailable)
        @test only(result.failures).stage == :normalize
        @test !only(result.failures).retryable

        preserved = DBInterface.execute(
            conn,
            "SELECT close, splitFactor FROM historical_data WHERE ticker = 'ORPHAN'",
        ) |> DataFrame
        @test nrow(preserved) == 1
        @test preserved.close == [10.0]
        @test preserved.splitFactor == [2.0]
    finally
        close_duckdb(conn)
        rm(db_path; force=true)
    end
end
