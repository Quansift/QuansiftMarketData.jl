using Test
using DBInterface
using QuansiftMarketData

# `close_duckdb` used to reduce every close failure to a warning. That made a
# failed close invisible: `data_pipeline.jl:1684` closes and immediately prints
# a success line, and `run_tiingo_pipeline.sh` reads the Julia exit code as the
# verdict, so the run reported success either way.
#
# It cannot simply rethrow. Most call sites close inside a `finally`, and
# throwing there would replace the original exception with the cleanup one --
# the failure the operator actually needs would be the one discarded.
#
# So the behaviour depends on whether an exception is already in flight, which
# `current_exceptions()` answers: it is non-empty inside a `finally` reached by
# unwinding and empty in one reached normally.
#
# `DuckDBConnection` is an alias for `DBInterface.Connection` (src/db/core.jl:20),
# so a fake subtype dispatches to the real method without opening a database.
struct FailingCloseConnection <: DBInterface.Connection end

DBInterface.close!(::FailingCloseConnection) = error("injected close failure")

@testset "close_duckdb failure semantics" begin
    @testset "a close failure on a normal path is raised" begin
        @test_throws ErrorException close_duckdb(FailingCloseConnection())
    end

    @testset "a close failure during unwinding does not displace the original" begin
        raised = try
            try
                error("primary failure")
            finally
                close_duckdb(FailingCloseConnection())
            end
            nothing
        catch e
            e
        end

        @test raised isa ErrorException
        @test raised.msg == "primary failure"
    end

    @testset "the displaced close failure is still reported" begin
        @test_logs (:error, r"Error closing DuckDB connection") match_mode = :any begin
            try
                try
                    error("primary failure")
                finally
                    close_duckdb(FailingCloseConnection())
                end
            catch
            end
        end
    end
end
