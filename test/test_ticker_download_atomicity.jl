using Test
using HTTP
using ZipFile
using QuansiftMarketData

function _write_ticker_zip(path::String, entry_name::String, csv_content::String)
    writer = ZipFile.Writer(path)
    try
        entry = ZipFile.addfile(writer, entry_name)
        write(entry, csv_content)
    finally
        close(writer)
    end
end

@testset "Ticker download atomically replaces validated destinations" begin
    mktempdir() do directory
        zip_path = joinpath(directory, "supported_tickers.zip")
        csv_path = joinpath(directory, "supported_tickers.csv")
        write(zip_path, "old-zip")
        write(csv_path, "old-csv")
        downloaded_paths = String[]
        owned_directory_mode = Ref{UInt}()
        csv_content = "ticker,exchange,assetType,endDate\nAAPL,NASDAQ,Stock,2026-07-31\n"
        downloader = function (_, temporary_path)
            push!(downloaded_paths, temporary_path)
            owned_directory_mode[] = stat(dirname(temporary_path)).mode
            _write_ticker_zip(temporary_path, basename(csv_path), csv_content)
            return temporary_path
        end

        @test isnothing(download_latest_tickers(
            "offline://tickers",
            zip_path,
            csv_path;
            downloader,
        ))
        @test read(csv_path, String) == csv_content
        @test only(downloaded_paths) != zip_path
        owned_directory = dirname(only(downloaded_paths))
        @test dirname(owned_directory) == directory
        @test basename(owned_directory) != basename(directory)
        @test owned_directory_mode[] & 0o077 == 0
        @test !ispath(owned_directory)
        @test sort(readdir(directory)) == sort([basename(zip_path), basename(csv_path)])
    end
end

@testset "Ticker publication replaces destination symlinks, not their targets" begin
    mktempdir() do directory
        victim = joinpath(directory, "victim.csv")
        write(victim, "victim-sentinel")
        zip_path = joinpath(directory, "supported_tickers.zip")
        csv_path = joinpath(directory, "supported_tickers.csv")
        symlink(victim, csv_path)
        csv_content = "ticker,exchange,assetType,endDate\nAAPL,NASDAQ,Stock,2026-07-31\n"
        downloader = function (_, temporary_path)
            _write_ticker_zip(temporary_path, basename(csv_path), csv_content)
            return temporary_path
        end

        @test isnothing(download_latest_tickers(
            "offline://tickers",
            zip_path,
            csv_path;
            downloader,
        ))
        @test !islink(csv_path)
        @test read(csv_path, String) == csv_content
        @test read(victim, String) == "victim-sentinel"
    end
end

@testset "Ticker download preserves destinations on fetch or validation failure" begin
    for failure in (:fetch, :missing_csv, :invalid_schema)
        mktempdir() do directory
            zip_path = joinpath(directory, "supported_tickers.zip")
            csv_path = joinpath(directory, "supported_tickers.csv")
            write(zip_path, "old-zip")
            write(csv_path, "old-csv")
            downloader = function (_, temporary_path)
                if failure == :fetch
                    write(temporary_path, "partial-download")
                    error("injected fetch failure")
                elseif failure == :missing_csv
                    _write_ticker_zip(temporary_path, "other.csv", "ticker\nAAPL\n")
                else
                    _write_ticker_zip(
                        temporary_path,
                        basename(csv_path),
                        "ticker,exchange\nAAPL,NASDAQ\n",
                    )
                end
                return temporary_path
            end

            @test_throws Exception download_latest_tickers(
                "offline://tickers",
                zip_path,
                csv_path;
                downloader,
            )
            @test read(zip_path, String) == "old-zip"
            @test read(csv_path, String) == "old-csv"
            @test sort(readdir(directory)) == sort([basename(zip_path), basename(csv_path)])
        end
    end
end

@testset "Ticker download rejects an empty validated ticker universe" begin
    mktempdir() do directory
        zip_path = joinpath(directory, "supported_tickers.zip")
        csv_path = joinpath(directory, "supported_tickers.csv")
        zip_sentinel = UInt8[0x00, 0x7f, 0xff]
        csv_sentinel = UInt8[0xff, 0x0a, 0x00]
        write(zip_path, zip_sentinel)
        write(csv_path, csv_sentinel)
        downloader = function (_, temporary_path)
            _write_ticker_zip(
                temporary_path,
                basename(csv_path),
                "ticker,exchange,assetType,endDate\n",
            )
            return temporary_path
        end

        @test_throws ErrorException("Downloaded ticker CSV contains no rows") download_latest_tickers(
            "offline://tickers",
            zip_path,
            csv_path;
            downloader,
        )
        @test read(zip_path) == zip_sentinel
        @test read(csv_path) == csv_sentinel
        @test sort(readdir(directory)) == sort([basename(zip_path), basename(csv_path)])
    end
end

