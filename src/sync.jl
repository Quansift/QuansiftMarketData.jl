using ..DB.Core: DuckDBConnection, validate_identifier, validate_file_path, validate_sql_value
using ..DB.Operations
using ..API: get_ticker_data, get_api_key
using ..Tiingo: HistoricalCollectionResult, SyncFailure, _finish_collection, _sync_failure

function _canonical_ticker_universe_frame()::DataFrame
    return DataFrame(
        ticker = String[],
        exchange = Union{Missing,String}[],
        asset_type = Union{Missing,String}[],
        price_currency = Union{Missing,String}[],
        start_date = Union{Missing,Date}[],
        end_date = Union{Missing,Date}[],
    )
end

function _universe_value(row::DataFrameRow, aliases::Tuple)
    for alias in aliases
        hasproperty(row, alias) || continue
        value = getproperty(row, alias)
        return isnothing(value) ? missing : value
    end
    return missing
end

function _universe_string(value)::Union{Missing,String}
    ismissing(value) && return missing
    normalized = strip(String(value))
    return isempty(normalized) ? missing : normalized
end

function _universe_date(value, field_name::String)::Union{Missing,Date}
    ismissing(value) && return missing
    value isa Date && return value
    value isa DateTime && return Date(value)
    try
        return Date(first(String(value), 10))
    catch error
        throw(ArgumentError("invalid $field_name: $error"))
    end
end

function _normalized_ticker(value)::String
    ismissing(value) && throw(ArgumentError("ticker is required"))
    ticker = uppercase(strip(String(value)))
    isempty(ticker) && throw(ArgumentError("ticker cannot be empty"))
    return ticker
end

function _normalize_ticker_universe(source::DataFrame)::DataFrame
    nrow(source) == 0 && return _canonical_ticker_universe_frame()
    result = _canonical_ticker_universe_frame()
    for row in eachrow(source)
        push!(result, (
            ticker = _normalized_ticker(_universe_value(row, (:ticker,))),
            exchange = _universe_string(_universe_value(row, (:exchange,))),
            asset_type = _universe_string(
                _universe_value(row, (:assetType, :assettype, :asset_type)),
            ),
            price_currency = _universe_string(
                _universe_value(row, (:priceCurrency, :pricecurrency, :price_currency)),
            ),
            start_date = _universe_date(
                _universe_value(row, (:startDate, :startdate, :start_date)),
                "start date",
            ),
            end_date = _universe_date(
                _universe_value(row, (:endDate, :enddate, :end_date)),
                "end date",
            ),
        ))
    end
    sort!(result, [:ticker, :exchange])
    return result
end

function _filtered_ticker_universe(universe::DataFrame)::DataFrame
    reference_dates = Date[
        row.end_date
        for row in eachrow(universe)
        if !ismissing(row.end_date) &&
            !ismissing(row.asset_type) && row.asset_type == "Stock" &&
            !ismissing(row.exchange) && row.exchange == "NYSE"
    ]
    isempty(reference_dates) && return _canonical_ticker_universe_frame()
    active_cutoff = maximum(reference_dates)
    supported_exchanges = Set(Config.Filtering.SUPPORTED_EXCHANGES)
    supported_asset_types = Set(Config.Filtering.SUPPORTED_ASSET_TYPES)
    filtered = filter(universe) do row
        !ismissing(row.exchange) && row.exchange in supported_exchanges &&
            !ismissing(row.asset_type) && row.asset_type in supported_asset_types &&
            !ismissing(row.end_date) && row.end_date >= active_cutoff &&
            !occursin("/", row.ticker)
    end
    sort!(filtered, [:ticker, :exchange])
    return filtered
end

"""
    collect_ticker_universe(source::DataFrame)

Normalize a Tiingo ticker-universe frame and return canonical `all` and
stock/ETF `filtered` frames without selecting a persistence backend.
"""
function collect_ticker_universe(source::DataFrame)
    all_tickers = _normalize_ticker_universe(source)
    return (; all = all_tickers, filtered = _filtered_ticker_universe(all_tickers))
end

"""
    collect_ticker_universe(; tickers_url, zip_file_path, csv_file, downloader)

Download and normalize Tiingo's ticker universe. Pass `downloader=nothing` to
read an existing CSV fixture, or inject a downloader that returns a `DataFrame`,
a CSV path, or writes `csv_file` like `download_latest_tickers`.
"""
function collect_ticker_universe(;
    tickers_url::String = Config.API.TICKERS_URL,
    zip_file_path::String = Config.DB.ZIP_FILE_PATH,
    csv_file::String = Config.DB.DEFAULT_CSV_FILE,
    downloader = download_latest_tickers,
)
    zip_existed = isfile(zip_file_path)
    csv_existed = isfile(csv_file)
    downloaded = !isnothing(downloader)
    try
        downloaded_value = isnothing(downloader) ?
            nothing :
            downloader(tickers_url, zip_file_path, csv_file)
        source = if downloaded_value isa DataFrame
            downloaded_value
        elseif downloaded_value isa AbstractString
            CSV.read(String(downloaded_value), DataFrame)
        else
            CSV.read(csv_file, DataFrame)
        end
        return collect_ticker_universe(source)
    finally
        if downloaded
            cleanup_files(
                zip_file_path,
                csv_file;
                delete_zip = !zip_existed,
                delete_csv = !csv_existed,
            )
        end
    end
