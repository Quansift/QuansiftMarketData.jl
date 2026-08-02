using Test
using Dates
using DataFrames
using TimeSeries
using TiingoJulia

struct OrdinaryFundamentalFetcherError <: Exception
    message::String
end

Base.showerror(io::IO, error::OrdinaryFundamentalFetcherError) =
    print(io, error.message)

@testset "Fundamental meta request contract" begin
    captured = Ref{Any}(nothing)
    payload = [(permaTicker="perm-aapl", ticker="AAPL", isActive=true)]
    fetcher = function (url, query, headers)
        captured[] = (; url, query, headers)
        return payload
    end

    result = get_fundamental_meta(;
        api_key="offline-token",
        base_url="https://example.test/tiingo/fundamentals",
        columns=["permaTicker", "ticker", "isActive"],
        return_type="dataframe",
        fetcher=fetcher,
    )

    @test captured[].url == "https://example.test/tiingo/fundamentals/meta"
    @test captured[].query == Dict(
        "columns" => "permaTicker,ticker,isActive",
    )
    @test captured[].headers == Dict(
        "Content-Type" => "application/json",
        "Authorization" => "Token offline-token",
    )
    @test !occursin("offline-token", captured[].url)
    @test result.permaTicker == ["perm-aapl"]
end

@testset "Daily fundamental request contract" begin
    captured = Ref{Any}(nothing)
    payload = [
        (date = "2026-07-18", marketCap = 3.0e12),
        (date = "2026-07-19T00:00:00.000Z", marketCap = nothing),
    ]
    fetcher = function (url, query, headers)
        captured[] = (; url, query, headers)
        return payload
    end

    result = get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        base_url = "https://example.test/tiingo/fundamentals",
        start_date = Date(2026, 7, 1),
        end_date = Date(2026, 7, 19),
        columns = ["marketCap"],
        return_type = "dataframe",
        fetcher,
    )

    @test captured[].url == "https://example.test/tiingo/fundamentals/AAPL/daily"
    @test captured[].query == Dict(
        "startDate" => "2026-07-01",
        "endDate" => "2026-07-19",
        "columns" => "marketCap",
    )
    @test captured[].headers == Dict(
        "Content-Type" => "application/json",
        "Authorization" => "Token offline-token",
    )
    @test !occursin("offline-token", captured[].url)
    @test result isa DataFrame
    @test result.date == [Date(2026, 7, 18), Date(2026, 7, 19)]
    @test eltype(result.date) == Date
    @test isequal(result.marketCap, Union{Missing,Float64}[3.0e12, missing])
    @test eltype(result.marketCap) == Union{Missing,Float64}
end

@testset "Daily fundamental rejects reversed dates before fetching" begin
    fetch_count = Ref(0)
    fetcher = function (url, query, headers)
        fetch_count[] += 1
        return Any[]
    end

    @test_throws ArgumentError get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        start_date = Date(2026, 7, 20),
        end_date = Date(2026, 7, 19),
        fetcher,
    )
    @test fetch_count[] == 0
end

@testset "Daily fundamental handles empty payload" begin
    result = get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        columns = ["marketCap"],
        return_type = "dataframe",
        fetcher = (url, query, headers) -> Any[],
    )

    @test isempty(result)
    @test names(result) == ["date", "marketCap"]
    @test eltype(result.date) == Date
    @test eltype(result.marketCap) == Union{Missing,Float64}
end

@testset "Daily fundamental return type compatibility" begin
    payload = [(date = "2026-07-18", marketCap = 3.0e12)]
    captured_query = Ref{Any}(nothing)
    captured_headers = Ref{Any}(nothing)
    fetcher = function (url, query, headers)
        captured_query[] = copy(query)
        captured_headers[] = copy(headers)
        return payload
    end

    original = get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        fetcher,
    )
    @test isempty(captured_query[])
    @test captured_headers[]["Authorization"] == "Token offline-token"
    dataframe = get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        return_type = "dataframe",
        fetcher,
    )
    timearray = get_daily_fundamental(
        "AAPL";
        api_key = "offline-token",
        return_type = "timearray",
        fetcher,
    )

    @test original === payload
    @test dataframe isa DataFrame
    @test dataframe.date == [Date(2026, 7, 18)]
    @test timearray isa TimeArray
    @test timestamp(timearray) == [Date(2026, 7, 18)]
    @test values(timearray)[1, 1] == 3.0e12
end

@testset "Fundamental request failures redact header credentials" begin
    api_key = "fundamental-header-secret"
    fetcher = function (url, query, headers)
        error("request failed url=$url query=$query headers=$headers")
    end

    calls = [
        () -> get_fundamental_meta(;
            api_key,
            base_url="https://example.test/tiingo/fundamentals",
            fetcher,
        ),
        () -> get_daily_fundamental(
            "AAPL";
            api_key,
            base_url="https://example.test/tiingo/fundamentals",
            fetcher,
        ),
    ]

    for call in calls
        caught = try
            call()
            nothing
        catch error
            error
        end
        @test caught isa ErrorException
        message = sprint(showerror, caught)
        @test !occursin(api_key, message)
        @test occursin("Authorization", message)
        @test occursin("[REDACTED]", message)
    end
end

@testset "Fundamental request failures preserve safe exception identity" begin
    sentinel = OrdinaryFundamentalFetcherError("ordinary offline failure")
    fetcher = (_, _, _) -> throw(sentinel)

    caught = try
        get_daily_fundamental(
            "AAPL";
            api_key="offline-token",
            base_url="https://example.test/tiingo/fundamentals",
            fetcher,
        )
        nothing
    catch error
        error
    end

    @test caught === sentinel
end