@testset "Ticker download bounds archive and decompressed CSV bytes" begin
    for oversized in (:zip, :csv)
        mktempdir() do directory
            zip_path = joinpath(directory, "supported_tickers.zip")
            csv_path = joinpath(directory, "supported_tickers.csv")
            write(zip_path, "old-zip")
            write(csv_path, "old-csv")
            csv_content = "ticker,exchange,assetType,endDate\n" *
                          "AAPL,NASDAQ,Stock,2026-07-31\n"
            downloader = function (_, temporary_path)
                _write_ticker_zip(
                    temporary_path,
                    basename(csv_path),
                    csv_content,
                )
                return temporary_path
            end

            caught = try
                download_latest_tickers(
                    "offline://tickers",
                    zip_path,
                    csv_path;
                    downloader,
                    max_zip_bytes = oversized == :zip ? 8 : 1_024,
                    max_csv_bytes = oversized == :csv ? 8 : 1_024,
                )
                nothing
            catch error
                error
            end

            @test caught isa Exception
            @test occursin(
                oversized == :zip ? "ZIP archive exceeds" : "CSV entry exceeds",
                sprint(showerror, caught),
            )
            @test read(zip_path, String) == "old-zip"
            @test read(csv_path, String) == "old-csv"
            @test sort(readdir(directory)) ==
                  sort([basename(zip_path), basename(csv_path)])
        end
    end
end

@testset "Default ticker downloader enforces the archive cap while reading" begin
    requests = Ref(0)
    listener = HTTP.Servers.Listener("127.0.0.1", 0; listenany=true)
    server = HTTP.serve!(listener; verbose=-1) do _
        requests[] += 1
        return HTTP.Response(200, fill(UInt8(0x41), 64))
    end
    try
        mktempdir() do directory
            zip_path = joinpath(directory, "supported_tickers.zip")
            csv_path = joinpath(directory, "supported_tickers.csv")
            write(zip_path, "old-zip")
            write(csv_path, "old-csv")
            url = "http://127.0.0.1:$(HTTP.Servers.port(server))/tickers"

            caught = try
                download_latest_tickers(
                    url,
                    zip_path,
                    csv_path;
                    max_zip_bytes = 16,
                )
                nothing
            catch error
                error
            end

            @test caught isa Exception
            @test occursin("ZIP archive exceeds", sprint(showerror, caught))
            @test requests[] == 1
            @test read(zip_path, String) == "old-zip"
            @test read(csv_path, String) == "old-csv"
        end
    finally
        close(server)
    end
end

@testset "Default ticker downloader has a finite inactivity timeout" begin
    observed_readtimeout = Ref{Union{Nothing,Int}}(nothing)
    layer = _handler -> function (_request; kwargs...)
        observed_readtimeout[] = get(kwargs, :readtimeout, nothing)
        throw(HTTP.TimeoutError(something(observed_readtimeout[], 0)))
    end

    HTTP.pushlayer!(layer)
    try
        mktempdir() do directory
            zip_path = joinpath(directory, "supported_tickers.zip")
            csv_path = joinpath(directory, "supported_tickers.csv")
            write(zip_path, "old-zip")
            write(csv_path, "old-csv")

            caught = try
                download_latest_tickers(
                    "http://example.invalid/tickers",
                    zip_path,
                    csv_path;
                    readtimeout=7,
                )
                nothing
            catch error
                error
            end

            @test caught isa Exception
            @test observed_readtimeout[] == 7
            @test read(zip_path, String) == "old-zip"
            @test read(csv_path, String) == "old-csv"
            @test sort(readdir(directory)) ==
                  sort([basename(zip_path), basename(csv_path)])
        end
    finally
        HTTP.poplayer!()
    end

    @test_throws ArgumentError download_latest_tickers(
        "http://example.invalid/tickers",
        tempname(),
        tempname();
        readtimeout=0,
    )
end

@testset "Ticker byte limits reject invalid values before I/O" begin
    paths = (tempname(), tempname())
    @test_throws ArgumentError("max_zip_bytes must be positive") download_latest_tickers(
        "http://example.invalid/tickers",
        paths...;
        max_zip_bytes=0,
    )
    @test_throws ArgumentError("max_csv_bytes must be positive") download_latest_tickers(
        "http://example.invalid/tickers",
        paths...;
        max_csv_bytes=0,
    )
end

@testset "Bounded ZIP and CSV copies stop at the first excess byte" begin
    limit = 8
    for label in ("ZIP archive", "CSV entry")
        source = IOBuffer(fill(UInt8(0x41), limit + 16))
        destination = IOBuffer()

        @test_throws ErrorException("$label exceeds $limit bytes") QuansiftMarketData.Sync._copy_with_byte_limit!(
            destination,
            source,
            limit,
            label,
        )
        @test position(source) == limit + 1
        @test position(destination) == 0
    end
end
