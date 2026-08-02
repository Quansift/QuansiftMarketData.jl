using Test
using DataFrames
using Dates
using DBInterface
using DuckDB
using LibPQ
using TiingoJulia

function _pg_integration_query(conn::LibPQ.Connection, sql::String)::DataFrame
    result = LibPQ.execute(conn, sql)
    try
        return DataFrame(result)
    finally
        close(result)
    end
end

function _pg_integration_command(conn::LibPQ.Connection, sql::String)
    close(LibPQ.execute(conn, sql))
    return nothing
end

function _pg_integration_cleanup(conn::LibPQ.Connection)
    for table in (
        "legacy_atomic_child",
        "legacy_atomic_second",
        "legacy_atomic_first",
        "fundamental_daily_metrics",
        "security_observations",
        "historical_data",
        "us_tickers_filtered",
        "us_tickers",
    )
        _pg_integration_command(conn, "DROP TABLE IF EXISTS $table CASCADE")
    end
end

function _pg_integration_read_parquet(path::String)::DataFrame
    conn = DBInterface.connect(DuckDB.DB)
    try
        return DBInterface.execute(
            conn,
            "SELECT * FROM read_parquet('$path') ORDER BY ticker, date",
        ) |> DataFrame
    finally
        DBInterface.close!(conn)
    end
end

pg_connection_string = get(ENV, "TIINGO_TEST_PG_CONNECTION", "")

