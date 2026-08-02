using Test
using ZipFile
using TiingoJulia

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
