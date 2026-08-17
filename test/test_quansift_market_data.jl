using QuansiftMarketData
using Test
using DataFrames
using DBInterface

@testset "QuansiftMarketData" begin
    # Use a temporary database file for testing
    test_db_path = tempname() * ".duckdb"

    # Clean up any existing test database
    isfile(test_db_path) && rm(test_db_path)

    conn = connect_duckdb(test_db_path)
    @test isa(conn, DBInterface.Connection)

    # Add some dummy data to us_tickers_filtered
    DBInterface.execute(
        conn,
        """
INSERT INTO us_tickers_filtered (ticker, exchange, assetType, priceCurrency, startDate, endDate)
VALUES ('AAPL', 'NASDAQ', 'Stock', 'USD', '1980-12-12', '2023-08-25')
""",
    )

    tickers_stock = get_tickers_stock(conn)
    @test isa(tickers_stock, DataFrame)
    @test !isempty(tickers_stock)

    close_duckdb(conn)

    # Clean up test database
    rm(test_db_path)
end

@testset "QuansiftMarketData 4 removes DuckDB-first compatibility APIs" begin
    for name in (
        :update_historical,
        :update_historical_parallel,
        :update_historical_sequential,
        :download_tickers_duckdb,
        :add_historical_data,
        :update_split_ticker,
        :export_to_postgres,
    )
        @test !isdefined(QuansiftMarketData, name)
        @test !(name in names(QuansiftMarketData; all=false, imported=false))
    end
end

println("All tests completed successfully!")
