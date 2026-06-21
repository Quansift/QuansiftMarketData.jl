module Operations
    using DBInterface
    using DuckDB
    using DataFrames
    using Dates
    using Logging

    using ..Core: DuckDBConnection, validate_identifier

    # Name of the transient view used to expose a DataFrame to DuckDB for a
    # single set-based upsert. Registered just before the INSERT and removed
    # immediately after, so it never collides across calls on one connection.
    const UPSERT_SOURCE_VIEW = "_tiingo_upsert_source"

    """
        execute_upsert_set_based(conn, data, ticker)

    Upsert `data` into `historical_data` with a single set-based statement.

    The DataFrame is registered as a zero-copy DuckDB view and inserted in one
    `INSERT ... SELECT ... ON CONFLICT` round trip, replacing the previous
    per-row prepared-statement loop. `COALESCE` mirrors the old per-row default
    handling (NaN for prices, 0 for volumes, 0.0 dividends, 1.0 split factor).

    Assumes one ticker's data with unique `date` values per call (true for a
    Tiingo daily response); duplicate keys within a batch would violate the
    `ON CONFLICT` target.
    """
    function execute_upsert_set_based(
        conn::DuckDBConnection,
        data::DataFrame,
        ticker::String
    )::Int
        if nrow(data) == 0
            return 0
        end

        DuckDB.register_data_frame(conn, data, UPSERT_SOURCE_VIEW)
        try
            upsert_stmt = """
            INSERT INTO historical_data (ticker, date, close, high, low, open, volume, adjClose, adjHigh, adjLow, adjOpen, adjVolume, divCash, splitFactor)
            SELECT
                CAST(? AS VARCHAR),
                date,
                COALESCE(close, 'nan'::FLOAT),
                COALESCE(high, 'nan'::FLOAT),
                COALESCE(low, 'nan'::FLOAT),
                COALESCE(open, 'nan'::FLOAT),
                COALESCE(volume, 0),
                COALESCE(adjClose, 'nan'::FLOAT),
                COALESCE(adjHigh, 'nan'::FLOAT),
                COALESCE(adjLow, 'nan'::FLOAT),
                COALESCE(adjOpen, 'nan'::FLOAT),
                COALESCE(adjVolume, 0),
                COALESCE(divCash, 0.0),
                COALESCE(splitFactor, 1.0)
            FROM $UPSERT_SOURCE_VIEW
            ON CONFLICT (ticker, date) DO UPDATE SET
                close = EXCLUDED.close,
                high = EXCLUDED.high,
                low = EXCLUDED.low,
                open = EXCLUDED.open,
                volume = EXCLUDED.volume,
                adjClose = EXCLUDED.adjClose,
                adjHigh = EXCLUDED.adjHigh,
                adjLow = EXCLUDED.adjLow,
                adjOpen = EXCLUDED.adjOpen,
                adjVolume = EXCLUDED.adjVolume,
                divCash = EXCLUDED.divCash,
                splitFactor = EXCLUDED.splitFactor
            """
            DBInterface.execute(conn, upsert_stmt, (ticker,))
            return nrow(data)
        finally
            DuckDB.unregister_data_frame(conn, UPSERT_SOURCE_VIEW)
        end
    end

    """
        upsert_stock_data(conn::DuckDBConnection, data::DataFrame, ticker::String)

    Upsert stock data into the historical_data table.
    """
    function upsert_stock_data(
        conn::DuckDBConnection,
        data::DataFrame,
        ticker::String
    )
        try
            return execute_upsert_set_based(conn, data, ticker)
        catch e
            @error "Error upserting stock data for $ticker" exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    """
        upsert_stock_data_bulk(conn::DuckDBConnection, data::DataFrame, ticker::String)

    Bulk upsert stock data into the historical_data table. Filters to `ticker`
    when a `ticker` column is present, then delegates to the set-based upsert.
    """
    function upsert_stock_data_bulk(
        conn::DuckDBConnection,
        data::DataFrame,
        ticker::String
    )
        if nrow(data) == 0
            return 0
        end

        # Filter data for the specific ticker only if the column exists.
        # Use propertynames (Symbols); names() returns Strings and would never match.
        has_ticker_col = :ticker in propertynames(data)
        ticker_data = has_ticker_col ? filter(row -> row.ticker == ticker, data) : data
        if nrow(ticker_data) == 0
            return 0
        end

        try
            return execute_upsert_set_based(conn, ticker_data, ticker)
        catch e
            @error "Error bulk upserting stock data for $ticker" exception=(e, catch_backtrace())
            rethrow(e)
        end
    end

    """
        get_tickers_all(conn::DBInterface.Connection)

    Get all tickers from the us_tickers_filtered table.
    """
    function get_tickers_all(conn::DBInterface.Connection)::DataFrame
        query = """
        SELECT ticker, exchange, assettype as asset_type, startdate as start_date, enddate as end_date
        FROM us_tickers_filtered
        ORDER BY ticker;
        """
        df = DBInterface.execute(conn, query) |> DataFrame
        return df
    end

    """
        get_tickers_etf(conn::DBInterface.Connection)

    Get all ETF tickers from the us_tickers_filtered table.
    """
    function get_tickers_etf(conn::DBInterface.Connection)::DataFrame
        DBInterface.execute(conn, """
        SELECT ticker, exchange, assettype as asset_type, startdate as start_date, enddate as end_date
        FROM us_tickers_filtered
        WHERE assetType = 'ETF'
        ORDER BY ticker;
        """) |> DataFrame
    end

    """
        get_tickers_stock(conn::DBInterface.Connection)

    Get all stock tickers from the us_tickers_filtered table.
    """
    function get_tickers_stock(conn::DBInterface.Connection)::DataFrame
        DBInterface.execute(conn, """
        SELECT ticker, exchange, assettype as asset_type, startdate as start_date, enddate as end_date
        FROM us_tickers_filtered
        WHERE assetType = 'Stock'
        ORDER BY ticker;
        """) |> DataFrame
    end

    """
        get_table_count(conn::DBInterface.Connection, table_name::String)::Int

    Helper function to get the row count of a table.
    """
    function get_table_count(conn::DBInterface.Connection, table_name::String)::Int
        safe_name = validate_identifier(table_name)
        result = DBInterface.execute(conn, "SELECT COUNT(*) FROM $safe_name") |> DataFrame
        return result[1, 1]
    end

    """
        get_latest_dates(conn::DuckDBConnection)
    """
    function get_latest_dates(conn::DuckDBConnection)
        DBInterface.execute(conn, """
            SELECT ticker, MAX(date) as latest_date
            FROM historical_data
            GROUP BY ticker
        """) |> DataFrame
    end

    """
        get_latest_date(conn::DuckDBConnection, symbol::String)::DataFrame
    """
    function get_latest_date(conn::DuckDBConnection, symbol::String)::DataFrame
        DBInterface.execute(conn, """
        SELECT ticker, max(date) + 1 AS latest_date
        FROM historical_data
        WHERE ticker = ?
        GROUP BY 1
        ORDER BY 1;
        """, [symbol]) |> DataFrame
    end
    export upsert_stock_data, upsert_stock_data_bulk
    export get_tickers_all, get_tickers_etf, get_tickers_stock
    export get_table_count, get_latest_dates, get_latest_date
end
