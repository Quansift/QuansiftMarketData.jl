using Test

const RELEASE_HYGIENE_SCRIPT = joinpath(
    @__DIR__,
    "..",
    "scripts",
    "ci",
    "validate_release_hygiene.jl",
)
const RELEASE_HYGIENE_SOURCE = read(RELEASE_HYGIENE_SCRIPT, String)
const RELEASE_HYGIENE_GUARDED = occursin(
    "if abspath(PROGRAM_FILE) == abspath(@__FILE__)",
    RELEASE_HYGIENE_SOURCE,
)

@test RELEASE_HYGIENE_GUARDED

if RELEASE_HYGIENE_GUARDED
    include(RELEASE_HYGIENE_SCRIPT)

    function _write_release_fixture(
        directory;
        version = "1.1.0",
        released = false,
        release_date = "2026-08-02",
        unreleased_entry = false,
        compat = "1",
        complete_citation = released,
    )
        write(joinpath(directory, "Project.toml"), """
name = "FixturePackage"
uuid = "11111111-1111-1111-1111-111111111111"
version = "$version"

[deps]
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Example = "11111111-2222-3333-4444-555555555555"
SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"

[compat]
Example = "$compat"
julia = "1.9"
""")
        release_section = released ? """
## [$version] - $release_date

### Added

- Production readiness controls.
""" : """
## [1.0.0] - 2026-02-13

### Added

- Initial release.
"""
        release_link = released ? "\n[$version]: https://github.com/Quansift/Tiingo.jl/compare/v1.0.0...v$version" : ""
        unreleased_base = released ? version : "1.0.0"
        unreleased_body = unreleased_entry ? "\n### Added\n\n- Not yet released.\n" : ""
        write(joinpath(directory, "CHANGELOG.md"), """
# Changelog

## [Unreleased]
$unreleased_body
$release_section
[unreleased]: https://github.com/Quansift/Tiingo.jl/compare/v$unreleased_base...HEAD$release_link
[1.0.0]: https://github.com/Quansift/Tiingo.jl/releases/tag/v1.0.0
""")
        release_citation = complete_citation ? """
version: $version
date-released: $release_date
""" : ""
        write(joinpath(directory, "CITATION.cff"), """
cff-version: 1.2.0
title: FixturePackage.jl
message: Please cite this software.
type: software
repository-code: https://github.com/Quansift/Tiingo.jl
license: MIT
$release_citation
authors:
  - given-names: Test
    family-names: Maintainer
""")
        config = """
[api]
base_url = "https://api.tiingo.com"
tickers_url = "https://apimedia.tiingo.com/docs/tiingo/daily/supported_tickers.zip"
max_retries = 3
retry_delay = 1

[files]
env_file = ".env"
zip_file = "tickers.zip"
csv_file = "tickers.csv"

[environment]
api_key_name = "TIINGO_API_KEY"

[filtering]
supported_exchanges = ["NYSE"]
supported_asset_types = ["Stock"]
"""
        write(joinpath(directory, "config.toml"), config)
        write(joinpath(directory, "config.example.toml"), config)
        return directory
    end

    const VALID_MIGRATION_METADATA = (
        schema_version = 1,
        versions = [1],
        checksums_valid = true,
    )
    const RELEASE_SHA = repeat("a", 40)

    @testset "Release modes are explicit and stable-semver-only" begin
        @test release_hygiene_mode(Dict{String,String}(); head_sha = RELEASE_SHA) ==
              (:development, nothing)
        @test release_hygiene_mode(
            Dict(
                "TIINGO_RELEASE_VERSION" => "1.1.0",
                "TIINGO_RELEASE_REF" => RELEASE_SHA,
            );
            head_sha = RELEASE_SHA,
        ) == (:preflight, v"1.1.0")
        @test release_hygiene_mode(
            Dict("TIINGO_RELEASE_TAG" => "v1.1.0");
            head_sha = RELEASE_SHA,
        ) == (:post_tag, v"1.1.0")

        @test is_stable_release_tag("v1.1.0")
        @test is_stable_release_version("1.1.0")
        @test !is_stable_release_tag("1.1.0")
        @test !is_stable_release_tag("v1.1")
        @test !is_stable_release_tag("v1.1.0-rc1")
        @test !is_stable_release_tag("nightly")
        @test !is_stable_release_version("v1.1.0")
        @test !is_stable_release_version("1.1")
        @test !is_stable_release_version("1.1.0-rc1")
        @test_throws ReleaseHygieneError release_hygiene_mode(
            Dict("TIINGO_RELEASE_TAG" => "nightly");
            head_sha = RELEASE_SHA,
        )
        @test_throws ReleaseHygieneError release_hygiene_mode(
            Dict(
                "TIINGO_RELEASE_VERSION" => "1.1.0",
                "TIINGO_RELEASE_REF" => repeat("b", 40),
            );
            head_sha = RELEASE_SHA,
        )
        for invalid_environment in (
            Dict("TIINGO_RELEASE_VERSION" => "1.1.0"),
            Dict("TIINGO_RELEASE_REF" => RELEASE_SHA),
            Dict(
                "TIINGO_RELEASE_TAG" => "v1.1.0",
                "TIINGO_RELEASE_REF" => RELEASE_SHA,
            ),
            Dict(
                "TIINGO_RELEASE_VERSION" => "1.1.0",
                "TIINGO_RELEASE_TAG" => "v1.1.0",
            ),
        )
            @test_throws ReleaseHygieneError release_hygiene_mode(
                invalid_environment;
                head_sha = RELEASE_SHA,
            )
        end
        @test_throws ReleaseHygieneError release_hygiene_mode(
            Dict(
                "TIINGO_RELEASE_VERSION" => "1.1",
                "TIINGO_RELEASE_REF" => RELEASE_SHA,
            );
            head_sha = RELEASE_SHA,
        )
        @test_throws ReleaseHygieneError release_hygiene_mode(
            Dict(
                "TIINGO_RELEASE_VERSION" => "1.1.0",
                "TIINGO_RELEASE_TAG" => "v1.1.0",
                "TIINGO_RELEASE_REF" => RELEASE_SHA,
            );
            head_sha = RELEASE_SHA,
        )
    end

    @testset "Development CFF fields fail closed" begin
        for field in ("cff-version", "message", "type")
            mktempdir() do directory
                _write_release_fixture(directory)
                citation_path = joinpath(directory, "CITATION.cff")
                citation = read(citation_path, String)
                pattern = field == "message" ? r"(?m)^message:.*\n" :
                          Regex("(?m)^" * field * ":.*\\n")
                write(citation_path, replace(citation, pattern => ""))
                @test_throws ReleaseHygieneError validate_release_hygiene(
                    directory;
                    environ = Dict{String,String}(),
                    head_sha = RELEASE_SHA,
                    tracked_files = String[],
                    migration_metadata = VALID_MIGRATION_METADATA,
                )
            end
        end

        mktempdir() do directory
            _write_release_fixture(directory)
            citation_path = joinpath(directory, "CITATION.cff")
            citation = replace(read(citation_path, String), "type: software" => "type: dataset")
            write(citation_path, citation)
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict{String,String}(),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
        end

        for (field, original) in (
            ("title", "FixturePackage.jl"),
            ("message", "Please cite this software."),
            ("repository-code", "https://github.com/Quansift/Tiingo.jl"),
            ("license", "MIT"),
        ), empty_value in ("\"\"", "\"   \"", "''", "'   '")
            mktempdir() do directory
                _write_release_fixture(directory)
                citation_path = joinpath(directory, "CITATION.cff")
                citation = read(citation_path, String)
                write(
                    citation_path,
                    replace(citation, "$field: $original" => "$field: $empty_value"),
                )
                @test_throws ReleaseHygieneError validate_release_hygiene(
                    directory;
                    environ = Dict{String,String}(),
                    head_sha = RELEASE_SHA,
                    tracked_files = String[],
                    migration_metadata = VALID_MIGRATION_METADATA,
                )
            end
        end

        for empty_value in ("\"\"", "\"   \"", "''", "'   '")
            mktempdir() do directory
                _write_release_fixture(directory)
                citation_path = joinpath(directory, "CITATION.cff")
                citation = read(citation_path, String)
                citation = replace(citation, "given-names: Test" => "given-names: $empty_value")
                citation = replace(
                    citation,
                    "family-names: Maintainer" => "family-names: $empty_value",
                )
                write(citation_path, citation)
                @test_throws ReleaseHygieneError validate_release_hygiene(
                    directory;
                    environ = Dict{String,String}(),
                    head_sha = RELEASE_SHA,
                    tracked_files = String[],
                    migration_metadata = VALID_MIGRATION_METADATA,
                )
            end
        end
    end

    @testset "Development validation is hermetic" begin
        mktempdir() do directory
            _write_release_fixture(directory)
            result = validate_release_hygiene(
                directory;
                environ = Dict{String,String}(),
                head_sha = RELEASE_SHA,
                tracked_files = [".env.example", "Project.toml"],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
            @test result.mode == :development
            @test result.version == v"1.1.0"
        end
    end

    @testset "Strict preflight validates release metadata before a tag" begin
        mktempdir() do directory
            _write_release_fixture(directory; released = true)
            result = validate_release_hygiene(
                directory;
                environ = Dict(
                    "TIINGO_RELEASE_VERSION" => "1.1.0",
                    "TIINGO_RELEASE_REF" => RELEASE_SHA,
                ),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
            @test result.mode == :preflight
            @test result.version == v"1.1.0"
        end

        mktempdir() do directory
            _write_release_fixture(
                directory;
                released = true,
                unreleased_entry = true,
            )
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict(
                    "TIINGO_RELEASE_VERSION" => "1.1.0",
                    "TIINGO_RELEASE_REF" => RELEASE_SHA,
                ),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
        end


        mktempdir() do directory
            _write_release_fixture(
                directory;
                released = true,
                release_date = "2026-99-99",
            )
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict(
                    "TIINGO_RELEASE_VERSION" => "1.1.0",
                    "TIINGO_RELEASE_REF" => RELEASE_SHA,
                ),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
        end

        for unreleased_content in ("* Still pending.", "Still pending.")
            mktempdir() do directory
                _write_release_fixture(directory; released = true)
                changelog_path = joinpath(directory, "CHANGELOG.md")
                changelog = read(changelog_path, String)
                write(
                    changelog_path,
                    replace(
                        changelog,
                        "## [Unreleased]\n" =>
                            "## [Unreleased]\n\n$unreleased_content\n",
                    ),
                )
                @test_throws ReleaseHygieneError validate_release_hygiene(
                    directory;
                    environ = Dict(
                        "TIINGO_RELEASE_VERSION" => "1.1.0",
                        "TIINGO_RELEASE_REF" => RELEASE_SHA,
                    ),
                    head_sha = RELEASE_SHA,
                    tracked_files = String[],
                    migration_metadata = VALID_MIGRATION_METADATA,
                )
            end
        end
    end

    @testset "Post-tag verification requires matching stable metadata" begin
        mktempdir() do directory
            _write_release_fixture(directory; released = true)
            result = validate_release_hygiene(
                directory;
                environ = Dict("TIINGO_RELEASE_TAG" => "v1.1.0"),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
            @test result.mode == :post_tag
            @test result.version == v"1.1.0"
        end
    end

    @testset "Compatibility migration and secret checks fail closed" begin
        mktempdir() do directory
            _write_release_fixture(directory; compat = ">=3")
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict{String,String}(),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
        end
        mktempdir() do directory
            _write_release_fixture(directory)
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict{String,String}(),
                head_sha = RELEASE_SHA,
                tracked_files = ["config/.env.production"],
                migration_metadata = VALID_MIGRATION_METADATA,
            )
            @test_throws ReleaseHygieneError validate_release_hygiene(
                directory;
                environ = Dict{String,String}(),
                head_sha = RELEASE_SHA,
                tracked_files = String[],
                migration_metadata = (
                    schema_version = 2,
                    versions = [1],
                    checksums_valid = true,
                ),
            )
        end
    end

    @testset "Release preflight is manual hermetic and exact-ref-only" begin
        preflight_path = joinpath(
            @__DIR__,
            "..",
            ".github",
            "workflows",
            "release-preflight.yml",
        )
        @test isfile(preflight_path)
        if isfile(preflight_path)
            preflight = read(preflight_path, String)
            @test occursin("workflow_dispatch:", preflight)
            @test occursin("release_version:", preflight)
            @test occursin("release_ref:", preflight)
            @test occursin("TIINGO_RELEASE_VERSION", preflight)
            @test occursin("TIINGO_RELEASE_REF", preflight)
            @test occursin("origin/main", preflight)
            @test occursin("postgres:17", preflight)
            @test occursin("DOCS_DEPLOY: \"false\"", preflight)
            @test occursin("benchmark/run.jl micro", preflight)
            @test occursin("docker build", preflight)
            @test occursin("attest-release:", preflight)
            @test occursin("statuses: write", preflight)
            @test occursin("tiingo/release-preflight/", preflight)
            @test occursin(
                "run-name: Release preflight v\${{ inputs.release_version }} @ \${{ inputs.release_ref }}",
                preflight,
            )
            @test occursin("actions/runs/\${GITHUB_RUN_ID}", preflight)
            attestation_position = findfirst("attest-release:", preflight)
            @test !isnothing(attestation_position)
            if !isnothing(attestation_position)
                attestation = preflight[first(attestation_position):end]
                @test all(
                    gate -> occursin("- $gate", attestation),
                    (
                        "hermetic",
                        "postgres-integration",
                        "docs-and-links",
                        "benchmark-smoke",
                        "image-build",
                    ),
                )
            end
            @test !occursin("TIINGO_API_KEY", preflight)
            @test !occursin("live_canary", preflight)
            @test !occursin("schedule:", preflight)
            @test !occursin("pull_request:", preflight)
            @test !occursin(r"(?m)^    release:\s*$", preflight)
        end
    end

    @testset "Release workflows pin actions and gate privileged tag jobs" begin
        workflow_directory = joinpath(@__DIR__, "..", ".github", "workflows")
        owned_workflows = (
            "CI.yml",
            "Docs.yml",
            "Lint.yml",
            "TagBot.yml",
            "docker-publish.yml",
            "live-canary.yml",
            "release-preflight.yml",
        )
        action_line = r"(?m)^\s*-?\s*uses:\s*[^\s@]+@([^\s#]+)(?:\s+#\s+\S+)?\s*$"
        for filename in owned_workflows
            source = read(joinpath(workflow_directory, filename), String)
            references = [matched.captures[1] for matched in eachmatch(action_line, source)]
            @test !isempty(references)
            @test all(reference -> !isnothing(match(r"^[0-9a-f]{40}$", reference)), references)
            @test all(
                line -> occursin(r"@[0-9a-f]{40}\s+#\s+\S+\s*$", line),
                filter(
                    line -> occursin(r"^\s*-?\s*uses:\s", line),
                    split(source, '\n'),
                ),
            )
        end

        for filename in ("Docs.yml", "docker-publish.yml")
            source = read(joinpath(workflow_directory, filename), String)
            @test occursin("git rev-parse 'HEAD^{commit}'", source)
            @test occursin("/statuses?per_page=100", source)
            @test occursin("tiingo/release-preflight/", source)
            @test occursin("actions: read", source)
            @test occursin("contents: read", source)
            @test occursin("statuses: read", source)
            @test occursin(".creator.login", source)
            @test occursin("github-actions[bot]", source)
            @test occursin("target_url", source)
            @test occursin("actions/runs/\${run_id}", source)
            @test occursin(
                ".path == \\\".github/workflows/release-preflight.yml@main\\\"",
                source,
            )
            @test occursin(".display_title == \\\"\${expected_title}\\\"", source)
            @test occursin(".head_sha ==", source)
            @test occursin(".event == \\\"workflow_dispatch\\\"", source)
            @test occursin(".status == \\\"completed\\\"", source)
            @test occursin(".conclusion == \\\"success\\\"", source)
            @test occursin("[[ \"\${verified_run_id}\" == \"\${run_id}\" ]]", source)
        end

        ci = read(joinpath(workflow_directory, "CI.yml"), String)
        @test occursin("- \"1.9\"", ci)
        @test occursin("- \"1.12\"", ci)
        @test !occursin("Pkg.instantiate(); Pkg.resolve()", ci)
        @test occursin("VERSION < v\"1.12\"", ci)
        @test occursin("rm(manifest_path)", ci)
        remove_position = findfirst("rm(manifest_path)", ci)
        resolve_position = findfirst(
            "Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()",
            ci,
        )
        build_position = findfirst("julia-actions/julia-buildpkg@", ci)
        @test !isnothing(remove_position)
        @test !isnothing(resolve_position)
        @test !isnothing(build_position)
        if !isnothing(remove_position) &&
           !isnothing(resolve_position) &&
           !isnothing(build_position)
            @test first(remove_position) < first(resolve_position)
            @test first(resolve_position) < first(build_position)
        end

        docs = read(joinpath(workflow_directory, "Docs.yml"), String)
        @test !occursin("statuses: write", docs)
        tagbot = read(joinpath(workflow_directory, "TagBot.yml"), String)
        @test occursin("contents: write", tagbot)
        @test occursin("issues: read", tagbot)
        @test occursin("pull-requests: read", tagbot)
    end
end
