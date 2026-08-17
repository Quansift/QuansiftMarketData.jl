using ..DB.Core: DuckDBConnection, validate_identifier, validate_file_path, validate_sql_value
using ..DB.Operations
using ..API: get_ticker_data, get_api_key
using ..QuansiftMarketData: HistoricalCollectionResult, SyncFailure, _finish_collection, _sync_failure

const _MAX_TICKER_ZIP_BYTES = 128 * 1024 * 1024
const _MAX_TICKER_CSV_BYTES = 512 * 1024 * 1024
const _TICKER_COPY_CHUNK_BYTES = 64 * 1024
const _TICKER_READ_TIMEOUT_SECONDS = 30

function _copy_with_byte_limit!(
    output::IO,
    input::IO,
    max_bytes::Int,
    label::String,
)::Int
    copied = 0
    while !eof(input)
        remaining = max_bytes - copied
        read_bytes = remaining >= _TICKER_COPY_CHUNK_BYTES ?
            _TICKER_COPY_CHUNK_BYTES :
            remaining + 1
        chunk = read(input, read_bytes)
        length(chunk) <= remaining || error("$label exceeds $max_bytes bytes")
        copied += length(chunk)
        write(output, chunk)
    end
    return copied
end

function _download_ticker_zip_bounded(
    url::String,
    path::String,
    max_bytes::Int,
    readtimeout::Int,
)::String
    open(path, "w") do output
        HTTP.open("GET", url; readtimeout) do stream
            response = HTTP.startread(stream)
            content_length = tryparse(
                Int,
                HTTP.header(response, "Content-Length", ""),
            )
            !isnothing(content_length) && content_length > max_bytes &&
                error("ZIP archive exceeds $max_bytes bytes")
            _copy_with_byte_limit!(output, stream, max_bytes, "ZIP archive")
        end
    end
    return path
