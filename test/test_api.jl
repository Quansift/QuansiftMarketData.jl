using Test
using DataFrames
using Dates
using HTTP
using JSON3
using Logging
using Random

# Import the functions using QuansiftMarketData
using QuansiftMarketData
using QuansiftMarketData.API

struct _InterruptingAPIResponseBody
    cancellation::InterruptException
end

Base.String(value::_InterruptingAPIResponseBody) = throw(value.cancellation)
# A real response body is a byte vector, so it answers `length` before
# anything tries to stringify it. The stand-in has to do the same, or the
# size check reaches it first and a MethodError masks the cancellation.
Base.length(::_InterruptingAPIResponseBody) = 0

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
        original_load_attempted = API.ENV_LOAD_ATTEMPTED[]
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
            API.ENV_LOAD_ATTEMPTED[] = original_load_attempted
            if !isnothing(original_key)
                ENV["TIINGO_API_KEY"] = original_key
            else
                pop!(ENV, "TIINGO_API_KEY", nothing)
            end
        end
    end

    @testset "a relative .env follows the caller, not the package" begin
        # A Pkg-installed package lives under ~/.julia/packages/<name>/<hash>/,
        # a directory Pkg owns and re-hashes on every version change. Resolving
        # a relative default there tells the operator to keep a credential
        # somewhere it will be silently orphaned.
        caller_dir = mktempdir()
        package_dir = mktempdir()
        try
            write(joinpath(caller_dir, ".env"), "TIINGO_API_KEY=from-caller\n")
            write(joinpath(package_dir, ".env"), "TIINGO_API_KEY=from-package\n")

            @test API.resolve_env_path(".env"; search_roots=(caller_dir, package_dir)) ==
                  joinpath(caller_dir, ".env")

            # The package directory still answers when the caller has no .env,
            # so a repository checkout keeps working.
            @test API.resolve_env_path(".env"; search_roots=(mktempdir(), package_dir)) ==
                  joinpath(package_dir, ".env")

            # With nothing on disk the caller is named, because that is where
            # the operator should create the file.
            empty_caller = mktempdir()
            @test API.resolve_env_path(".env"; search_roots=(empty_caller, mktempdir())) ==
                  joinpath(empty_caller, ".env")

            # An absolute path is the caller's decision and is never searched.
            absolute = joinpath(package_dir, ".env")
            @test API.resolve_env_path(absolute; search_roots=(caller_dir,)) == absolute
        finally
            rm(caller_dir; force=true, recursive=true)
            rm(package_dir; force=true, recursive=true)
        end
    end

    @testset "a missing key names a writable location" begin
        original_key = get(ENV, "TIINGO_API_KEY", nothing)
        original_load_attempted = API.ENV_LOAD_ATTEMPTED[]
        pop!(ENV, "TIINGO_API_KEY", nothing)
        try
            message = try
                get_api_key(env_path=joinpath(mktempdir(), ".env"), reload_env=true)
                ""
            catch caught
                sprint(showerror, caught)
            end
            @test occursin("TIINGO_API_KEY", message)
            # Never point at the package cache; it is not a place to keep a key.
            @test !occursin(".julia/packages", message)
        finally
            API.ENV_LOAD_ATTEMPTED[] = original_load_attempted
            isnothing(original_key) ? pop!(ENV, "TIINGO_API_KEY", nothing) :
                (ENV["TIINGO_API_KEY"] = original_key)
        end
    end

    @testset "fetch_api_data rejects invalid resource limits before I/O" begin
        arguments = (
            "http://example.invalid",
            Dict{String,String}(),
            Dict{String,String}(),
        )
        @test_throws ArgumentError("max_retries must be >= 1") fetch_api_data(
            arguments...;
            max_retries=0,
        )
        @test_throws ArgumentError(
            "max_response_bytes must be non-negative",
        ) fetch_api_data(
            arguments...;
            max_response_bytes=-1,
        )
    end

    @testset "get_ticker_data sends the Tiingo request contract" begin
        observed_target = Ref("")
        observed_authorization = Ref("")
        handler = function (request)
            observed_target[] = request.target
            observed_authorization[] = something(
                HTTP.header(request, "Authorization"),
                "",
            )
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "[{\"date\":\"2024-01-02\",\"close\":101.25}]",
            )
        end
        ticker_info = DataFrame(
            ticker = ["AAPL"],
            start_date = [Date(2024, 1, 2)],
            end_date = [Date(2024, 1, 3)],
        )[1, :]

        result = _with_loopback_api(handler) do base_url
            get_ticker_data(
                ticker_info;
                api_key="loopback-key",
                base_url,
            )
        end

        request_uri = HTTP.URI(observed_target[])
        @test request_uri.path == "/test/AAPL/prices"
        @test HTTP.queryparams(request_uri) == Dict(
            "startDate" => "2024-01-02",
            "endDate" => "2024-01-03",
        )
        @test observed_authorization[] == "Token loopback-key"
        @test result isa DataFrame
        @test names(result) == ["date", "close"]
        @test only(result.date) == "2024-01-02"
        @test only(result.close) == 101.25
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
            @test caught isa API.ApiStatusError
            @test caught.status == status
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
        @test caught isa API.ApiStatusError
        @test caught.status == 503
        @test requests[] == 2
        @test occursin("HTTP 503", message)
        @test occursin("response body omitted", message)
        @test !occursin(secret, message)
        # An exhausted retryable status is a failure, not an absence.
        @test !API.is_no_data_error(caught)
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
                    caught isa API.ApiStatusError,
                    caught.status,
                    target_requests[],
                    target_authorization[],
                ) == (true, 302, 0, "")
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

    @testset "Retry jitter only ever lengthens the wait" begin
        # Jitter decorrelates retries so concurrent callers do not re-burst in
        # lockstep. It is additive-only on purpose: `Retry-After` is an
        # instruction from the server, and a jitter that could undercut it
        # would turn politeness into a second wave of 429s.
        rng = Random.MersenneTwister(20260815)

        @test API._jittered_delay_seconds(0; rng) == 0
        @test API._jittered_delay_seconds(-3; rng) == -3

        for base in (1, 2, 30, 300)
            for _ in 1:200
                delayed = API._jittered_delay_seconds(base; rng)
                @test delayed >= base
                @test delayed <= API._MAX_RETRY_DELAY_SECONDS
            end
        end

        # The cap holds even when the base is already at it.
        @test API._jittered_delay_seconds(
            API._MAX_RETRY_DELAY_SECONDS;
            rng,
        ) == API._MAX_RETRY_DELAY_SECONDS

        # Same seed, same sequence: the jitter is random, not unpredictable.
        first_run = [
            API._jittered_delay_seconds(8; rng = Random.MersenneTwister(7))
            for _ in 1:3
        ]
        second_run = [
            API._jittered_delay_seconds(8; rng = Random.MersenneTwister(7))
            for _ in 1:3
        ]
        @test first_run == second_run
        # And it actually varies, or it is not jitter.
        varying_rng = Random.MersenneTwister(11)
        samples = [API._jittered_delay_seconds(8; rng = varying_rng) for _ in 1:20]
        @test length(unique(samples)) > 1
    end

    @testset "Oversized responses are refused before parsing" begin
        # Parsing JSON and then constructing a DataFrame multiplies the body
        # allocation, so the transport must reject before either operation.
        requests = Ref(0)
        payload = "[" * join(("{\"index\":$index}" for index in 1:200), ",") * "]"
        handler = function (_)
            requests[] += 1
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                payload,
            )
        end

        caught = _with_loopback_api(handler) do url
            try
                fetch_api_data(
                    url,
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries = 3,
                    retry_delay = 0,
                    max_response_bytes = 16,
                )
                nothing
            catch error
                error
            end
        end

        message = sprint(showerror, caught)
        @test caught isa ErrorException
        @test occursin("over the", message)
        # An oversized response is a permanent condition, so it must not be
        # retried — re-downloading it is the one thing that makes it worse.
        @test requests[] == 1

        # The same response passes under a limit that accommodates it, and a
        # limit of 0 disables the check entirely.
        for limit in (length(payload), 0)
            requests[] = 0
            data = _with_loopback_api(handler) do url
                fetch_api_data(
                    url,
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries = 1,
                    retry_delay = 0,
                    max_response_bytes = limit,
                )
            end
            @test length(data) == 200
            @test requests[] == 1
        end
    end

    @testset "Oversized responses abort during socket streaming" begin
        limit = 16
        reached_after_limit = Ref(false)
        attempts = Ref(0)
        layer = _handler -> function (request; kwargs...)
            attempts[] += 1
            write(request.response.body, fill(UInt8('x'), limit))
            write(request.response.body, UInt8[UInt8('x')])
            reached_after_limit[] = true
            return HTTP.Response(200, "[]")
        end

        HTTP.pushlayer!(layer)
        caught = try
            try
                fetch_api_data(
                    "http://example.invalid",
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries = 3,
                    retry_delay = 0,
                    max_response_bytes = limit,
                )
                nothing
            catch error
                error
            end
        finally
            HTTP.poplayer!()
        end

        @test caught isa ErrorException
        @test occursin("over the $limit byte limit", sprint(showerror, caught))
        @test attempts[] == 1
        @test !reached_after_limit[]
    end

    @testset "Failure classification reads the status, not the wording" begin
        # `_is_unavailable_historical_error` and the retryable inference used
        # to match English substrings on an error whose HTTP status was known
        # at the point it was thrown. An upstream wording change silently
        # reclassified failures. The status now travels with the error.
        @test API._is_retryable_status(429)
        @test API._is_retryable_status(500)
        @test API._is_retryable_status(599)
        @test !API._is_retryable_status(400)
        @test !API._is_retryable_status(404)
        @test !API._is_retryable_status(200)

        @test API._is_unavailable_status(404)
        @test API._is_unavailable_status(410)
        @test !API._is_unavailable_status(503)
        @test !API._is_unavailable_status(400)

        # Wording that disagrees with the status must lose to the status.
        misleading_permanent = API.ApiStatusError(
            400,
            "connection reset while the request timed out",
        )
        misleading_transient = API.ApiStatusError(
            503,
            "no data returned for this security",
        )
        @test !API._is_retryable_status(misleading_permanent.status)
        @test API._is_retryable_status(misleading_transient.status)
        @test !API._is_unavailable_status(misleading_transient.status)
    end

    @testset "transport retries use the bounded delay policy" begin
        attempts = Ref(0)
        layer = _handler -> function (_request; kwargs...)
            attempts[] += 1
            error("injected transport failure")
        end

        HTTP.pushlayer!(layer)
        caught = try
            with_logger(NullLogger()) do
                try
                    fetch_api_data(
                        "http://example.invalid",
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
        finally
            HTTP.poplayer!()
        end

        @test caught isa ErrorException
        @test occursin("injected transport failure", sprint(showerror, caught))
        @test attempts[] == 2
        @test !API.is_no_data_error(caught)
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

        hostile_url =
            "http://review-user:uri-secret@example.invalid/private/path?token=query-secret"
        redacted_url = API._redact_api_error(hostile_url)
        @test !occursin("review-user", redacted_url)
        @test !occursin("uri-secret", redacted_url)
        @test !occursin("query-secret", redacted_url)
        @test occursin("http://[REDACTED]@example.invalid/private/path", redacted_url)
        @test occursin("token=[REDACTED]", redacted_url)

        log_output = IOBuffer()
        layer = _handler -> function (_request; kwargs...)
            return HTTP.Response(200, "[]")
        end
        HTTP.pushlayer!(layer)
        try
            with_logger(SimpleLogger(log_output, Logging.Info)) do
                fetch_api_data(
                    hostile_url,
                    Dict{String,String}(),
                    Dict{String,String}();
                    max_retries=1,
                    allow_empty=true,
                )
            end
        finally
            HTTP.poplayer!()
        end
        captured_log = String(take!(log_output))
        @test !occursin("review-user", captured_log)
        @test !occursin("uri-secret", captured_log)
        @test !occursin("query-secret", captured_log)
        @test occursin("example.invalid/private/path", captured_log)
    end

    @testset "A 200 carrying no rows is a typed absence" begin
        # The absence used to arrive as an `ErrorException`, so every consumer
        # recovered it by matching English in the message. It is not a failure
        # either: the request succeeded, so there is nothing to ask again for.
        requests = Ref(0)
        handler = function (_)
            requests[] += 1
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "[]",
            )
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

        @test caught isa API.NoDataError
        @test !(caught isa ErrorException)
        @test requests[] == 1
        @test occursin("No data returned from", sprint(showerror, caught))
        @test API.is_no_data_error(caught)

        # `allow_empty=true` is the opt-out and still hands back the payload.
        requests[] = 0
        data = _with_loopback_api(handler) do url
            fetch_api_data(
                url,
                Dict{String,String}(),
                Dict{String,String}();
                max_retries=3,
                retry_delay=0,
                allow_empty=true,
            )
        end
        @test isempty(data)
        @test requests[] == 1
    end

    @testset "An unparseable 200 stays an untyped failure" begin
        requests = Ref(0)
        handler = function (_)
            requests[] += 1
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                "<html>bad gateway</html>",
            )
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

        @test caught isa ErrorException
        @test occursin("Invalid JSON response from", sprint(showerror, caught))
        @test requests[] == 1
        # A malformed body is a broken response, not a security with nothing.
        @test !API.is_no_data_error(caught)
    end

    @testset "is_no_data_error asks the type, not the wording" begin
        redacted_url = "https://example.test/daily/AAPL/prices"

        @test API.is_no_data_error(
            API.NoDataError("No data returned from $redacted_url"),
        )
        for status in (404, 410)
            @test API.is_no_data_error(
                API._http_status_error(status, redacted_url, "body"),
            )
        end

        # Any other carried status is a failure, whatever the body said. 429
        # and 503 keep their retries; the retry testsets above pin that.
        for status in (400, 401, 403, 429, 500, 503)
            @test !API.is_no_data_error(
                API.ApiStatusError(status, "no data returned for this security"),
            )
        end

        # Wording alone proves nothing, including the exact wording that used
        # to be load-bearing.
        for message in (
            "No data returned from $redacted_url",
            "HTTP 404 for $redacted_url; response body omitted",
            "HTTP 410 for $redacted_url; response body omitted",
            "Invalid JSON response from $redacted_url",
            "injected transport failure",
        )
            @test !API.is_no_data_error(ErrorException(message))
        end
        @test !API.is_no_data_error(ArgumentError("max_retries must be >= 1"))

        # A distinct type, not a relabelled `ErrorException`.
        @test API.NoDataError <: Exception
        @test !(API.NoDataError <: ErrorException)
    end

    @testset "No-data errors carry only a redacted URL" begin
        hostile_url =
            "http://review-user:uri-secret@example.invalid/private/path?token=query-secret"
        layer = _handler -> function (_request; kwargs...)
            return HTTP.Response(200, "[]")
        end

        HTTP.pushlayer!(layer)
        caught = try
            with_logger(NullLogger()) do
                try
                    fetch_api_data(
                        hostile_url,
                        Dict{String,String}(),
                        Dict{String,String}();
                        max_retries=1,
                        retry_delay=0,
                    )
                    nothing
                catch error
                    error
                end
            end
        finally
            HTTP.poplayer!()
        end

        message = sprint(showerror, caught)
        @test caught isa API.NoDataError
        @test !occursin("review-user", message)
        @test !occursin("uri-secret", message)
        @test !occursin("query-secret", message)
        @test occursin("[REDACTED]", message)
        # Exactly the redacted URL and nothing else: no body, no headers.
        @test message ==
              "No data returned from " * API._redact_api_error(hostile_url)
    end

    @testset "The no-data surface is exported" begin
        for name in (:ApiStatusError, :NoDataError, :is_no_data_error)
            @test name in names(QuansiftMarketData.API)
            @test name in names(QuansiftMarketData)
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
    #     QuansiftMarketData.generate_filtered_tickers(conn)

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
