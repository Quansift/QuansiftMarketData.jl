@testset "Logger mode resolution" begin
    resolve = QuansiftMarketData._resolve_logger_mode

    @testset "recognised modes pass through" begin
        for mode in ("console", "tee", "file", "tee-file", "none")
            @test resolve(mode) == (mode, nothing)
        end
    end

    @testset "case and surrounding whitespace are tolerated" begin
        @test resolve("  TEE-FILE  ") == ("tee-file", nothing)
        @test resolve("Console") == ("console", nothing)
    end

    @testset "an unrecognised value falls back to console and is reported" begin
        # The point of the fix: an unknown value must not silence the package.
        # The rejected value comes back so __init__ can name it in a warning.
        @test resolve("stdout") == ("console", "stdout")
        @test resolve("") == ("console", "")
        @test resolve("nul") == ("console", "nul")
    end

    @testset "silence is reachable only by asking for it" begin
        @test first(resolve("none")) == "none"
        @test first(resolve("journald")) != "none"
    end
end
