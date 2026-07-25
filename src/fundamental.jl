using HTTP
using JSON3
using DataFrames
using TimeSeries
using Dates
using DotEnv
using DuckDB
using DBInterface
using ZipFile

"""
    get_fundamental_meta(; api_key=get_api_key(), columns=nothing)

Fetch Tiingo's current Fundamentals metadata snapshot. The endpoint describes
the mapping observed now; it does not provide ticker-validity dates.
"""
function get_fundamental_meta(;
    api_key::String = get_api_key(),
    base_url::String = "https://api.tiingo.com/tiingo/fundamentals",
    return_type::String = "original",
    columns::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    fetcher::Function = _fetch_fundamental_meta_data,
)
    headers = Dict("Content-Type" => "application/json")
    query = Dict("token" => api_key)
    if !isnothing(columns)
        query["columns"] = join(columns, ",")
    end
    data = fetcher("$base_url/meta", query, headers)
    if return_type == "original"
        return data
    elseif return_type == "dataframe"
        return isempty(data) ? DataFrame() : DataFrame(data)
    end
    error("Invalid return_type. Choose 'original' or 'dataframe'.")
end

function _fetch_fundamental_meta_data(url::String, query::Dict, headers::Dict)
    return fetch_api_data(url, query, headers; allow_empty = true)
end

"""
    get_daily_fundamental(ticker::String; api_key=get_api_key(), base_url="https://api.tiingo.com/tiingo/fundamentals", start_date=nothing, end_date=nothing, columns=nothing)

Get daily fundamental data for a given ticker from Tiingo API.
"""
function get_daily_fundamental(
    ticker::String;
    api_key::String = get_api_key(),
    base_url::String = "https://api.tiingo.com/tiingo/fundamentals",
    return_type::String = "original",
    start_date::Union{Date,Nothing} = nothing,
    end_date::Union{Date,Nothing} = nothing,
    columns::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    fetcher::Function = _fetch_daily_fundamental_data,
)
    if !isnothing(start_date) && !isnothing(end_date) && start_date > end_date
        throw(ArgumentError("start_date must be on or before end_date"))
    end

    headers = Dict("Content-Type" => "application/json")
    url = "$base_url/$ticker/daily"
    query = Dict("token" => api_key)
    if !isnothing(start_date)
        query["startDate"] = Dates.format(start_date, "yyyy-mm-dd")
    end
    if !isnothing(end_date)
        query["endDate"] = Dates.format(end_date, "yyyy-mm-dd")
    end
    if !isnothing(columns)
        query["columns"] = join(columns, ",")
    end

    data = fetcher(url, query, headers)
    if return_type == "original"
        return data
    elseif return_type == "dataframe"
        return _daily_fundamental_dataframe(data)
    elseif return_type == "timearray"
        df = _daily_fundamental_dataframe(data)
        return TimeArray(
            df.date,
            Matrix(df[:, Not(:date)]),
            Symbol.(names(df[:, Not(:date)])),
        )
    else
        error("Invalid return_type. Choose 'original', 'dataframe', or 'timearray'.")
    end
end

function _fetch_daily_fundamental_data(url::String, query::Dict, headers::Dict)
    return fetch_api_data(url, query, headers; allow_empty = true)
end

function _daily_fundamental_dataframe(data)::DataFrame
    if isempty(data)
        return DataFrame(
            date = Date[],
            marketCap = Union{Missing,Float64}[],
        )
    end

    df = DataFrame(data)
    if hasproperty(df, :date)
        df.date = _daily_fundamental_date.(df.date)
    end
    if hasproperty(df, :marketCap)
        market_caps = Vector{Union{Missing,Float64}}(undef, nrow(df))
        for (index, value) in enumerate(df.marketCap)
            market_caps[index] = ismissing(value) || isnothing(value) ? missing : Float64(value)
        end
        df.marketCap = market_caps
    end
    return df
end

_daily_fundamental_date(value::Date) = value
_daily_fundamental_date(value) = Date(first(String(value), 10))
