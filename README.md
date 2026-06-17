# TiingoJulia

A Julia package for downloading and managing financial data from the Tiingo API, with high-performance DuckDB storage and parallel processing capabilities.

[![Tests](https://img.shields.io/github/actions/workflow/status/10kpw/TiingoJulia/CI.yml?branch=main&label=Tests)](https://github.com/10kpw/TiingoJulia/actions)
[![Documentation](https://img.shields.io/github/actions/workflow/status/10kpw/TiingoJulia/Docs.yml?branch=main&label=Docs)](https://10kpw.github.io/TiingoJulia/dev)
[![Lint](https://img.shields.io/github/actions/workflow/status/10kpw/TiingoJulia/Lint.yml?branch=main&label=Lint)](https://github.com/10kpw/TiingoJulia/actions)

## Features

- **High-Performance Data Processing**: Parallel API calls with configurable concurrency
- **DuckDB Integration**: Fast, embedded database storage for financial data
- **Comprehensive Market Coverage**: Support for stocks, ETFs, and fundamental data
- **Flexible Export Options**: Export data to PostgreSQL or other formats
- **Robust Error Handling**: Automatic retry logic and graceful error recovery
- **Memory Optimization**: Automatic memory detection and database optimization

## Installation

```julia
using Pkg
Pkg.add("TiingoJulia")
```

## Quick Start

### 1. Set up environment variables safely

Create a local `.env` from the template:

```bash
cp .env.example .env
```

Set your Tiingo key in `.env`:

```env
TIINGO_API_KEY=your_api_key_here
```

`.env` is ignored by git. Do not commit secrets.

### 2. Optional configuration overrides

`config.toml` contains non-secret defaults. You can override values per environment with env vars:
Use `config.example.toml` as a template if you want a custom config file per deployment.

- `TIINGO_CONFIG_PATH`: path to an alternate `config.toml` (legacy `config.json` is still supported)
- `TIINGO_DB_PATH`: default DuckDB path
- `TIINGO_API_BASE_URL`: Tiingo daily base URL
- `TIINGO_TICKERS_URL`: ticker zip URL
- `TIINGO_API_MAX_RETRIES`: API retry attempts
- `TIINGO_API_RETRY_DELAY`: API retry base delay (seconds)
- `TIINGO_LOG_FILE`: log file path
- `TIINGO_DUCKDB_TMP`: DuckDB scratch/temp directory
- `TIINGO_DUCKDB_MEMORY_LIMIT_GB`: override DuckDB memory limit in GB
- `TIINGO_DUCKDB_THREADS`: override DuckDB worker thread count for query execution
- `TIINGO_DUCKDB_WORKER_THREADS`: override DuckDB background worker thread count
- `TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER`: set to `false` to reduce ingest memory pressure
- `TIINGO_DUCKDB_UPSERT_CHUNK_SIZE`: rows per transaction during historical-data upserts
- `TIINGO_SUPPORTED_EXCHANGES`: comma-separated exchange list
- `TIINGO_SUPPORTED_ASSET_TYPES`: comma-separated asset type list

Package/runtime variables are documented in `.env.example`.
The current scheduled pipeline variables are documented in `.env.staging.example`.
Set overrides before running `using TiingoJulia`.
For a real-environment validation pass before launch, use [`scripts/staging_smoke_test.jl`](scripts/staging_smoke_test.jl) with [`PRODUCTION.md`](PRODUCTION.md).

### 3. Basic Usage

```julia
using TiingoJulia

# Connect to DuckDB database (creates tiingo_historical_data.duckdb by default)
conn = connect_duckdb("my_financial_data.duckdb")

# Optimize database for your system
optimize_database(conn)

# Download and process ticker information
download_tickers_duckdb(conn)

# Get filtered tickers for US markets
tickers = get_tickers_stock(conn)  # Get all stocks
etfs = get_tickers_etf(conn)      # Get all ETFs
all_tickers = get_tickers_all(conn) # Get all instruments

# Update historical data with parallel processing
update_historical(conn, tickers[1:100];  # Process first 100 tickers
                  use_parallel=true,
                  batch_size=50,
                  max_concurrent=10)
```

### 4. Advanced Configuration

```julia
# Custom database path and settings
db_path = "/path/to/your/financial_data.duckdb"
conn = connect_duckdb(db_path)

# Configure for your system
optimize_database(conn)  # Automatically detects system capabilities

# High-performance batch processing
large_tickers = get_tickers_stock(conn)
update_historical(conn, large_tickers;
                  use_parallel=true,
                  batch_size=100,      # Process 100 tickers per batch
                  max_concurrent=20,   # 20 concurrent API calls
                  add_missing=true)    # Add new tickers automatically
```

## How to Cite

If you use TiingoJulia.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/10kpw/TiingoJulia/blob/main/CITATION.cff).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.
For deployment guidance, see [PRODUCTION.md](PRODUCTION.md).

## Production Deployment

The current Linux deployment path is:

- `systemd timer` as the scheduler
- `docker compose` as the runtime wrapper
- GHCR image tags for preprod/prod promotion
- `.env.staging` / `.env` for application secrets and sync settings
- `/etc/default/tiingojulia-pipeline` for host-side compose selection

`cron` is not the recommended scheduler here. The repo ships `systemd` units and the pipeline depends on Docker plus an external DB network, which `systemd` manages more cleanly.
`TIINGO_DB_PATH` is the intermediate DuckDB file path. `TIINGO_DUCKDB_TMP` is separate and only controls DuckDB scratch space.
On 3GB-class droplets, set `TIINGO_DUCKDB_MEMORY_LIMIT_GB=1`, `TIINGO_DUCKDB_THREADS=1`,
`TIINGO_DUCKDB_WORKER_THREADS=1`, and keep `TIINGO_DUCKDB_PRESERVE_INSERTION_ORDER=false`.

### Required Env Files

Application env file:

- Preprod (`10kpw-non-prod`): `/opt/tiingojulia/.env.staging`
- Prod (`tokusenquant.com`): `/opt/tiingojulia/.env`

Host-side `systemd` env file:

- Both hosts: `/etc/default/tiingojulia-pipeline`

The app env file should contain the variables you actually want inside the container, for example:

```dotenv
TIINGO_API_KEY=replace_me_with_real_tiingo_api_key
TIINGO_PG_CONNECTION=postgresql://USER:PASS@postgres:5432/DB?sslmode=disable
TIINGO_LOGGER=console
TIINGO_SMOKE_TICKER_LIMIT=25
TIINGO_SMOKE_BATCH_SIZE=25
TIINGO_SMOKE_MAX_CONCURRENT=5
TIINGO_SMOKE_USE_PARALLEL=false
TIINGO_SMOKE_EXPORT_POSTGRES=true
```

The host-side `systemd` env file selects which image/env/network `docker compose` should use:

```dotenv
TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
TIINGO_IMAGE_TAG=staging
TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env.staging
TIINGO_DOCKER_NETWORK=db-net
TIINGO_DB_HOST_DIR=/home/shin/tiingo/data
TIINGO_DB_CONTAINER_DIR=/data
```

### 10kpw Droplet

Copy-paste path for preprod (`10kpw-non-prod`):

```bash
sudo mkdir -p /opt/tiingojulia
sudo chown "$USER":"$USER" /opt/tiingojulia
git clone https://github.com/10kpw/TiingoJulia.git /opt/tiingojulia
cd /opt/tiingojulia

cp .env.staging.example .env.staging

cat >/tmp/tiingojulia-pipeline <<'EOF'
TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
TIINGO_IMAGE_TAG=staging
TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env.staging
TIINGO_DOCKER_NETWORK=db-net
TIINGO_DB_HOST_DIR=/home/shin/tiingo/data
TIINGO_DB_CONTAINER_DIR=/data
EOF

sudo install -m 0644 /tmp/tiingojulia-pipeline /etc/default/tiingojulia-pipeline
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer /etc/systemd/system/
sudo systemctl daemon-reload

echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin

docker compose -f deploy/compose/docker-compose.pipeline.yml pull pipeline
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline

sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer
journalctl -u tiingojulia-pipeline.service -f
```

Edit `/opt/tiingojulia/.env.staging` before the first run and set at least:

- `TIINGO_API_KEY`
- `TIINGO_PG_CONNECTION` if PostgreSQL export is enabled
- `TIINGO_SMOKE_EXPORT_POSTGRES=true` when you want the export path validated

### TokusenQuant.com

Copy-paste path for prod (`tokusenquant.com`):

```bash
sudo mkdir -p /opt/tiingojulia
sudo chown "$USER":"$USER" /opt/tiingojulia
git clone https://github.com/10kpw/TiingoJulia.git /opt/tiingojulia
cd /opt/tiingojulia

cp .env.example .env

cat >/tmp/tiingojulia-pipeline <<'EOF'
TIINGO_IMAGE_REPO=ghcr.io/quansift/tiingojulia
TIINGO_IMAGE_TAG=latest
TIINGO_APP_ENV_FILE=/opt/tiingojulia/.env
TIINGO_DOCKER_NETWORK=db-net
TIINGO_DB_HOST_DIR=/home/shin/tiingo/data
TIINGO_DB_CONTAINER_DIR=/data
EOF

sudo install -m 0644 /tmp/tiingojulia-pipeline /etc/default/tiingojulia-pipeline
sudo cp deploy/systemd/tiingojulia-pipeline.service /etc/systemd/system/
sudo cp deploy/systemd/tiingojulia-pipeline.timer /etc/systemd/system/
sudo systemctl daemon-reload

echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin

docker compose -f deploy/compose/docker-compose.pipeline.yml pull pipeline
docker compose -f deploy/compose/docker-compose.pipeline.yml run --rm pipeline

sudo systemctl enable --now tiingojulia-pipeline.timer
systemctl list-timers tiingojulia-pipeline.timer
journalctl -u tiingojulia-pipeline.service -f
```

Edit `/opt/tiingojulia/.env` before the first run and set:

- `TIINGO_API_KEY`
- `TIINGO_PG_CONNECTION`
- `TIINGO_DB_PATH=/data/tiingo_historical_data.duckdb`
- `TIINGO_SMOKE_EXPORT_POSTGRES=true`
- `TIINGO_SMOKE_TICKER_LIMIT` to the production scope you actually want

At the moment the scheduled container command is still [`scripts/staging_smoke_test.jl`](scripts/staging_smoke_test.jl), so production scope is controlled by `TIINGO_SMOKE_*` variables rather than a separate full-sync entrypoint.

## Contributing

If you want to make contributions of any kind, please first take a look at our [contributing guide directly on GitHub](docs/src/90-contributing.md).

---

### Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

## API Reference

### Core Functions

#### Database Connection and Management

```julia
# Connect to DuckDB with custom path
conn = connect_duckdb("/Users/yourname/Documents/financial_data.duckdb")

# Connect using default path (tiingo_historical_data.duckdb in current directory)
conn = connect_duckdb()

# Optimize database for your system (automatically detects memory and CPU)
optimize_database(conn)

# Create database indexes for better performance
create_indexes(conn)

# Safely close the connection
close_duckdb(conn)
```

#### Ticker Management

```julia
# Download and process latest ticker information
download_tickers_duckdb(conn)

# Get different types of tickers
stocks = get_tickers_stock(conn)        # All stocks
etfs = get_tickers_etf(conn)           # All ETFs
all_instruments = get_tickers_all(conn) # All instruments

# Generate filtered ticker list (US markets only)
generate_filtered_tickers(conn)
```

#### Historical Data Updates

```julia
# High-performance parallel updates
update_historical(conn, tickers;
                  use_parallel=true,      # Enable parallel processing
                  batch_size=50,          # Process 50 tickers per batch
                  max_concurrent=10,      # 10 concurrent API calls
                  add_missing=true)       # Add new tickers automatically

# Sequential processing (for debugging or low-resource environments)
update_historical(conn, tickers;
                  use_parallel=false,
                  add_missing=true)

# Update specific date range
api_key = get_api_key()
ticker_data = get_ticker_data(stocks[1];
                             start_date=Date("2024-01-01"),
                             end_date=Date("2024-12-31"),
                             api_key=api_key)
```

#### Individual Ticker Operations

```julia
# Add historical data for a single ticker
add_historical_data(conn, "AAPL")

# Update split-adjusted data
update_split_ticker(conn, all_instruments)

# Bulk upsert for better performance
upsert_stock_data_bulk(conn, ticker_data, "AAPL")
```

### Database Configuration Examples

#### Different Database Paths

```julia
# Project-specific database
project_db = "/Users/yourname/Projects/trading_analysis/market_data.duckdb"
conn = connect_duckdb(project_db)

# Shared network location
network_db = "/Volumes/SharedDrive/financial_data/tiingo_data.duckdb"
conn = connect_duckdb(network_db)

# Temporary database for testing
temp_db = "/tmp/test_tiingo_data.duckdb"
conn = connect_duckdb(temp_db)
```

#### Memory and Performance Optimization

```julia
# Connect and optimize for your system
conn = connect_duckdb("large_dataset.duckdb")
optimize_database(conn)  # Automatically configures based on system specs

# Manual optimization for high-memory systems
using DBInterface
DBInterface.execute(conn, "SET memory_limit = '32GB'")
DBInterface.execute(conn, "SET threads = 16")
DBInterface.execute(conn, "SET worker_threads = 15")
```

### Complete Workflow Examples

#### Basic Data Collection Workflow

```julia
using TiingoJulia

# Set up database
db_path = "financial_data.duckdb"
conn = connect_duckdb(db_path)
optimize_database(conn)

# Download ticker information
download_tickers_duckdb(conn)

# Get stocks and ETFs
stocks = get_tickers_stock(conn)
etfs = get_tickers_etf(conn)

# Update historical data for top 500 stocks
top_stocks = stocks[1:500, :]
update_historical(conn, top_stocks;
                  use_parallel=true,
                  batch_size=100,
                  max_concurrent=15)

# Clean up
close_duckdb(conn)
```

#### High-Performance Batch Processing

```julia
using TiingoJulia

# Set up for maximum performance
db_path = "/path/to/high_performance_data.duckdb"
conn = connect_duckdb(db_path)
optimize_database(conn)
create_indexes(conn)

# Download latest ticker data
download_tickers_duckdb(conn)

# Process all instruments in large batches
all_tickers = get_tickers_all(conn)
println("Processing $(nrow(all_tickers)) total instruments")

# Split into manageable chunks
chunk_size = 1000
for i in 1:chunk_size:nrow(all_tickers)
    end_idx = min(i + chunk_size - 1, nrow(all_tickers))
    chunk = all_tickers[i:end_idx, :]

    println("Processing chunk $(div(i-1, chunk_size) + 1): tickers $(i)-$(end_idx)")

    update_historical(conn, chunk;
                      use_parallel=true,
                      batch_size=50,
                      max_concurrent=20,
                      add_missing=true)
end

close_duckdb(conn)
```

#### Data Export and Integration

```julia
using TiingoJulia, DataFrames

# Set up source database
source_db = "source_data.duckdb"
conn = connect_duckdb(source_db)

# Query historical data
query = """
SELECT ticker, date, adjClose as price, volume
FROM historical_data
WHERE date >= '2024-01-01'
AND ticker IN ('AAPL', 'GOOGL', 'MSFT')
ORDER BY ticker, date
"""

df = DBInterface.execute(conn, query) |> DataFrame

# Export to PostgreSQL
pg_connection_string = ENV["TIINGO_PG_CONNECTION"]
pg_conn = connect_postgres(pg_connection_string)
export_to_postgres(
    conn,
    pg_conn,
    ["historical_data", "us_tickers_filtered"];
    pg_connection_string=pg_connection_string,
)

# Clean up connections
close_duckdb(conn)
close_postgres(pg_conn)
```

### Error Handling and Logging

```julia
using TiingoJulia, Logging

# Enable detailed logging
ENV["TIINGO_LOGGER"] = "console"

# Set up with error handling
try
    conn = connect_duckdb("my_data.duckdb")
    optimize_database(conn)

    # Verify database integrity
    is_valid, error_msg = verify_duckdb_integrity("my_data.duckdb")
    if !is_valid
        @error "Database integrity check failed: $error_msg"
        return
    end

    # Process data with error recovery
    tickers = get_tickers_stock(conn)
    updated_tickers, missing_tickers = update_historical(conn, tickers[1:100];
                                                        use_parallel=true,
                                                        batch_size=25,
                                                        max_concurrent=8)

    @info "Successfully updated $(length(updated_tickers)) tickers"
    if !isempty(missing_tickers)
        @warn "Missing tickers: $(missing_tickers)"
    end

catch e
    @error "Error in data processing: $e"
finally
    # Always close the connection
    try
        close_duckdb(conn)
    catch
        # Ignore errors during cleanup
    end
end
```

### Environment Configuration

#### .env File Setup

```env
# Required: Your Tiingo API key
TIINGO_API_KEY=your_actual_api_key_here

# Optional: Logging configuration
TIINGO_LOGGER=console    # Default: "console". Options: "null", "console", "tee", "file", "tee-file"

# Optional: PostgreSQL export connection
TIINGO_PG_CONNECTION=postgresql://user:password@host:5432/database?sslmode=require

# Optional: Database configuration
TIINGO_DB_PATH=/path/to/your/preferred/database.duckdb

# Current scheduled pipeline settings
TIINGO_SMOKE_TICKER_LIMIT=25
TIINGO_SMOKE_BATCH_SIZE=25
TIINGO_SMOKE_MAX_CONCURRENT=5
TIINGO_SMOKE_USE_PARALLEL=false
TIINGO_SMOKE_EXPORT_POSTGRES=false
```

#### Database File Organization

```text
your_project/
├── .env                           # API key configuration
├── .env.staging                   # Preprod/smoke settings
├── data/
│   ├── production_data.duckdb     # Main production database
│   ├── test_data.duckdb          # Testing database
│   └── backups/
│       └── backup_2024_01_01.duckdb
├── scripts/
│   ├── run_staging_smoke.sh      # Host-side bounded sync runner
│   └── staging_smoke_test.jl     # Current container entrypoint
└── analysis/
    ├── market_analysis.jl        # Your analysis scripts
    └── reports/
```

## Performance Improvements

TiingoJulia.jl includes significant performance improvements for historical data processing:

### Parallel Processing Enhancements

- **True Parallelism**: Uses Julia's native `Threads.@spawn` for concurrent API calls
- **Job Queue System**: Bounded buffer system to manage resource usage efficiently
- **Robust Error Handling**: Automatic retry logic with exponential backoff
- **Memory Optimization**: Automatic system memory detection and database tuning
- **Platform-Specific Optimization**: Optimized database settings for different operating systems

### Performance Benchmarks

- **Sequential Processing**: ~2-3 tickers per second
- **Parallel Processing**: ~15-25 tickers per second (depends on system and network)
- **Memory Usage**: Automatically optimized based on available system memory
- **Database Performance**: Optimized with proper indexing and bulk operations

See the [Performance Guide](docs/src/PERFORMANCE.md) for detailed benchmarks and tuning parameters.