end

"""
        download_tickers_duckdb(conn::DuckDBConnection; tickers_url, zip_file_path, csv_file)

    Download and process the latest tickers from Tiingo.
    """
    function download_tickers_duckdb(
        conn::DuckDBConnection;
        tickers_url::String = Config.API.TICKERS_URL,
        zip_file_path::String = Config.DB.ZIP_FILE_PATH,
        csv_file::String = Config.DB.DEFAULT_CSV_FILE
    )
        zip_existed = isfile(zip_file_path)
        csv_existed = isfile(csv_file)
        try
            # Step 1: Download and unzip
            @info "Starting ticker download and processing..."
            download_latest_tickers(tickers_url, zip_file_path, csv_file)
            process_tickers_csv(conn, csv_file)

            # Step 2: Create filtered table and verify
            @info "Generating filtered tickers table..."
            create_filtered_tickers(conn)

            # Step 3: Verify the tables were created and have rows
            us_tickers_count = Operations.get_table_count(conn, Config.DB.Tables.US_TICKERS)
            filtered_count = Operations.get_table_count(conn, Config.DB.Tables.US_TICKERS_FILTERED)

            @info "Ticker processing completed" original_count=us_tickers_count filtered_count=filtered_count

            if filtered_count == 0
                @warn "us_tickers_filtered table was created but contains no rows"
            end
        catch e
            @error "Error in download_tickers_duckdb" exception=(e, catch_backtrace())
            rethrow(e)
        finally
            cleanup_files(
                zip_file_path,
                csv_file;
                delete_zip = !zip_existed,
                delete_csv = !csv_existed
            )
        end
    end

    """
        download_latest_tickers(url::String, zip_file_path::String, csv_file::String)

    Download and validate the ticker universe. The CSV is the canonical
    downstream artifact and the ZIP is ancillary retained input. Each file is
    replaced atomically from a same-directory temporary file after validation;
    the two replacements are not a crash-transactional pair.
    """
    function download_latest_tickers(
        url::String = Config.API.TICKERS_URL,
        zip_file_path::String = Config.DB.ZIP_FILE_PATH,
        csv_file::String = Config.DB.DEFAULT_CSV_FILE;
        downloader::Function = HTTP.download,
    )
        abspath(zip_file_path) == abspath(csv_file) &&
            throw(ArgumentError("ZIP and CSV destinations must be different files"))
        zip_dir = dirname(abspath(zip_file_path))
        csv_dir = dirname(abspath(csv_file))
        mkpath(zip_dir)
        mkpath(csv_dir)
        target_basename = basename(csv_file)

        return mktempdir(zip_dir; prefix=".tiingojulia-tickers-zip-") do zip_temporary_directory
            mktempdir(csv_dir; prefix=".tiingojulia-tickers-csv-") do csv_temporary_directory
                temporary_zip = joinpath(zip_temporary_directory, "download.zip")
                temporary_csv = joinpath(csv_temporary_directory, target_basename)
                downloader(url, temporary_zip)
                isfile(temporary_zip) && filesize(temporary_zip) > 0 ||
                    error("Ticker download did not produce a non-empty ZIP archive")

                found = false
                reader = ZipFile.Reader(temporary_zip)
                try
                    for file in reader.files
                        if basename(file.name) == target_basename
                            open(temporary_csv, "w") do io
                                write(io, read(file))
                            end
                            found = true
                            break
                        end
                    end
                finally
                    close(reader)
                end

                found || error(
                    "CSV file '$target_basename' not found in downloaded zip archive",
                )
                parsed = CSV.read(temporary_csv, DataFrame)
                required_columns = Set(["ticker", "exchange", "assetType", "endDate"])
                missing_columns = sort!(collect(setdiff(required_columns, Set(names(parsed)))))
                isempty(missing_columns) || error(
                    "Downloaded ticker CSV is missing required columns: $(join(missing_columns, ", "))",
                )

                Base.Filesystem.rename(temporary_zip, zip_file_path)
                Base.Filesystem.rename(temporary_csv, csv_file)
                @info "Downloaded and unzipped: $target_basename"
                return nothing
            end
        end
    end

    """
        process_tickers_csv(conn::DuckDBConnection, csv_file::String)

    Helper function to process the tickers CSV file and insert into DuckDB.
    """
    function process_tickers_csv(
        conn::DuckDBConnection,
        csv_file::String
    )
        safe_path = validate_file_path(csv_file)
        DBInterface.execute(conn, """
        CREATE OR REPLACE TABLE us_tickers AS
        SELECT * FROM read_csv('$safe_path')
        """)
        @info "Update us_tickers in DuckDB with the CSV"
    end

    """
        create_filtered_tickers(conn::DuckDBConnection)

    Create filtered US tickers table.
    """
    function create_filtered_tickers(conn::DuckDBConnection)
        @info "Generating filtered tickers table..."
        exchanges = join(["'" * validate_sql_value(ex) * "'" for ex in Config.Filtering.SUPPORTED_EXCHANGES], ", ")
        asset_types = join(["'" * validate_sql_value(at) * "'" for at in Config.Filtering.SUPPORTED_ASSET_TYPES], ", ")

        DBInterface.execute(conn, """
            CREATE OR REPLACE TABLE us_tickers_filtered AS
            SELECT * FROM us_tickers
            WHERE exchange IN ($exchanges)
              AND endDate >= (SELECT max(endDate) FROM us_tickers WHERE assetType = 'Stock' and exchange = 'NYSE')
              AND assetType IN ($asset_types)
              AND ticker NOT LIKE '%/%'
        """)
    end

    """
        cleanup_files(zip_file_path::String)

    Helper function to clean up temporary files.
    """
    function cleanup_files(
        zip_file_path::String,
        csv_file::String;
        delete_zip::Bool = true,
        delete_csv::Bool = true
    )
        for (file, should_delete) in ((zip_file_path, delete_zip), (csv_file, delete_csv))
            if should_delete && isfile(file)
                rm(file)
                @info "Cleaned up temporary file: $file"
            end
        end
    end

    """
        generate_filtered_tickers(conn::DuckDBConnection)

    Generate a filtered list of US tickers.
    """
    function generate_filtered_tickers(
        conn::DuckDBConnection
    )
        try
            # Check if us_tickers table exists and has data
            us_tickers_count = Operations.get_table_count(conn, Config.DB.Tables.US_TICKERS)

            if us_tickers_count == 0
                error("us_tickers table is empty or does not exist")
            end

            # Create and populate the filtered table
            create_filtered_tickers(conn)

            # Verify the table was created and has rows
            filtered_count = Operations.get_table_count(conn, Config.DB.Tables.US_TICKERS_FILTERED)

            @info "Original us_tickers count: $us_tickers_count"
            @info "Filtered us_tickers_filtered count: $filtered_count"

            if filtered_count == 0
                @warn "us_tickers_filtered table was created but contains no rows"
            else
                @info "Generated filtered list of US tickers with $filtered_count rows"
            end

        catch e
            @error "Error in generate_filtered_tickers: $(e)"
            rethrow(e)
        end
    end

    """
        update_us_tickers(conn::DuckDBConnection, csv_file::String)

    Update the us_tickers table in the database from a CSV file.
    """
    function update_us_tickers(conn::DuckDBConnection, csv_file::String = Config.DB.DEFAULT_CSV_FILE)
        safe_table = validate_identifier(Config.DB.Tables.US_TICKERS)
        safe_path = validate_file_path(csv_file)
        query = """
        CREATE OR REPLACE TABLE $safe_table AS
        SELECT * FROM read_csv('$safe_path')
        """
        try
            DBInterface.execute(conn, query)
            @info "Updated us_tickers table from file: $csv_file"
        catch e
            @error "Failed to update us_tickers table" exception=(e, catch_backtrace())
            # throw(DatabaseQueryError("Failed to update us_tickers: $e", query)) # Error type not available here
            rethrow(e)
        end
    end

    """
        update_historical(conn::DuckDBConnection, tickers::DataFrame, api_key::String; use_parallel::Bool=false, batch_size::Int=50, max_concurrent::Int=10, add_missing::Bool=true)

    Update historical data for multiple tickers.
    """
    function update_historical(
        conn::DuckDBConnection,
        tickers::DataFrame,
        api_key::String = get_api_key();
        use_parallel::Bool = false,
        batch_size::Int = 50,
        max_concurrent::Int = 10,
        add_missing::Bool = true,
        latest_dates_df::Union{DataFrame,Nothing} = nothing,
        reference_ticker::String = "SPY"
    )
        # Dispatch to parallel or sequential version
        if use_parallel
            return update_historical_parallel(
                conn, tickers, api_key;
                batch_size=batch_size,
                max_concurrent=max_concurrent,
                add_missing=add_missing
            )
        else
            return update_historical_sequential_impl(
                conn, tickers, api_key;
                add_missing=add_missing,
                latest_dates_df=latest_dates_df
            )
        end
    end

    function build_latest_date_lookup(latest_dates_df::DataFrame)::Dict{String,Date}
        latest_dates_lookup = Dict{String,Date}()
        for row in eachrow(latest_dates_df)
            ticker = row.ticker
            latest_date = row.latest_date
            if ismissing(ticker) || isnothing(ticker) ||
               ismissing(latest_date) || isnothing(latest_date)
                continue
            end
            latest_dates_lookup[String(ticker)] = Date(latest_date)
        end
        return latest_dates_lookup
    end

    function build_ticker_row_lookup(tickers::DataFrame)::Dict{String,DataFrameRow}
        ticker_lookup = Dict{String,DataFrameRow}()
        for i in 1:nrow(tickers)
            row = tickers[i, :]
            ticker = row.ticker
            if ismissing(ticker) || ticker === nothing
                continue
            end
            ticker_lookup[String(ticker)] = row
        end
        return ticker_lookup
    end

    function resolve_ticker_end_date(row::DataFrameRow)::Date
        if haskey(row, :end_date)
            return row.end_date
        end
        if haskey(row, :endDate)
            return row.endDate
        end
        return Date(now()) - Day(1)
    end

    function resolve_ticker_start_date(row::DataFrameRow)::Union{Date,Nothing}
        if haskey(row, :start_date)
            return Date(row.start_date)
        end
        if haskey(row, :startDate)
            return Date(row.startDate)
        end
        return nothing
    end

    function _canonical_eod_frame()::DataFrame
        return DataFrame(
            date = Date[],
            close = Union{Missing,Float64}[],
            high = Union{Missing,Float64}[],
            low = Union{Missing,Float64}[],
            open = Union{Missing,Float64}[],
            volume = Union{Missing,Int64}[],
            adjClose = Union{Missing,Float64}[],
            adjHigh = Union{Missing,Float64}[],
            adjLow = Union{Missing,Float64}[],
            adjOpen = Union{Missing,Float64}[],
            adjVolume = Union{Missing,Int64}[],
            divCash = Union{Missing,Float64}[],
            splitFactor = Union{Missing,Float64}[],
        )
    end

    const EOD_PAYLOAD_COLUMNS = [
        :date => (:date,),
        :close => (:close,),
        :high => (:high,),
        :low => (:low,),
        :open => (:open,),
        :volume => (:volume,),
        :adjClose => (:adjClose, :adjclose, :adj_close),
        :adjHigh => (:adjHigh, :adjhigh, :adj_high),
        :adjLow => (:adjLow, :adjlow, :adj_low),
        :adjOpen => (:adjOpen, :adjopen, :adj_open),
        :adjVolume => (:adjVolume, :adjvolume, :adj_volume),
        :divCash => (:divCash, :divcash, :div_cash),
        :splitFactor => (:splitFactor, :splitfactor, :split_factor),
    ]

    function _eod_value(row::DataFrameRow, aliases::Tuple, field::Symbol)
        for alias in aliases
            hasproperty(row, alias) && return getproperty(row, alias)
        end
        throw(ArgumentError("EOD payload is missing required column: $field"))
    end

    function _eod_date(value)::Date
        (ismissing(value) || isnothing(value)) &&
            throw(ArgumentError("EOD date cannot be missing"))
        value isa Date && return value
        value isa DateTime && return Date(value)
        try
            return Date(first(String(value), 10))
        catch error
            throw(ArgumentError("invalid EOD date: $error"))
        end
    end

    function _eod_float(value, field::Symbol)::Union{Missing,Float64}
        (ismissing(value) || isnothing(value)) && return missing
        value isa Real || throw(ArgumentError("$field must be numeric or missing"))
        return Float64(value)
    end

    function _eod_integer(value, field::Symbol)::Union{Missing,Int64}
        (ismissing(value) || isnothing(value)) && return missing
        value isa Real || throw(ArgumentError("$field must be numeric or missing"))
        isinteger(value) || throw(ArgumentError("$field must be an integer or missing"))
        return Int64(value)
    end

    """
        normalize_eod_prices(payload; start_date=nothing, end_date=nothing)

    Normalize one Tiingo EOD response to the complete historical-storage schema.
    Dates are canonical `Date` values, numeric missings are preserved, duplicate
    dates and rows outside the requested range are rejected, and output is
    sorted by date.
    """
    function normalize_eod_prices(
        payload;
        start_date::Union{Date,Nothing} = nothing,
        end_date::Union{Date,Nothing} = nothing,
    )::DataFrame
        !isnothing(start_date) && !isnothing(end_date) && start_date > end_date &&
            throw(ArgumentError("start_date must be on or before end_date"))
        source = payload isa DataFrame ? payload : DataFrame(payload)
        nrow(source) == 0 && return _canonical_eod_frame()

        result = _canonical_eod_frame()
        for row in eachrow(source)
            values = Dict(
                field => _eod_value(row, aliases, field)
                for (field, aliases) in EOD_PAYLOAD_COLUMNS
            )
            date = _eod_date(values[:date])
            !isnothing(start_date) && date < start_date && throw(ArgumentError(
                "EOD row date $date is before requested start date $start_date",
            ))
            !isnothing(end_date) && date > end_date && throw(ArgumentError(
                "EOD row date $date is after requested end date $end_date",
            ))
            push!(result, (
                date = date,
                close = _eod_float(values[:close], :close),
                high = _eod_float(values[:high], :high),
                low = _eod_float(values[:low], :low),
                open = _eod_float(values[:open], :open),
                volume = _eod_integer(values[:volume], :volume),
                adjClose = _eod_float(values[:adjClose], :adjClose),
                adjHigh = _eod_float(values[:adjHigh], :adjHigh),
                adjLow = _eod_float(values[:adjLow], :adjLow),
                adjOpen = _eod_float(values[:adjOpen], :adjOpen),
                adjVolume = _eod_integer(values[:adjVolume], :adjVolume),
                divCash = _eod_float(values[:divCash], :divCash),
                splitFactor = _eod_float(values[:splitFactor], :splitFactor),
            ))
        end
        allunique(result.date) ||
            throw(ArgumentError("EOD payload contains duplicate dates"))
        sort!(result, :date)
        return result
    end

    function _historical_latest_dates(latest_dates)::Dict{String,Date}
        if latest_dates isa DataFrame
            return build_latest_date_lookup(latest_dates)
        elseif latest_dates isa AbstractDict
            return Dict(
                String(ticker) => Date(date)
                for (ticker, date) in latest_dates
                if !ismissing(ticker) && !isnothing(ticker) &&
                    !ismissing(date) && !isnothing(date)
            )
        end
        throw(ArgumentError("latest_dates must be a DataFrame or dictionary"))
    end

    function _is_unavailable_historical_error(error)::Bool
        message = lowercase(sprint(showerror, error))
        return occursin("no data returned", message) ||
            occursin("no data retrieved", message) ||
            occursin("no new data", message) ||
            occursin(r"\bhttp (?:404|410)\b", message)
    end

    """
        find_split_refresh_targets(frame; start_date=nothing, end_date=nothing)

    Find securities with a non-unit split factor in a canonical observation
    frame. The optional date range is inclusive. Missing ticker, date, or split
    factor values are ignored, and the latest split date is returned for each
    ticker in stable ticker order. This function owns no cross-run watermark or
    persistence state.
    """
    function find_split_refresh_targets(
        frame::DataFrame;
        start_date::Union{Date,Nothing}=nothing,
        end_date::Union{Date,Nothing}=nothing,
    )::DataFrame
        !isnothing(start_date) && !isnothing(end_date) && start_date > end_date &&
            throw(ArgumentError("start_date must be on or before end_date"))

        required_columns = [:ticker, :date, :splitFactor]
        missing_columns = filter(
            column -> column ∉ propertynames(frame),
            required_columns,
        )
        isempty(missing_columns) || throw(ArgumentError(
            "split observations are missing required columns: " *
            join(String.(missing_columns), ", "),
        ))

        latest_by_ticker = Dict{String,Date}()
        for (row_index, row) in enumerate(eachrow(frame))
            values = (row.ticker, row.date, row.splitFactor)
            any(value -> ismissing(value) || isnothing(value), values) && continue

            ticker = try
                String(row.ticker)
            catch
                throw(ArgumentError("ticker at row $row_index must be convertible to String"))
            end
            split_date = row.date isa Date ? row.date : throw(ArgumentError(
                "date at row $row_index must be a Date",
            ))
            split_factor = row.splitFactor isa Real ? row.splitFactor : throw(ArgumentError(
                "splitFactor at row $row_index must be numeric",
            ))
            split_factor == 1 && continue
            !isnothing(start_date) && split_date < start_date && continue
            !isnothing(end_date) && split_date > end_date && continue

            latest_by_ticker[ticker] = max(
                split_date,
                get(latest_by_ticker, ticker, split_date),
            )
        end

        tickers = sort!(collect(keys(latest_by_ticker)))
        return DataFrame(
            ticker=tickers,
            split_date=[latest_by_ticker[ticker] for ticker in tickers],
        )
    end

    _historical_row_label(row_index::Integer)::String = "row[$row_index]"

    function _historical_symbol(row::DataFrameRow)::String
        haskey(row, :ticker) || throw(ArgumentError("ticker is required"))
        value = row.ticker
        (ismissing(value) || isnothing(value)) &&
            throw(ArgumentError("ticker is required"))
        symbol = try
            String(value)
        catch
            throw(ArgumentError("ticker must be convertible to String"))
        end
        isempty(strip(symbol)) && throw(ArgumentError("ticker cannot be empty"))
        return symbol
    end

    function _historical_date(
        row::DataFrameRow,
        aliases::Tuple,
        field_name::String,
        default::Union{Date,Nothing},
    )::Union{Date,Nothing}
        for alias in aliases
            haskey(row, alias) || continue
            value = row[alias]
            (ismissing(value) || isnothing(value)) &&
                throw(ArgumentError("$field_name is required"))
            try
                value isa Date && return value
                value isa DateTime && return Date(value)
                return Date(first(String(value), 10))
            catch
                throw(ArgumentError("$field_name must be a valid date"))
            end
        end
        return default
    end

    """
        collect_historical(tickers, api_key=get_api_key(); ...)

    Collect Tiingo EOD batches without choosing a database backend. `fetcher`
    receives the same arguments as `get_ticker_data`. When supplied, `writer`
    is called as `writer(ticker, frame)` and must return the number of rows it
    persisted. Strict mode processes every ticker and then throws
    `SyncIncompleteError` when one or more fetch, normalization, or write
    operations failed.
    """
    function collect_historical(
        tickers::DataFrame,
        api_key::String = get_api_key();
        latest_dates = Dict{String,Date}(),
        add_missing::Bool = true,
        fetcher = get_ticker_data,
        writer = nothing,
        continue_on_error::Bool = true,
        strict::Bool = false,
    )::HistoricalCollectionResult
        latest_dates_lookup = _historical_latest_dates(latest_dates)
        attempted = String[]
        updated = String[]
        unchanged = String[]
        unavailable = String[]
        failed = String[]
        failures = SyncFailure[]
        written_rows = 0

        for (row_index, row) in enumerate(eachrow(tickers))
            symbol = _historical_row_label(row_index)
            try
                symbol = _historical_symbol(row)
            catch error
                push!(attempted, symbol)
                push!(failed, symbol)
                push!(failures, _sync_failure(symbol, :normalize, error; retryable=false))
                (!continue_on_error && !strict) && rethrow()
                continue
            end
            push!(attempted, symbol)

            ticker_end_date = try
                _historical_date(
                    row,
                    (:end_date, :endDate),
                    "end_date",
                    Date(now()) - Day(1),
                )
            catch error
                push!(failed, symbol)
                push!(failures, _sync_failure(symbol, :normalize, error; retryable=false))
                (!continue_on_error && !strict) && rethrow()
                continue
            end
            latest_date = get(latest_dates_lookup, symbol, nothing)
            if !isnothing(latest_date) && latest_date >= ticker_end_date
                push!(unchanged, symbol)
                continue
            elseif isnothing(latest_date) && !add_missing
                push!(unavailable, symbol)
                continue
            end

            start_date = if isnothing(latest_date)
                try
                    _historical_date(
                        row,
                        (:start_date, :startDate),
                        "start_date",
                        nothing,
                    )
                catch error
                    push!(failed, symbol)
                    push!(
                        failures,
                        _sync_failure(symbol, :normalize, error; retryable=false),
                    )
                    (!continue_on_error && !strict) && rethrow()
                    continue
                end
            else
                latest_date + Day(1)
            end
            payload = try
                if isnothing(start_date)
                    fetcher(row; api_key)
                else
                    fetcher(
                        row;
                        start_date,
                        end_date = ticker_end_date,
                        api_key,
                    )
                end
            catch error
                error isa InterruptException && rethrow()
                if _is_unavailable_historical_error(error)
                    push!(unavailable, symbol)
                    continue
                end
                push!(failed, symbol)
                failure = _sync_failure(symbol, :fetch, error)
                push!(failures, failure)
                (!continue_on_error && !strict) && rethrow()
                @warn(
                    "Historical fetch failed for $symbol; continuing",
                    failure_stage=failure.stage,
                    failure_message=failure.message,
                    retryable=failure.retryable,
                )
                continue
            end

            frame = try
                normalize_eod_prices(
                    payload;
                    start_date,
                    end_date = ticker_end_date,
                )
            catch error
                push!(failed, symbol)
                push!(failures, _sync_failure(symbol, :normalize, error; retryable=false))
                (!continue_on_error && !strict) && rethrow()
                continue
            end
            if nrow(frame) == 0
                push!(isnothing(latest_date) ? unavailable : unchanged, symbol)
                continue
            end

            if !isnothing(writer)
                try
                    rows = writer(symbol, frame)
                    rows isa Integer ||
                        throw(ArgumentError("writer must return an integer row count"))
                    rows >= 0 ||
                        throw(ArgumentError("writer row count must be non-negative"))
                    written_rows += rows
                catch error
                    push!(failed, symbol)
                    push!(failures, _sync_failure(symbol, :write, error))
                    (!continue_on_error && !strict) && rethrow()
                    continue
                end
            end
            push!(updated, symbol)
        end

        result = HistoricalCollectionResult(
            attempted,
            updated,
            unchanged,
            unavailable,
            failed,
            failures,
            written_rows,
        )
        return _finish_collection(result, strict)
    end

    function get_split_refresh_targets(conn::DuckDBConnection, end_date::Date)::DataFrame
        return DBInterface.execute(conn, """
            SELECT ticker, MAX(date) AS split_date
            FROM historical_data
            WHERE date = ?
              AND splitFactor <> 1.0
            GROUP BY ticker
            ORDER BY ticker
        """, [end_date]) |> DataFrame
    end

    function update_historical_sequential_impl(
        conn::DuckDBConnection,
        tickers::DataFrame,
        api_key::String;
        add_missing::Bool = true,
        latest_dates_df::Union{DataFrame,Nothing} = nothing
    )
        # Only compute latest dates if not provided (optimization for batch processing)
        if latest_dates_df === nothing
            latest_dates_df = Operations.get_latest_dates(conn)
        end
        latest_dates_lookup = build_latest_date_lookup(latest_dates_df)

        updated_tickers = String[]
        missing_tickers = String[]
        error_tickers = String[]

        for (i, row) in enumerate(eachrow(tickers))
            symbol = row.ticker
            ticker_end_date = resolve_ticker_end_date(row)
            latest_date = get(latest_dates_lookup, symbol, nothing)

            if isnothing(latest_date)
                if add_missing
                    handle_missing_ticker(conn, row, api_key, missing_tickers, updated_tickers)
                else
                    push!(missing_tickers, symbol)
                    @info "$i : $symbol is missing and add_missing=false"
                end
            else
                if latest_date < ticker_end_date
                    @info "$i : $symbol : $(latest_date + Day(1)) ~ $ticker_end_date"
                    try
                        ticker_data = get_ticker_data(
                            row,
                            start_date = latest_date + Day(1),
                            end_date = ticker_end_date,
                            api_key = api_key
                        )
                        if !isempty(ticker_data)
                            Operations.upsert_stock_data(conn, ticker_data, symbol)
                            push!(updated_tickers, symbol)
                        end
                    catch e
                        if (isa(e, ErrorException) && occursin("No data returned", e.msg)) ||
                           (isa(e, AssertionError) && occursin("No data returned", e.msg))
                            @info "$i : $symbol has no new data"
                        else
                            @warn "Failed to update $symbol: $e"
                            push!(error_tickers, symbol)
                        end
                    end
                else
                    @info "$i : $symbol is up to date"
                end
            end
        end

        log_update_results(missing_tickers, updated_tickers, error_tickers, add_missing)
        return (updated_tickers, missing_tickers)
    end

    function update_historical_parallel(
        conn::DuckDBConnection,
        tickers::DataFrame,
        api_key::String = get_api_key();
        batch_size::Int = 50,
        max_concurrent::Int = 10,
        add_missing::Bool = true
    )
        @info "Starting parallel historical data update" total_tickers=nrow(tickers) batch_size max_concurrent

        # Pre-compute latest dates once for all batches
        latest_dates_df = Operations.get_latest_dates(conn)
        latest_dates_lookup = build_latest_date_lookup(latest_dates_df)

        all_updated = String[]
        all_missing = String[]

        # Process tickers in batches
        num_batches = Int(ceil(nrow(tickers) / batch_size))

        for batch_idx in 1:num_batches
            start_idx = (batch_idx - 1) * batch_size + 1
            end_idx = min(batch_idx * batch_size, nrow(tickers))
            batch = tickers[start_idx:end_idx, :]

            @info "Processing batch $batch_idx/$num_batches" tickers_in_batch=nrow(batch)

            # Use Channel for job queue to limit concurrency
            jobs = Channel{Int}(max_concurrent)
            results = Channel{Tuple{String, Bool, Bool, Union{Exception, Nothing}}}(nrow(batch))
            write_queue = Channel{Tuple{String, Union{DataFrame, Nothing}, Bool, Union{Exception, Nothing}}}(nrow(batch))

            # Spawn workers
            @sync begin
                # Single writer to avoid concurrent DB writes on one connection
                @async begin
                    for (ticker, data, success, error) in write_queue
                        if data !== nothing
                            try
                                Operations.upsert_stock_data_bulk(conn, data, ticker)
                                put!(results, (ticker, true, true, nothing))
                            catch e
                                put!(results, (ticker, false, false, e))
                            end
                        else
                            put!(results, (ticker, success, false, error))
                        end
                    end
                    close(results)
                end

                # Producer: add jobs to queue
                @async begin
                    for i in 1:nrow(batch)
                        put!(jobs, i)
                    end
                    close(jobs)
                end

                # Consumers: process jobs with limited concurrency
                worker_tasks = Task[]
                for _ in 1:max_concurrent
                    t = @async begin
                        for job_idx in jobs
                            row = batch[job_idx, :]
                            ticker = row.ticker

                            try
                                ticker_end_date = resolve_ticker_end_date(row)
                                latest_date = get(latest_dates_lookup, ticker, nothing)

                                if isnothing(latest_date)
                                    # Missing ticker
                                    if add_missing
                                        ticker_data = get_ticker_data(row; api_key=api_key)
                                        if !isempty(ticker_data)
                                            put!(write_queue, (ticker, ticker_data, true, nothing))
                                        else
                                            put!(write_queue, (ticker, nothing, false, ErrorException("No data retrieved")))
                                        end
                                    else
                                        put!(write_queue, (ticker, nothing, false, nothing))
                                    end
                                else
                                    if latest_date < ticker_end_date
                                        ticker_data = get_ticker_data(
                                            row,
                                            start_date = latest_date + Day(1),
                                            end_date = ticker_end_date,
                                            api_key = api_key
                                        )
                                        if !isempty(ticker_data)
                                            put!(write_queue, (ticker, ticker_data, true, nothing))
                                        else
                                            put!(write_queue, (ticker, nothing, false, ErrorException("No new data")))
                                        end
                                    else
                                        put!(write_queue, (ticker, nothing, true, nothing))
                                    end
                                end
                            catch e
                                put!(write_queue, (ticker, nothing, false, e))
                            end
                        end
                    end
                    push!(worker_tasks, t)
                end

                # Close write queue when all workers are done
                @async begin
                    for t in worker_tasks
                        wait(t)
                    end
                    close(write_queue)
                end
            end

            # Collect results
            batch_updated = String[]
            batch_missing = String[]

            for (ticker, success, data_written, error) in results
                if data_written
                    push!(batch_updated, ticker)
                end
                if !success
                    push!(batch_missing, ticker)
                    if !isnothing(error)
                        @warn "Failed to update ticker: $ticker" exception=error
                    end
                end
            end

            append!(all_updated, batch_updated)
            append!(all_missing, batch_missing)

            @info "Batch $batch_idx complete" updated=length(batch_updated) missing=length(batch_missing)
        end

        @info "Parallel update completed" total_updated=length(all_updated) total_missing=length(all_missing)
        return (all_updated, all_missing)
    end

    function update_historical_sequential(
        conn::DuckDBConnection,
        tickers::DataFrame,
        api_key::String = get_api_key();
        add_missing::Bool = true
    )
        @info "Starting sequential historical data update" total_tickers=nrow(tickers)
        return update_historical_sequential_impl(conn, tickers, api_key; add_missing=add_missing)
    end

    function handle_missing_ticker(
        conn::DuckDBConnection,
        ticker_info::DataFrameRow,
        api_key::String,
        missing_tickers::Vector{String},
        updated_tickers::Vector{String}
    )
        symbol = ticker_info.ticker
        push!(missing_tickers, symbol)
        @info "Adding missing ticker: $symbol"
        try
            ticker_data = get_ticker_data(ticker_info; api_key=api_key)
            if !isempty(ticker_data)
                Operations.upsert_stock_data(conn, ticker_data, symbol)
                push!(updated_tickers, symbol)
            else
                @warn "No data retrieved for $symbol"
            end
        catch e
            @warn "Failed to add historical data for $symbol: $e"
        end
    end

    function log_update_results(missing_tickers::Vector{String}, updated_tickers::Vector{String}, error_tickers::Vector{String}, add_missing::Bool)
        if !isempty(missing_tickers)
            if add_missing
                @info "Attempted to add $(length(missing_tickers)) missing tickers to historical_data"
            else
                @warn "The following tickers are not in historical_data: $missing_tickers"
            end
        end

        if !isempty(error_tickers)
            @warn "The following tickers encountered errors during processing: $error_tickers"
        end

        @info "Historical data update completed" updated_count=length(updated_tickers) missing_count=length(missing_tickers) error_count=length(error_tickers)
    end

    function _empty_historical_collection_result()::HistoricalCollectionResult
        return HistoricalCollectionResult(
            String[],
            String[],
            String[],
            String[],
            String[],
            SyncFailure[],
            0,
        )
    end

    function _collect_split_historical(
        conn::DuckDBConnection,
        split_tickers::DataFrame,
        tickers::DataFrame,
        api_key::String;
        fetcher = get_ticker_data,
    )::HistoricalCollectionResult
        nrow(split_tickers) == 0 && return _empty_historical_collection_result()

        ticker_lookup = build_ticker_row_lookup(tickers)
        refresh_rows = tickers[1:0, :]
        attempted = String[]
        missing_ticker_info = String[]
        missing_failures = SyncFailure[]

        for row in eachrow(split_tickers)
            symbol = String(row.ticker)
            push!(attempted, symbol)
            ticker_info = get(ticker_lookup, symbol, nothing)
            if isnothing(ticker_info)
                push!(missing_ticker_info, symbol)
                push!(
                    missing_failures,
                    _sync_failure(
                        symbol,
                        :normalize,
                        ErrorException("No ticker info found for $symbol");
                        retryable=false,
                    ),
                )
                continue
            end
            push!(refresh_rows, ticker_info)
        end

        collected = collect_historical(
            refresh_rows,
            api_key;
            latest_dates=Dict{String,Date}(),
            fetcher,
            writer=(ticker, frame) -> Operations.upsert_stock_data(conn, frame, ticker),
            continue_on_error=true,
            strict=false,
        )
        updated = Set(collected.updated)
        unchanged = Set(collected.unchanged)
        unavailable = Set(collected.unavailable)
        failed = Set(vcat(collected.failed, missing_ticker_info))
        failure_by_ticker = Dict(
            failure.entity => failure
            for failure in vcat(collected.failures, missing_failures)
        )
        ordered_failures = SyncFailure[
            failure_by_ticker[ticker]
            for ticker in attempted
            if haskey(failure_by_ticker, ticker)
        ]

        return HistoricalCollectionResult(
            attempted,
            [ticker for ticker in attempted if ticker in updated],
            [ticker for ticker in attempted if ticker in unchanged],
            [ticker for ticker in attempted if ticker in unavailable],
            [ticker for ticker in attempted if ticker in failed],
            ordered_failures,
            collected.written_rows,
        )
    end

    """
        update_split_ticker(conn::DuckDBConnection, tickers::DataFrame, api_key::String)

    Recollect complete history for split tickers and return a structured result.
    This deprecated compatibility wrapper accepts `max_concurrent` for source
    compatibility; collection is isolated sequentially through
    `collect_historical` so one unavailable ticker cannot abort later tickers.
    """
    function update_split_ticker(
        conn::DuckDBConnection,
        tickers::DataFrame, # all tickers is best
        api_key::String = get_api_key();
        max_concurrent::Int = 4,
    )::HistoricalCollectionResult
        if nrow(tickers) == 0
            @info "No tickers to process for split updates"
            return _empty_historical_collection_result()
        end

        end_date = maximum(skipmissing(tickers.end_date))
        split_tickers = get_split_refresh_targets(conn, end_date)
        if nrow(split_tickers) == 0
            @info "No split tickers found for refresh" end_date
            return _empty_historical_collection_result()
        end

        result = _collect_split_historical(conn, split_tickers, tickers, api_key)
        @info(
            "Split ticker refresh completed",
            attempted_count=length(result.attempted),
            updated_count=length(result.updated),
            unchanged_count=length(result.unchanged),
            unavailable_count=length(result.unavailable),
            failed_count=length(result.failed),
            written_rows=result.written_rows,
        )
        return result
    end

    """
        add_historical_data(conn::DuckDBConnection, ticker::String, api_key::String)

    Add historical data for a single ticker.
    """
    function add_historical_data(
        conn::DuckDBConnection,
        ticker::String,
        api_key::String = get_api_key()
    )
        # Look up ticker info from the database to get a DataFrameRow for get_ticker_data
        ticker_df = DBInterface.execute(conn, """
            SELECT ticker, exchange, assettype as asset_type,
                   startdate as start_date, enddate as end_date
            FROM us_tickers_filtered
            WHERE ticker = ?
        """, [ticker]) |> DataFrame

        if isempty(ticker_df)
            @warn "Ticker $ticker not found in us_tickers_filtered"
            return
        end

        ticker_info = ticker_df[1, :]
        data = get_ticker_data(ticker_info; api_key=api_key)
        if isempty(data)
            @warn "No data retrieved for $ticker"
            return
        end
        Operations.upsert_stock_data(conn, data, ticker)
        @info "Added historical data for $ticker"
    end
