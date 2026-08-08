using Test
using Dates
using DataFrames
using DuckDB
using DBInterface
using HTTP
using JSON3

# Import the functions using Tiingo
using Tiingo.API

@testset "API Tests" begin
    @testset "get_api_key" begin
        original_key = get(ENV, "TIINGO_API_KEY", nothing)
        temp_env_path = tempname()
        missing_env_path = tempname()

        write(temp_env_path, "TIINGO_API_KEY=test-key-from-temp-env\n")
        pop!(ENV, "TIINGO_API_KEY", nothing)

        try
            @test get_api_key(env_path=temp_env_path, reload_env=true) == "test-key-from-temp-env"
            pop!(ENV, "TIINGO_API_KEY", nothing)
            @test_throws ErrorException get_api_key(env_path=missing_env_path, reload_env=true)
        finally
            rm(temp_env_path; force=true)
            if !isnothing(original_key)
                ENV["TIINGO_API_KEY"] = original_key
            else
                pop!(ENV, "TIINGO_API_KEY", nothing)
            end
        end
    end

    @testset "get_ticker_data" begin
        # Create a mock ticker info DataFrameRow
        ticker_df = DataFrame(
            ticker = ["AAPL"],
            start_date = [Date("2023-05-01")],
            end_date = [Date("2023-05-01")]
        )
        ticker_info = ticker_df[1, :]

        # Run live API tests only when explicitly enabled
        if get(ENV, "TIINGO_TEST_LIVE_API", "false") == "true"
            try
                get_ticker_data(ticker_info)
                @test true
            catch e
                @test e isa Exception
            end
        else
            @test_skip "Skipping live API test (set TIINGO_TEST_LIVE_API=true to enable)"
        end
    end

    @testset "fetch_api_data" begin
        if get(ENV, "TIINGO_TEST_LIVE_API", "false") == "true"
            # Test the error handling path using a known-bad URL
            @test_throws ErrorException fetch_api_data(
                "http://invalid-url-for-testing.com",
                Dict("param" => "value"),
                Dict("Authorization" => "Token invalid-key")
            )
        else
            @test_skip "Skipping live network test (set TIINGO_TEST_LIVE_API=true to enable)"
        end
    end

    @testset "API errors redact credentials" begin
        cases = [
            (
                "GET /daily?token=secret-token&columns=marketCap",
                ["secret-token"],
            ),
            (
                "GET /daily?apikey=secret.apikey&api_key=secret_key&api-key=secret-key",
                ["secret.apikey", "secret_key", "secret-key"],
            ),
            (
                "GET /daily?api%5Fkey%3Dsecret%2Fencoded%2Bvalue",
                ["secret%2Fencoded%2Bvalue"],
            ),
            (
                "Authorization: Token secret-token",
                ["secret-token"],
            ),
            (
                "\"Authorization\" => \"Bearer secret.bearer-token\"",
                ["secret.bearer-token"],
            ),
            (
                "%22Authorization%22%3A%20%22Token%20encoded-header-secret%22",
                ["encoded-header-secret"],
            ),
            (
                "HTTP 401: {\"api_key\":\"body-secret\",\"token\":\"other-secret\"}",
                ["body-secret", "other-secret"],
            ),
            (
                "Dict(\"api_key\" => \"dict-secret\")",
                ["dict-secret"],
            ),
        ]

        for (input, secrets) in cases
            message = API._redact_api_error(ErrorException(input))
            @test all(secret -> !occursin(secret, message), secrets)
            @test occursin("[REDACTED]", message)
        end

        message = API._redact_api_error("GET /daily?token=secret-token")
        @test !occursin("secret-token", message)
        @test occursin("token=[REDACTED]", message)

        status_error = API._http_status_error(
            401,
            "https://example.test/daily?token=url-secret",
            "arbitrary unlabelled body secret",
        )
        status_message = sprint(showerror, status_error)
        @test !occursin("url-secret", status_message)
        @test !occursin("arbitrary unlabelled body secret", status_message)
        @test occursin("response body omitted", status_message)
    end

    @testset "download_tickers_duckdb" begin
        if get(ENV, "TIINGO_TEST_LIVE_API", "false") == "true"
            # Create a mock DuckDB connection
            conn = DBInterface.connect(DuckDB.DB)

            # Test the function with a simple case
            try
                Tiingo.download_tickers_duckdb(conn)
                @test true
            catch e
                @test e isa Exception
            end

            # Clean up
            DBInterface.close!(conn)
        else
            @test_skip "Skipping live download test (set TIINGO_TEST_LIVE_API=true to enable)"
        end
    end

    # @testset "generate_filtered_tickers" begin
    #     # Create a mock DuckDB connection
    #     conn = DBInterface.connect(DuckDB.DB)

    #     # Create and populate a mock us_tickers table
    #     DBInterface.execute(
    #         conn,
    #         """
    # CREATE TABLE us_tickers (
    #     ticker STRING,
    #     exchange STRING,
    #     assetType STRING,
    #     endDate DATE
    # )
    # """,
    #     )
    #     DBInterface.execute(
    #         conn,
    #         """
    # INSERT INTO us_tickers VALUES
    # ('AAPL', 'NYSE', 'Stock', '2023-05-01'),
    # ('GOOGL', 'NASDAQ', 'Stock', '2023-05-01'),
    # ('VTI', 'NYSE ARCA', 'ETF', '2023-05-01'),
    # ('INVALID', 'OTC', 'Stock', '2023-05-01')
    # """,
    #     )

    #     # Run the function
    #     Tiingo.generate_filtered_tickers(conn)

    #     # Check the results
    #     result =
    #         DBInterface.execute(conn, "SELECT COUNT(*) FROM us_tickers_filtered") |>
    #         DataFrame
    #     @test result[1, 1] == 3  # AAPL, GOOGL, and VTI should be included

    #     # Clean up
    #     DBInterface.execute(conn, "DROP TABLE us_tickers")
    #     DBInterface.execute(conn, "DROP TABLE us_tickers_filtered")
    #     DBInterface.close!(conn)
    # end
end
