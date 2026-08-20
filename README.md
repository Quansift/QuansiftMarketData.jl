# QuansiftMarketData.jl

[![Tests](https://img.shields.io/github/actions/workflow/status/Quansift/QuansiftMarketData.jl/CI.yml?branch=main&label=Tests)](https://github.com/Quansift/QuansiftMarketData.jl/actions)
[![Documentation](https://img.shields.io/github/actions/workflow/status/Quansift/QuansiftMarketData.jl/Docs.yml?branch=main&label=Docs)](https://quansift.github.io/QuansiftMarketData.jl/dev)
[![Lint](https://img.shields.io/github/actions/workflow/status/Quansift/QuansiftMarketData.jl/Lint.yml?branch=main&label=Lint)](https://github.com/Quansift/QuansiftMarketData.jl/actions)

QuansiftMarketData is a Julia client for collecting Tiingo end-of-day stock
and ETF prices and Fundamentals data. It normalizes API responses into
`DataFrame`s and provides optional PostgreSQL, Parquet, and DuckDB persistence
primitives.

> [!IMPORTANT]
> QuansiftMarketData is an unofficial, community-maintained project. It is not
> affiliated with, endorsed by, or sponsored by Tiingo, Inc. This project does
> not use the Tiingo logo. Each user must obtain their own Tiingo API key and
> use Tiingo services and data in accordance with the
> [Tiingo Terms of Use](https://api.tiingo.com/tos/). The software license does
> not grant rights to Tiingo data. It does not bundle or redistribute Tiingo
> data. Tiingo is a provider trademark. This is not legal advice.

- [Tiingo official website](https://www.tiingo.com/)
- [Tiingo API documentation](https://www.tiingo.com/documentation/general/overview)

## What it does

- Fetches the Tiingo ticker universe, EOD stock and ETF prices, and
  Fundamentals data.
- Validates and normalizes responses into canonical Julia `DataFrame`s.
- Supports sink-independent historical and Fundamentals collection.
- Provides optional PostgreSQL upserts, atomic Parquet writes, and local
  DuckDB storage.

## Getting started

### 1. Get a Tiingo API key

Create an account at [Tiingo](https://www.tiingo.com/) and obtain an API key.
Review the [Tiingo Terms of Use](https://api.tiingo.com/tos/) before requesting,
processing, or storing data.

### 2. Install the package

Until the package is registered in Julia's General registry, install it from
GitHub together with `DataFrames`, which the example below uses:

```julia
using Pkg
Pkg.add(url="https://github.com/Quansift/QuansiftMarketData.jl")
Pkg.add("DataFrames")
```

### 3. Set the API key

Set `TIINGO_API_KEY` in your shell before starting Julia. This prompts without
displaying the key or placing it in the command itself:

```bash
read -s TIINGO_API_KEY
export TIINGO_API_KEY
```

Do not commit API keys. For automated environments, use the platform's secret
manager rather than storing the key in source code.

### 4. Fetch and normalize AAPL EOD prices

```julia
using Dates
using DataFrames
using QuansiftMarketData

start_date = Date("2024-01-01")
end_date = Date("2024-01-31")
ticker = DataFrame(
    ticker=["AAPL"],
    start_date=[start_date],
    end_date=[end_date],
)[1, :]

raw_prices = get_ticker_data(ticker; start_date, end_date)
prices = normalize_eod_prices(raw_prices; start_date, end_date)

first(prices, 5)
```

`get_ticker_data` reads `TIINGO_API_KEY` by default. Passing date bounds to
`normalize_eod_prices` also validates that returned observations are within the
requested range.

### 5. Optionally persist normalized data

Only persist Tiingo data when your current plan and the Terms permit it. For
example, write the normalized frame to Parquet:

```julia
result = write_parquet(prices, "aapl.parquet")
```

PostgreSQL, DuckDB, ticker-universe, batch collection, and Fundamentals examples
are in the [full documentation](https://quansift.github.io/QuansiftMarketData.jl/dev).

## Main API

- EOD: `get_ticker_data`, `normalize_eod_prices`, `collect_historical`
- Tickers: `collect_ticker_universe`
- Fundamentals: `get_fundamental_meta`, `get_daily_fundamental`,
  `collect_fundamentals`
- Persistence: `upsert_*`, `replace_ticker_universe`, `write_parquet`

## Documentation and contributing

- [Documentation](https://quansift.github.io/QuansiftMarketData.jl/dev)
- [Contributing guide](docs/src/90-contributing.md)
- [Production operations](docs/architecture/80-production-operations.md)
- [Changelog](CHANGELOG.md)
- [Citation](CITATION.cff)