end

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
        error isa InterruptException && rethrow()
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
        max_zip_bytes::Int = _MAX_TICKER_ZIP_BYTES,
        max_csv_bytes::Int = _MAX_TICKER_CSV_BYTES,
        readtimeout::Int = _TICKER_READ_TIMEOUT_SECONDS,
    )
        max_zip_bytes > 0 || throw(ArgumentError("max_zip_bytes must be positive"))
        max_csv_bytes > 0 || throw(ArgumentError("max_csv_bytes must be positive"))
        readtimeout > 0 || throw(ArgumentError("readtimeout must be positive"))
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
                if downloader === HTTP.download
                    _download_ticker_zip_bounded(
                        url,
                        temporary_zip,
                        max_zip_bytes,
                        readtimeout,
                    )
                else
                    downloader(url, temporary_zip)
                end
                isfile(temporary_zip) && filesize(temporary_zip) > 0 ||
                    error("Ticker download did not produce a non-empty ZIP archive")
                filesize(temporary_zip) <= max_zip_bytes ||
                    error("ZIP archive exceeds $max_zip_bytes bytes")

                found = false
                reader = ZipFile.Reader(temporary_zip)
                try
                    for file in reader.files
                        if basename(file.name) == target_basename
                            file.uncompressedsize <= max_csv_bytes ||
                                error("CSV entry exceeds $max_csv_bytes bytes")
                            open(temporary_csv, "w") do io
                                _copy_with_byte_limit!(
                                    io,
                                    file,
                                    max_csv_bytes,
                                    "CSV entry",
                                )
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
                nrow(parsed) > 0 || error("Downloaded ticker CSV contains no rows")

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
            error isa InterruptException && rethrow()
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
        # A typed error is authoritative: `NoDataError` and a 404/410 status
        # are the security having nothing to give, and any other carried status
        # is a failure — a 503 whose body happens to say "no data returned" is
        # worth retrying, not a recorded absence. Substring matching remains
        # the fallback for errors that carried neither.
        API.is_no_data_error(error) && return true
        error isa API.ApiStatusError && return false
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
            catch error
                error isa InterruptException && rethrow()
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
        catch error
            error isa InterruptException && rethrow()
            throw(ArgumentError("ticker must be convertible to String"))
        end
        isempty(strip(symbol)) && throw(ArgumentError("ticker cannot be empty"))
        return symbol
    end

    function _validate_unique_historical_tickers(tickers::DataFrame)::Nothing
        first_rows = Dict{String,Int}()
        duplicates = String[]
        for (row_index, row) in enumerate(eachrow(tickers))
            symbol = try
                _historical_symbol(row)
            catch error
                error isa InterruptException && rethrow()
                continue
            end
            if haskey(first_rows, symbol)
                push!(duplicates, "$symbol (rows $(first_rows[symbol]) and $row_index)")
            else
                first_rows[symbol] = row_index
            end
        end
        isempty(duplicates) || throw(ArgumentError(
            "duplicate canonical ticker inputs: $(join(duplicates, ", "))",
        ))
        return nothing
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
            catch error
                error isa InterruptException && rethrow()
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
    persisted. Every writer frame carries the call-scoped `fetched_at`,
    including frames recovered by a retry sweep. Strict mode processes every
    ticker and then throws
    `SyncIncompleteError` when one or more fetch, normalization, or write
    operations failed.
    `retry_rounds` (default 0) sweeps tickers whose FETCH failed with a
    retryable classification after the main pass; recovered tickers leave
    `failed` and `failures`. It is opt-in because this entrypoint is
    sink-neutral and reports complete failure records for the caller to act
    on. Normalization failures are deterministic and write failures must not
    be re-driven, so neither is ever swept.
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
        retry_rounds::Int = 0,
        fetched_at::DateTime = Dates.now(Dates.UTC),
    )::HistoricalCollectionResult
        retry_rounds >= 0 ||
            throw(ArgumentError("retry_rounds must be non-negative"))
        _validate_unique_historical_tickers(tickers)
        latest_dates_lookup = _historical_latest_dates(latest_dates)
        attempted = String[]
        updated = String[]
        unchanged = String[]
        unavailable = String[]
        failed = String[]
        failures = SyncFailure[]
        written_rows = 0

        function record_failure!(
            failure::SyncFailure,
            failure_index::Union{Int,Nothing},
        )::Int
            if isnothing(failure_index)
                push!(failed, failure.entity)
                push!(failures, failure)
                return length(failures)
            end
            failures[failure_index] = failure
            return failure_index
        end

        # Tickers whose FETCH failed with a retryable classification, swept
        # after the main pass when `retry_rounds > 0`. Normalization failures
        # are deterministic and write failures must not be re-driven, so
        # neither is ever queued here.
        retry_queue = Tuple{Int,DataFrameRow,Int}[]
        recovered_failure_indices = Set{Int}()

        function record_recovery!(failure_index::Union{Int,Nothing})
            !isnothing(failure_index) && push!(recovered_failure_indices, failure_index)
            return nothing
        end

        function process_row!(
            row_index,
            row,
            failure_index::Union{Int,Nothing},
        )
            sweeping = !isnothing(failure_index)
            symbol = _historical_row_label(row_index)
            try
                symbol = _historical_symbol(row)
            catch error
                error isa InterruptException && rethrow()
                sweeping || push!(attempted, symbol)
                record_failure!(
                    _sync_failure(symbol, :normalize, error; retryable=false),
                    failure_index,
                )
                (!continue_on_error && !strict) && rethrow()
                return nothing
            end
            sweeping || push!(attempted, symbol)

            ticker_end_date = try
                _historical_date(
                    row,
                    (:end_date, :endDate),
                    "end_date",
                    Date(now()) - Day(1),
                )
            catch error
                error isa InterruptException && rethrow()
                record_failure!(
                    _sync_failure(symbol, :normalize, error; retryable=false),
                    failure_index,
                )
                (!continue_on_error && !strict) && rethrow()
                return nothing
            end
            latest_date = get(latest_dates_lookup, symbol, nothing)
            if !isnothing(latest_date) && latest_date >= ticker_end_date
                push!(unchanged, symbol)
                record_recovery!(failure_index)
                return nothing
            elseif isnothing(latest_date) && !add_missing
                push!(unavailable, symbol)
                record_recovery!(failure_index)
                return nothing
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
                    error isa InterruptException && rethrow()
                    record_failure!(
                        _sync_failure(symbol, :normalize, error; retryable=false),
                        failure_index,
                    )
                    (!continue_on_error && !strict) && rethrow()
                    return nothing
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
                    record_recovery!(failure_index)
                    return nothing
                end
                failure = _sync_failure(symbol, :fetch, error)
                failure_index = record_failure!(failure, failure_index)
                failure.retryable && push!(retry_queue, (row_index, row, failure_index))
                (!continue_on_error && !strict) && rethrow()
                @warn(
                    "Historical fetch failed for $symbol; continuing",
                    failure_stage=failure.stage,
                    failure_message=failure.message,
                    retryable=failure.retryable,
                )
                return nothing
            end

            frame = try
                normalize_eod_prices(
                    payload;
                    start_date,
                    end_date = ticker_end_date,
                )
            catch error
                error isa InterruptException && rethrow()
                record_failure!(
                    _sync_failure(symbol, :normalize, error; retryable=false),
                    failure_index,
                )
                (!continue_on_error && !strict) && rethrow()
                return nothing
            end
            frame[!, :fetched_at] = fill(fetched_at, nrow(frame))
            if nrow(frame) == 0
                push!(isnothing(latest_date) ? unavailable : unchanged, symbol)
                record_recovery!(failure_index)
                return nothing
            end

            if !isnothing(writer)
                try
                    rows = writer(symbol, frame)
                    (rows isa Integer && !(rows isa Bool)) ||
                        throw(ArgumentError("writer must return an integer row count"))
                    rows >= 0 ||
                        throw(ArgumentError("writer row count must be non-negative"))
                    rows <= nrow(frame) || throw(ArgumentError(
                        "writer row count must not exceed frame row count",
                    ))
                    written_rows += rows
                catch error
                    error isa InterruptException && rethrow()
                    record_failure!(
                        _sync_failure(symbol, :write, error; retryable=false),
                        failure_index,
                    )
                    (!continue_on_error && !strict) && rethrow()
                    return nothing
                end
            end
            push!(updated, symbol)
            record_recovery!(failure_index)
            return nothing
        end

        for (row_index, row) in enumerate(eachrow(tickers))
            process_row!(row_index, row, nothing)
        end

        for round in 1:retry_rounds
            isempty(retry_queue) && break
            round_queue = retry_queue
            # Rebinding is what makes a repeat failure land in the NEXT
            # round's queue instead of the one currently being drained.
            retry_queue = Tuple{Int,DataFrameRow,Int}[]
            @info "Sweeping retryable historical fetch failures" round tickers=length(round_queue)
            for (row_index, row, failure_index) in round_queue
                process_row!(row_index, row, failure_index)
            end
        end
        for failure_index in sort!(collect(recovered_failure_indices); rev=true)
            deleteat!(failed, failure_index)
            deleteat!(failures, failure_index)
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
