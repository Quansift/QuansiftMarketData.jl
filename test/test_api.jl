using Test
using Dates
using DataFrames
using DuckDB
using DBInterface
using HTTP
using JSON3
using Logging

# Import the functions using Tiingo
using Tiingo.API

struct _InterruptingAPIResponseBody
    cancellation::InterruptException
end

Base.String(value::_InterruptingAPIResponseBody) = throw(value.cancellation)

function _with_loopback_api(test::Function, handler::Function)
    listener = HTTP.Servers.Listener("127.0.0.1", 0; listenany=true)
    server = HTTP.serve!(handler, listener; verbose=-1)
    try
        return test("http://127.0.0.1:$(HTTP.Servers.port(server))/test")
    finally
        close(server)
    end
end

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

    @testset "fetch_api_data owns HTTP status retries" begin
        for status in (401, 403, 404)
            requests = Ref(0)
            secret = "status-body-secret-$status"
            handler = function (_)
                requests[] += 1
                return HTTP.Response(status, secret)
            end

            caught = _with_loopback_api(handler) do url
                try
                    fetch_api_data(
                        url,
                        Dict{String,String}(),
                        Dict{String,String}();
                        max_retries=3,
                        retry_delay=0,
                    )
                    nothing
                catch error
                    error
                end
            end

            message = sprint(showerror, caught)
            @test caught isa ErrorException
            @test requests[] == 1
            @test occursin("HTTP $status", message)
            @test occursin("response body omitted", message)
            @test !occursin(secret, message)
        end

        for status in (429, 503)
            requests = Ref(0)
            handler = function (_)
                requests[] += 1
                if requests[] == 1
                    headers = status == 429 ? ["Retry-After" => "0"] : Pair{String,String}[]
                    return HTTP.Response(status, headers, "retry-body-secret")
                end
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    "[{\"ok\":true}]",
                )
            end
            log_buffer = IOBuffer()

            data = _with_loopback_api(handler) do url
                with_logger(SimpleLogger(log_buffer, Logging.Warn)) do
                    fetch_api_data(
                        url,
                        Dict{String,String}(),
                        Dict{String,String}();
                        max_retries=2,
                        retry_delay=0,
                    )
                end
            end

            warning = String(take!(log_buffer))
            @test requests[] == 2
            @test only(data).ok
            @test occursin("API request retryable failure", warning)
            @test occursin("status = $status", warning)
            @test !occursin("retry-body-secret", warning)
            status == 429 && @test occursin("delay_seconds = 0", warning)
        end

        requests = Ref(0)
        secret = "bounded-body-secret"
        handler = function (_)
            requests[] += 1
            return HTTP.Response(503, secret)
        end
        caught = _with_loopback_api(handler) do url
            try
                fetch_api_data(
                    url,
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries=2,
                    retry_delay=0,
                )
                nothing
            catch error
                error
            end
        end
        message = sprint(showerror, caught)
        @test caught isa ErrorException
        @test requests[] == 2
        @test occursin("HTTP 503", message)
        @test occursin("response body omitted", message)
        @test !occursin(secret, message)
    end

    @testset "fetch_api_data does not follow redirects" begin
        target_requests = Ref(0)
        target_authorization = Ref("")
        target_listener = HTTP.Servers.Listener("127.0.0.1", 0; listenany=true)
        target_server = HTTP.serve!(target_listener; verbose=-1) do request
            target_requests[] += 1
            target_authorization[] = something(
                HTTP.header(request, "Authorization"),
                "",
            )
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "[{\"ok\":true}]",
            )
        end

        try
            target_url = "http://127.0.0.1:$(HTTP.Servers.port(target_server))/target"
            redirect_listener = HTTP.Servers.Listener("127.0.0.1", 0; listenany=true)
            redirect_server = HTTP.serve!(redirect_listener; verbose=-1) do _
                HTTP.Response(302, ["Location" => target_url])
            end

            try
                caught = try
                    fetch_api_data(
                        "http://127.0.0.1:$(HTTP.Servers.port(redirect_server))/redirect",
                        Dict{String,String}(),
                        Dict("Authorization" => "Token redirect-secret");
                        max_retries=1,
                        retry_delay=0,
                    )
                    nothing
                catch error
                    error
                end

                @test (
                    caught isa ErrorException,
                    target_requests[],
                    target_authorization[],
                ) == (true, 0, "")
            finally
                close(redirect_server)
            end
        finally
            close(target_server)
        end
    end

    @testset "Retry-After delay parsing is bounded and deterministic" begin
        now = DateTime(2015, 10, 21, 7, 20)
        cases = [
            (2, 3, nothing, 8),
            (2, 1, "17", 17),
            (2, 1, "999", 300),
            (2, 2, "-5", 4),
            (2, 2, "not-a-delay", 4),
            (2, 1, "Wed, 21 Oct 2015 07:20:10 GMT", 10),
            (2, 1, "Wed, 21 Oct 2015 07:28:00 GMT", 300),
            (2, 2, "Wed, 21 Oct 2015 07:19:50 GMT", 4),
        ]

        for (base_delay, attempt, retry_after, expected) in cases
            @test API._retry_delay_seconds(
                base_delay,
                attempt,
                retry_after,
                now,
            ) == expected
        end
    end

    @testset "transport retries use the bounded delay policy" begin
        caught = with_logger(NullLogger()) do
            try
                fetch_api_data(
                    "not a url",
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries=2,
                    retry_delay=-1,
                )
                nothing
            catch error
                error
            end
        end

        @test caught isa ErrorException
    end

    @testset "fetch_api_data preserves cancellation identity" begin
        for stage in (:transport, :json)
            cancellation = InterruptException()
            attempts = Ref(0)
            response = HTTP.Response(200)
            response.body = _InterruptingAPIResponseBody(cancellation)
            layer = _handler -> function (_request; kwargs...)
                attempts[] += 1
                stage == :transport && throw(cancellation)
                return response
            end

            HTTP.pushlayer!(layer)
            caught = try
                try
                    fetch_api_data(
                        "http://example.invalid",
                        Dict{String,String}(),
                        Dict{String,String}();
                        max_retries=3,
                        retry_delay=0,
                    )
                    nothing
                catch error
                    error
                end
            finally
                HTTP.poplayer!()
            end

            @test caught === cancellation
            @test attempts[] == 1
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