@testset "PostgreSQL 17 persistence integration" begin
    if isempty(pg_connection_string)
        @test_skip "set TIINGO_TEST_PG_CONNECTION to an isolated PostgreSQL database"
    else
        pg = connect_postgres(pg_connection_string; max_retries = 1)
        try
            server_version_num = only(_pg_integration_query(
                pg,
                "SELECT current_setting('server_version_num')::integer " *
                "AS server_version_num",
            ).server_version_num)
            @test 170_000 <= server_version_num < 180_000

            _pg_integration_cleanup(pg)
            create_tables(pg)

            expected_tables = Set([
                "fundamental_daily_metrics",
                "historical_data",
                "security_observations",
                "us_tickers",
                "us_tickers_filtered",
            ])
            created_tables = _pg_integration_query(
                pg,
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                """,
            )
            @test expected_tables ⊆ Set(String.(created_tables.table_name))

            all_universe = DataFrame(
                ticker = ["AAPL", "SPY"],
                exchange = ["NASDAQ", "NYSE ARCA"],
                asset_type = ["Stock", "ETF"],
                price_currency = ["USD", "USD"],
                start_date = [Date(1980, 12, 12), Date(1993, 1, 22)],
                end_date = fill(Date(2026, 7, 25), 2),
            )
            filtered_universe = all_universe[[1], :]
            @test replace_ticker_universe(
                pg,
                all_universe,
                filtered_universe,
            ) == (all_rows = 2, filtered_rows = 1)

            prices = DataFrame(
                date = [Date(2024, 1, 2), Date(2024, 1, 3)],
                close = Union{Missing,Float64}[missing, 101.0],
                high = Union{Missing,Float64}[missing, 102.0],
                low = Union{Missing,Float64}[missing, 99.0],
                open = Union{Missing,Float64}[missing, 100.0],
                volume = Union{Missing,Int64}[missing, 1_000],
                adjClose = Union{Missing,Float64}[missing, 101.0],
                adjHigh = Union{Missing,Float64}[missing, 102.0],
                adjLow = Union{Missing,Float64}[missing, 99.0],
                adjOpen = Union{Missing,Float64}[missing, 100.0],
                adjVolume = Union{Missing,Int64}[missing, 1_000],
                divCash = Union{Missing,Float64}[missing, 0.0],
                splitFactor = Union{Missing,Float64}[missing, 1.0],
            )
            @test upsert_stock_data_bulk(pg, prices, "AAPL") == 2

            stored_prices = _pg_integration_query(
                pg,
                """
                SELECT date, close, volume, splitfactor
                FROM historical_data
                WHERE ticker = 'AAPL'
                ORDER BY date
                """,
            )
            @test nrow(stored_prices) == 2
            @test isnan(stored_prices.close[1])
            @test stored_prices.volume[1] == 0
            @test stored_prices.splitfactor[1] == 1.0

            updated_prices = copy(prices)
            updated_prices.close[2] = 202.5
            @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT close FROM historical_data WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            ).close) == 202.5

            duplicate_prices = prices[[2, 2], :]
            duplicate_prices.close = [900.0, 901.0]
            @test_throws Exception upsert_stock_data_bulk(pg, duplicate_prices, "AAPL")
            @test only(_pg_integration_query(
                pg,
                "SELECT close FROM historical_data WHERE ticker = 'AAPL' AND date = DATE '2024-01-03'",
            ).close) == 202.5

            observed_at = DateTime(2026, 7, 25, 12)
            observations = DataFrame(
                perma_ticker = ["perm-aapl"],
                observed_at = [observed_at],
                ticker = ["AAPL"],
                is_active = [true],
                is_adr = Union{Missing,Bool}[missing],
                daily_last_updated = Union{Missing,DateTime}[missing],
                exchange = Union{Missing,String}["NASDAQ"],
                asset_type = Union{Missing,String}["Stock"],
                price_coverage_start = Union{Missing,Date}[Date(1980, 12, 12)],
                price_coverage_end = Union{Missing,Date}[Date(2026, 7, 25)],
                is_leveraged = Union{Missing,Bool}[missing],
                join_status = ["matched"],
            )
            @test upsert_security_observations(pg, observations) == 1

            metrics = DataFrame(
                perma_ticker = ["perm-aapl"],
                metric_date = [Date(2024, 1, 3)],
                market_cap = Union{Missing,Float64}[3.0e12],
                enterprise_value = Union{Missing,Float64}[missing],
                pe_ratio = Union{Missing,Float64}[25.0],
                available_at = Union{Missing,DateTime}[missing],
                fetched_at = [observed_at],
                source_revision = Union{Missing,String}[missing],
            )
            @test upsert_fundamental_daily_metrics(pg, metrics) == 1
            stored_metrics = _pg_integration_query(
                pg,
                "SELECT market_cap, enterprise_value, pe_ratio FROM fundamental_daily_metrics",
            )
            @test only(stored_metrics.market_cap) == 3.0e12
            @test ismissing(only(stored_metrics.enterprise_value))
            @test only(stored_metrics.pe_ratio) == 25.0

            duplicate_metrics = metrics[[1, 1], :]
            duplicate_error = try
                upsert_fundamental_daily_metrics(pg, duplicate_metrics)
                nothing
            catch error
                error
            end
            @test duplicate_error isa ArgumentError
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM fundamental_daily_metrics",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "CREATE UNIQUE INDEX tiingo_test_us_tickers_ticker_key " *
                "ON us_tickers (ticker)",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE historical_data ADD CONSTRAINT " *
                "tiingo_test_historical_ticker_fk FOREIGN KEY (ticker) " *
                "REFERENCES us_tickers (ticker)",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE security_observations ADD CONSTRAINT " *
                "tiingo_test_security_ticker_fk FOREIGN KEY (ticker) " *
                "REFERENCES us_tickers (ticker)",
            )

            replacement_universe = all_universe[[2], :]
            replace_error = try
                replace_ticker_universe(
                    pg,
                    replacement_universe,
                    replacement_universe,
                )
                nothing
            catch error
                error
            end
            @test replace_error isa Exception
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE
            @test _pg_integration_query(
                pg,
                "SELECT ticker FROM us_tickers ORDER BY ticker",
            ).ticker == ["AAPL", "SPY"]
            @test _pg_integration_query(
                pg,
                "SELECT ticker FROM us_tickers_filtered ORDER BY ticker",
            ).ticker == ["AAPL"]
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM historical_data WHERE ticker = 'AAPL'",
            ).row_count) == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM security_observations WHERE ticker = 'AAPL'",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "ALTER TABLE historical_data DROP CONSTRAINT " *
                "tiingo_test_historical_ticker_fk",
            )
            _pg_integration_command(
                pg,
                "ALTER TABLE security_observations DROP CONSTRAINT " *
                "tiingo_test_security_ticker_fk",
            )
            _pg_integration_command(
                pg,
                "DROP INDEX tiingo_test_us_tickers_ticker_key",
            )

            @test replace_ticker_universe(
                pg,
                replacement_universe,
                replacement_universe,
            ) == (all_rows = 1, filtered_rows = 1)
            replaced_all = _pg_integration_query(
                pg,
                "SELECT ticker, assettype FROM us_tickers",
            )
            replaced_filtered = _pg_integration_query(
                pg,
                "SELECT ticker, assettype FROM us_tickers_filtered",
            )
            @test replaced_all.ticker == ["SPY"]
            @test replaced_all.assettype == ["ETF"]
            @test replaced_filtered.ticker == ["SPY"]
            @test replaced_filtered.assettype == ["ETF"]
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM historical_data WHERE ticker = 'AAPL'",
            ).row_count) == 2
            @test only(_pg_integration_query(
                pg,
                "SELECT count(*) AS row_count FROM security_observations WHERE ticker = 'AAPL'",
            ).row_count) == 1

            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_first (id BIGINT, generation TEXT)",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_first VALUES (1, 'old-first')",
            )
            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_second (id BIGINT UNIQUE, generation TEXT)",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_second VALUES (1, 'old-second')",
            )
            _pg_integration_command(
                pg,
                "CREATE TABLE legacy_atomic_child (source_id BIGINT REFERENCES legacy_atomic_second(id))",
            )
            _pg_integration_command(
                pg,
                "INSERT INTO legacy_atomic_child VALUES (1)",
            )
            stages_before = _pg_integration_query(
                pg,
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name LIKE '_tiingo_stage_%'
                ORDER BY table_name
                """,
            ).table_name

            legacy_source = DBInterface.connect(DuckDB.DB)
            try
                DBInterface.execute(
                    legacy_source,
                    "CREATE TABLE legacy_atomic_first (id BIGINT, generation VARCHAR)",
                )
                DBInterface.execute(
                    legacy_source,
                    "INSERT INTO legacy_atomic_first VALUES (1, 'new-first')",
                )
                DBInterface.execute(
                    legacy_source,
                    "CREATE TABLE legacy_atomic_second (id BIGINT, generation VARCHAR)",
                )
                DBInterface.execute(
                    legacy_source,
                    "INSERT INTO legacy_atomic_second VALUES (1, 'new-second')",
                )

                @test_throws Exception export_to_postgres(
                    legacy_source,
                    pg,
                    ["legacy_atomic_first", "legacy_atomic_second"];
                    use_dataframe=true,
                    max_retries=1,
                    retry_delay=0,
                )
            finally
                DBInterface.close!(legacy_source)
            end

            @test only(_pg_integration_query(
                pg,
                "SELECT generation FROM legacy_atomic_first",
            ).generation) == "old-first"
            @test only(_pg_integration_query(
                pg,
                "SELECT generation FROM legacy_atomic_second",
            ).generation) == "old-second"
            @test _pg_integration_query(
                pg,
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE '_tiingo_stage_%' ORDER BY table_name",
            ).table_name == stages_before
            @test LibPQ.transaction_status(pg) == LibPQ.libpq_c.PQTRANS_IDLE

            mktempdir() do directory
                destination = joinpath(directory, "historical_data.parquet")
                result = write_parquet(pg, "historical_data", destination)
                @test result.rows == 2
                @test result.columns == 14
                restored = _pg_integration_read_parquet(destination)
                @test restored.ticker == ["AAPL", "AAPL"]
                @test restored.close[2] == 202.5
            end

            hostile_schema = "tiingo_test_hostile_path"
            _pg_integration_command(
                pg,
                "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
            )
            _pg_integration_command(pg, "CREATE SCHEMA $hostile_schema")
            try
                for table in (
                    "us_tickers",
                    "us_tickers_filtered",
                    "historical_data",
                    "security_observations",
                    "fundamental_daily_metrics",
                )
                    _pg_integration_command(
                        pg,
                        "CREATE TABLE $hostile_schema.$table " *
                        "(LIKE public.$table INCLUDING ALL)",
                    )
                end
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.us_tickers " *
                    "(ticker) VALUES ('HOSTILE')",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.us_tickers_filtered " *
                    "(ticker) VALUES ('HOSTILE')",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.historical_data " *
                    "(ticker, date) VALUES ('HOSTILE', DATE '2000-01-01')",
                )
                _pg_integration_command(
                    pg,
                    "CREATE TABLE $hostile_schema.hostile_publish_probe " *
                    "(id BIGINT, generation TEXT)",
                )
                _pg_integration_command(
                    pg,
                    "INSERT INTO $hostile_schema.hostile_publish_probe " *
                    "VALUES (1, 'hostile-sentinel')",
                )
                _pg_integration_command(
                    pg,
                    "SET search_path TO $hostile_schema, public",
                )

                create_tables(pg)
                @test replace_ticker_universe(
                    pg,
                    all_universe,
                    filtered_universe,
                ) == (all_rows=2, filtered_rows=1)
                @test upsert_stock_data_bulk(pg, updated_prices, "AAPL") == 2

                hostile_source = DBInterface.connect(DuckDB.DB)
                try
                    DBInterface.execute(
                        hostile_source,
                        "CREATE TABLE hostile_publish_probe " *
                        "(id BIGINT, generation VARCHAR)",
                    )
                    DBInterface.execute(
                        hostile_source,
                        "INSERT INTO hostile_publish_probe " *
                        "VALUES (1, 'public-generation')",
                    )
                    export_to_postgres(
                        hostile_source,
                        pg,
                        ["hostile_publish_probe"];
                        use_dataframe=true,
                        max_retries=1,
                        retry_delay=0,
                    )
                finally
                    DBInterface.close!(hostile_source)
                end

                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM public.us_tickers ORDER BY ticker",
                ).ticker == ["AAPL", "SPY"]
                @test _pg_integration_query(
                    pg,
                    "SELECT ticker FROM $hostile_schema.us_tickers",
                ).ticker == ["HOSTILE"]
                @test only(_pg_integration_query(
                    pg,
                    "SELECT generation FROM public.hostile_publish_probe",
                ).generation) == "public-generation"
                @test only(_pg_integration_query(
                    pg,
                    "SELECT generation FROM " *
                    "$hostile_schema.hostile_publish_probe",
                ).generation) == "hostile-sentinel"
            finally
                _pg_integration_command(pg, "SET search_path TO public")
                _pg_integration_command(
                    pg,
                    "DROP TABLE IF EXISTS public.hostile_publish_probe CASCADE",
                )
                _pg_integration_command(
                    pg,
                    "DROP SCHEMA IF EXISTS $hostile_schema CASCADE",
                )
            end
        finally
            try
                _pg_integration_cleanup(pg)
            finally
                close_postgres(pg)
            end
        end
    end
end
