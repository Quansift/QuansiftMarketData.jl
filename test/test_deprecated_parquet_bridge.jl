using Test
using DataFrames
using DBInterface
using DuckDB
using LibPQ
using TiingoJulia

@testset "deprecated Parquet bridge owns only its temporary artifacts" begin
    postgres_module = TiingoJulia.DB.Postgres

    mktempdir() do caller_directory
        caller_path = joinpath(caller_directory, "caller-owned.parquet")
        caller_contents = "caller-owned sentinel"
        write(caller_path, caller_contents)
        original_entries = readdir(caller_directory)

        owned_path = Ref{String}()
        result = postgres_module.with_owned_parquet_file(caller_path) do temporary_path
            owned_path[] = temporary_path
            @test temporary_path != caller_path
            @test dirname(dirname(temporary_path)) == caller_directory
            write(temporary_path, "library-owned temporary data")
            return :prepared
        end

        @test result == :prepared
        @test read(caller_path, String) == caller_contents
        @test !ispath(owned_path[])
        @test readdir(caller_directory) == original_entries

        failed_owned_path = Ref{String}()
        @test_throws ErrorException postgres_module.with_owned_parquet_file(caller_path) do temporary_path
            failed_owned_path[] = temporary_path
            write(temporary_path, "incomplete library-owned data")
            error("simulated PostgreSQL preparation failure")
        end

        @test read(caller_path, String) == caller_contents
        @test !ispath(failed_owned_path[])
        @test readdir(caller_directory) == original_entries
    end
end

@testset "retained Parquet writer owns a private same-directory temporary path" begin
    parquet_module = TiingoJulia.DB.Parquet

    mktempdir() do directory
        destination = joinpath(directory, "retained.parquet")
        owned_directory = Ref{String}()
        result = parquet_module.write_atomic_parquet(
            destination,
            1,
            ["value"];
            overwrite=false,
        ) do temporary
            owned_directory[] = dirname(temporary)
            @test dirname(owned_directory[]) == directory
            @test stat(owned_directory[]).mode & 0o077 == 0
            write_parquet(DataFrame(value=[1]), temporary)
            return nothing
        end

        @test result.rows == 1
        @test isfile(destination)
        @test !ispath(owned_directory[])
        @test readdir(directory) == [basename(destination)]
    end
end

@testset "retained Parquet overwrite replaces a symlink, not its target" begin
    mktempdir() do directory
        victim = joinpath(directory, "victim.txt")
        destination = joinpath(directory, "retained.parquet")
        write(victim, "victim-sentinel")
        symlink(victim, destination)

        result = write_parquet(DataFrame(value=[1]), destination; overwrite=true)
        @test result.rows == 1
        @test !islink(destination)
        @test read(victim, String) == "victim-sentinel"
    end
end

@testset "deprecated Parquet bridge preserves caller file on transfer failure" begin
    postgres_module = TiingoJulia.DB.Postgres

    mktempdir() do caller_directory
        caller_path = joinpath(caller_directory, "caller-owned.parquet")
        caller_contents = "caller-owned sentinel"
        write(caller_path, caller_contents)

        duckdb_conn = DBInterface.connect(DuckDB.DB)
        pg_conn = LibPQ.Connection(
            "host=127.0.0.1 port=1 dbname=unavailable connect_timeout=1";
            throw_error=false,
        )
        try
            DBInterface.execute(
                duckdb_conn,
                "CREATE TABLE bridge_source (id INTEGER)",
            )
            DBInterface.execute(
                duckdb_conn,
                "INSERT INTO bridge_source VALUES (1)",
            )

            @test_throws Exception postgres_module.export_table_to_postgres_parquet(
                duckdb_conn,
                pg_conn,
                "bridge_source",
                caller_path,
            )

            @test read(caller_path, String) == caller_contents
            @test readdir(caller_directory) == [basename(caller_path)]
        finally
            LibPQ.close(pg_conn)
            DBInterface.close!(duckdb_conn)
        end
    end
end
