module Parquet
    using DBInterface
    using DataFrames
    using DuckDB

    using ..Core: validate_identifier, validate_file_path
    using ..Postgres: PostgreSQLConnection
    using ..Postgres: with_attached_postgres
    using ..Schema: quote_postgres_identifier

    const PARQUET_SOURCE_VIEW = "_tiingo_parquet_source"
    const PARQUET_POSTGRES_SNAPSHOT = "_tiingo_postgres_snapshot"
    const SUPPORTED_COMPRESSIONS = Set([:zstd, :snappy, :gzip, :uncompressed])

    struct ParquetWriteResult
        path::String
        rows::Int
        columns::Int
        bytes::Int
    end

    function normalized_parquet_path(path::AbstractString)::String
        raw_path = String(path)
        isempty(raw_path) && throw(ArgumentError("Parquet destination cannot be empty"))
        occursin('\0', raw_path) &&
            throw(ArgumentError("Parquet destination cannot contain a NUL byte"))
        normalized = abspath(expanduser(raw_path))
        validate_file_path(normalized)
        return normalized
    end

    function validated_compression(compression::Symbol)::String
        compression in SUPPORTED_COMPRESSIONS || throw(ArgumentError(
            "Unsupported Parquet compression '$compression'; expected one of $(sort!(collect(SUPPORTED_COMPRESSIONS)))",
        ))
        return uppercase(String(compression))
    end

    function parquet_schema(conn, path::String)::Vector{String}
        schema = DBInterface.execute(
            conn,
            "DESCRIBE SELECT * FROM read_parquet('$path')",
        ) |> DataFrame
        return String.(schema.column_name)
    end

    function parquet_row_count(conn, path::String)::Int
        rows = DBInterface.execute(
            conn,
            "SELECT count(*) AS row_count FROM read_parquet('$path')",
        ) |> DataFrame
        return Int(rows[1, :row_count])
    end

    function publish_parquet_file(
        temporary::String,
        destination::String;
        overwrite::Bool,
    )
        if overwrite
            if (ispath(destination) || islink(destination)) && !isfile(destination)
                throw(ArgumentError(
                    "Parquet destination became a non-file before replacement: $destination",
                ))
            end
            Base.Filesystem.rename(temporary, destination)
            return
        end

        try
            Base.Filesystem.hardlink(temporary, destination)
        catch error
            if ispath(destination) || islink(destination)
                throw(ArgumentError(
                    "Parquet destination already exists: $destination",
                ))
            end
            rethrow(error)
        end
    end

    function write_atomic_parquet(
        write_temporary::Function,
        path::AbstractString,
        expected_rows::Int,
        expected_columns::Vector{String};
        overwrite::Bool,
    )::ParquetWriteResult
        destination = normalized_parquet_path(path)
        if ispath(destination) || islink(destination)
            isfile(destination) || throw(ArgumentError(
                "Parquet destination exists and is not a regular file: $destination",
            ))
            overwrite || throw(ArgumentError(
                "Parquet destination already exists: $destination",
            ))
        end

        mkpath(dirname(destination))
        return mktempdir(
            dirname(destination);
            prefix=".tiingojulia-parquet-",
        ) do temporary_directory
            temporary = joinpath(temporary_directory, basename(destination))
            verification_conn = DBInterface.connect(DuckDB.DB)
            try
                write_temporary(temporary)
                isfile(temporary) || error("Parquet writer did not create: $temporary")

                actual_rows = parquet_row_count(verification_conn, temporary)
                actual_columns = parquet_schema(verification_conn, temporary)
                actual_rows == expected_rows || error(
                    "Parquet row-count verification failed: expected $expected_rows, got $actual_rows",
                )
                actual_columns == expected_columns || error(
                    "Parquet schema verification failed: expected $(expected_columns), got $(actual_columns)",
                )

                publish_parquet_file(temporary, destination; overwrite)
                return ParquetWriteResult(
                    destination,
                    actual_rows,
                    length(actual_columns),
                    filesize(destination),
                )
            finally
                try
                    DBInterface.close!(verification_conn)
                catch
                end
            end
        end
    end

    """
        write_parquet(frame::DataFrame, path::AbstractString;
                      overwrite::Bool=false, compression::Symbol=:zstd)

    Atomically write a DataFrame to a retained local Parquet file. Existing
    destinations are rejected unless `overwrite=true`.
    """
    function write_parquet(
        frame::DataFrame,
        path::AbstractString;
        overwrite::Bool=false,
        compression::Symbol=:zstd,
    )::ParquetWriteResult
        compression_sql = validated_compression(compression)
        expected_columns = names(frame)

        return write_atomic_parquet(
            path,
            nrow(frame),
            expected_columns;
            overwrite,
        ) do temporary
            conn = DBInterface.connect(DuckDB.DB)
            try
                DuckDB.register_data_frame(conn, frame, PARQUET_SOURCE_VIEW)
                DBInterface.execute(
                    conn,
                    """
                    COPY (SELECT * FROM $PARQUET_SOURCE_VIEW)
                    TO '$temporary' (FORMAT PARQUET, COMPRESSION $compression_sql)
                    """,
                )
            finally
                try
                    DuckDB.unregister_data_frame(conn, PARQUET_SOURCE_VIEW)
                catch
                end
                try
                    DBInterface.close!(conn)
                catch
                end
            end
        end
    end

    """
        write_parquet(pg_conn::PostgreSQLConnection, table_name::AbstractString,
                      path::AbstractString;
                      overwrite::Bool=false, compression::Symbol=:zstd)

    Atomically snapshot one PostgreSQL table to a retained local Parquet file
    through an ephemeral in-memory DuckDB PostgreSQL scanner.
    """
    function write_parquet(
        pg_conn::PostgreSQLConnection,
        table_name::AbstractString,
        path::AbstractString;
        overwrite::Bool=false,
        compression::Symbol=:zstd,
    )::ParquetWriteResult
        safe_table = validate_identifier(String(table_name))
        quoted_table = quote_postgres_identifier(lowercase(safe_table))
        qualified_source = "\"postgres_source\".\"public\".$quoted_table"
        compression_sql = validated_compression(compression)
        conn = DBInterface.connect(DuckDB.DB)
        try
            try
                DBInterface.execute(conn, "LOAD postgres")
            catch error
                throw(ErrorException(
                    "DuckDB PostgreSQL extension is not preinstalled. " *
                    "Install it during image or environment setup with " *
                    "`INSTALL postgres`, then retry; runtime downloads are disabled. " *
                    "DuckDB error: $(sprint(showerror, error))",
                ))
            end

            # One PostgreSQL SELECT statement owns one MVCC snapshot. Materialize
            # that scan locally before count/schema/COPY so later verification
            # cannot observe different commits and SELECT-only roles remain valid.
            with_attached_postgres(
                conn,
                pg_conn;
                alias="postgres_source",
                read_only=true,
            ) do
                DBInterface.execute(
                    conn,
                    "CREATE TEMP TABLE $PARQUET_POSTGRES_SNAPSHOT " *
                    "AS SELECT * FROM $qualified_source",
                )
            end

            source_rows = DBInterface.execute(
                conn,
                "SELECT count(*) AS row_count FROM $PARQUET_POSTGRES_SNAPSHOT",
            ) |> DataFrame
            expected_rows = Int(source_rows[1, :row_count])
            source_schema = DBInterface.execute(
                conn,
                "DESCRIBE SELECT * FROM $PARQUET_POSTGRES_SNAPSHOT",
            ) |> DataFrame
            expected_columns = String.(source_schema.column_name)

            return write_atomic_parquet(
                path,
                expected_rows,
                expected_columns;
                overwrite,
            ) do temporary
                DBInterface.execute(
                    conn,
                    """
                    COPY (SELECT * FROM $PARQUET_POSTGRES_SNAPSHOT)
                    TO '$temporary' (FORMAT PARQUET, COMPRESSION $compression_sql)
                    """,
                )
            end
        finally
            try
                DBInterface.close!(conn)
            catch
            end
        end
    end

    export ParquetWriteResult, write_parquet
end
