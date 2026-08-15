using Test
using DataFrames
using Dates
using DBInterface
using DuckDB
using QuansiftMarketData

function _read_parquet_fixture(path::String)::DataFrame
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

@testset "Parquet output is verified, atomic, and preserves schema" begin
    mktempdir() do directory
        destination = joinpath(directory, "nested", "prices.parquet")
        frame = DataFrame(
            ticker = ["AAPL", "SPY"],
            date = [Date(2024, 1, 2), Date(2024, 1, 3)],
            close = Union{Missing,Float64}[100.5, missing],
            volume = Int64[1_000, 2_000],
        )

        result = write_parquet(frame, destination)

        @test result isa ParquetWriteResult
        @test result.path == abspath(destination)
        @test result.rows == 2
        @test result.columns == 4
        @test result.bytes > 0
        @test isfile(destination)

        restored = _read_parquet_fixture(destination)
        @test names(restored) == names(frame)
        @test restored.ticker == frame.ticker
        @test restored.date == frame.date
        @test isequal(restored.close, frame.close)
        @test restored.volume == frame.volume
        @test isfile(destination)
    end
end

@testset "Parquet overwrite is explicit and atomic" begin
    mktempdir() do directory
        destination = joinpath(directory, "prices.parquet")
        original = DataFrame(
            ticker = ["AAPL"],
            date = [Date(2024, 1, 2)],
            close = [100.0],
        )
        replacement = DataFrame(
            ticker = ["SPY"],
            date = [Date(2024, 1, 3)],
            close = [200.0],
        )
        write_parquet(original, destination; compression = :snappy)

        @test_throws ArgumentError write_parquet(replacement, destination)
        unchanged = _read_parquet_fixture(destination)
        @test unchanged.ticker == ["AAPL"]
        @test unchanged.close == [100.0]

        result = write_parquet(
            replacement,
            destination;
            overwrite = true,
            compression = :gzip,
        )
        @test result.rows == 1
        restored = _read_parquet_fixture(destination)
        @test restored.ticker == ["SPY"]
        @test restored.date == [Date(2024, 1, 3)]
        @test restored.close == [200.0]
        @test isempty(filter(name -> occursin(".tmp.", name), readdir(directory)))
    end
end

@testset "Parquet publication failures preserve destinations and clean temporary files" begin
    parquet_module = QuansiftMarketData.DB.Parquet

    mktempdir() do directory
        destination = joinpath(directory, "prices.parquet")
        original = DataFrame(
            ticker = ["AAPL"],
            date = [Date(2024, 1, 2)],
            close = [100.0],
        )
        write_parquet(original, destination)

        injected = try
            parquet_module.write_atomic_parquet(
                destination,
                1,
                ["ticker", "date", "close"];
                overwrite = true,
            ) do temporary
                write(temporary, "incomplete parquet")
                error("injected writer failure")
            end
            nothing
        catch error
            error
        end

        @test injected isa ErrorException
        @test occursin("injected writer failure", sprint(showerror, injected))
        restored = _read_parquet_fixture(destination)
        @test restored.ticker == ["AAPL"]
        @test restored.close == [100.0]
        @test isempty(filter(name -> occursin(".tmp.", name), readdir(directory)))
    end
end

@testset "Parquet no-overwrite publication is race safe" begin
    parquet_module = QuansiftMarketData.DB.Parquet

    mktempdir() do directory
        source = joinpath(directory, "source.parquet")
        destination = joinpath(directory, "prices.parquet")
        frame = DataFrame(
            ticker = ["AAPL"],
            date = [Date(2024, 1, 2)],
            close = [100.0],
        )
        write_parquet(frame, source)

        raced = try
            parquet_module.write_atomic_parquet(
                destination,
                1,
                ["ticker", "date", "close"];
                overwrite = false,
            ) do temporary
                cp(source, temporary)
                write(destination, "concurrent publisher")
            end
            nothing
        catch error
            error
        end

        @test raced isa ArgumentError
        @test read(destination, String) == "concurrent publisher"
        @test isempty(filter(name -> occursin(".tmp.", name), readdir(directory)))
    end
end

@testset "Parquet rejects unsupported compression before writing" begin
    mktempdir() do directory
        destination = joinpath(directory, "invalid.parquet")
        frame = DataFrame(ticker = ["AAPL"])

        @test_throws ArgumentError write_parquet(
            frame,
            destination;
            compression = :brotli,
        )
        @test !ispath(destination)
    end
end
