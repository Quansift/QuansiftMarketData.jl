#!/usr/bin/env julia

using Dates
using TOML
import Pkg
import Tiingo

struct ReleaseHygieneError <: Exception
    message::String
end

Base.showerror(io::IO, error::ReleaseHygieneError) = print(io, error.message)

_hygiene_fail(message::AbstractString) = throw(ReleaseHygieneError(String(message)))

const STDLIB_UUIDS = Set([
    "ade2ca70-3891-5945-98fb-dc099432e06a", # Dates
    "56ddb016-857b-54e1-b83d-db4d58db5568", # Logging
    "ea8e919c-243c-51af-8825-aaa63cd721ce", # SHA
])

function get_nested(config::AbstractDict, keys::Vector{String})
    current = config
    for (index, key) in enumerate(keys)
        current isa AbstractDict && haskey(current, key) || _hygiene_fail(
            "Missing configuration key: " * join(keys[1:index], "."),
        )
        current = current[key]
    end
    return current
end

function validate_config(path::AbstractString)
    isfile(path) || _hygiene_fail("Required config file is missing: $(basename(path))")
    config = try
        TOML.parsefile(path)
    catch
        _hygiene_fail("Failed to parse configuration: $(basename(path))")
    end

    required_string_keys = [
        ["api", "base_url"],
        ["api", "tickers_url"],
        ["files", "env_file"],
        ["files", "zip_file"],
        ["files", "csv_file"],
        ["environment", "api_key_name"],
    ]
    for key_path in required_string_keys
        value = get_nested(config, key_path)
        value isa String && !isempty(strip(value)) || _hygiene_fail(
            "Expected non-empty string for key: " * join(key_path, "."),
        )
    end
    for key_path in (
        ["filtering", "supported_exchanges"],
        ["filtering", "supported_asset_types"],
    )
        value = get_nested(config, key_path)
        value isa AbstractVector && !isempty(value) || _hygiene_fail(
            "Expected non-empty array for key: " * join(key_path, "."),
        )
    end

    max_retries = get_nested(config, ["api", "max_retries"])
    retry_delay = get_nested(config, ["api", "retry_delay"])
    max_retries isa Integer && max_retries >= 1 || _hygiene_fail(
        "api.max_retries must be an integer >= 1",
    )
    retry_delay isa Integer && retry_delay >= 0 || _hygiene_fail(
        "api.retry_delay must be an integer >= 0",
    )
    return nothing
end

function _tracked_files(root::AbstractString)::Vector{String}
    output = try
        read(`git -C $root ls-files`, String)
    catch
        _hygiene_fail("Unable to list tracked files with git")
    end
    return filter(!isempty, split(chomp(output), '\n'))
end

function validate_tracked_env_files(tracked_files::AbstractVector{<:AbstractString})
    bad_files = String[]
    for file in tracked_files
        is_env_like = occursin(r"(^|/)\.env($|\.)", file)
        is_example = occursin(r"(^|/)\.env(\.[^/]*)?\.example$", file)
        is_env_like && !is_example && push!(bad_files, String(file))
    end
    isempty(bad_files) || _hygiene_fail(
        "Secret env files are tracked in git: " * join(sort!(bad_files), ", "),
    )
    return nothing
end

validate_tracked_env_files(root::AbstractString=pwd()) =
    validate_tracked_env_files(_tracked_files(root))

function _stable_version(value::AbstractString, label::AbstractString)::VersionNumber
    version = try
        VersionNumber(value)
    catch
        _hygiene_fail("$label must be a semantic version")
    end
    isempty(version.prerelease) && isempty(version.build) || _hygiene_fail(
        "$label must be a stable semantic version",
    )
    return version
end

is_stable_release_tag(value::AbstractString)::Bool =
    !isnothing(match(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$", value))

is_stable_release_version(value::AbstractString)::Bool =
    !isnothing(match(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$", value))

function release_hygiene_mode(
    environ::AbstractDict=ENV;
    head_sha::AbstractString,
)
    release_version = strip(get(environ, "TIINGO_RELEASE_VERSION", ""))
    release_ref = strip(get(environ, "TIINGO_RELEASE_REF", ""))
    release_tag = strip(get(environ, "TIINGO_RELEASE_TAG", ""))
    has_version = !isempty(release_version)
    has_ref = !isempty(release_ref)
    has_tag = !isempty(release_tag)

    if !has_version && !has_ref && !has_tag
        return (:development, nothing)
    elseif has_version && has_ref && !has_tag
        is_stable_release_version(release_version) || _hygiene_fail(
            "release version must match stable X.Y.Z syntax",
        )
        isnothing(match(r"^[0-9a-f]{40}$", release_ref)) && _hygiene_fail(
            "TIINGO_RELEASE_REF must be an exact lowercase commit SHA",
        )
        release_ref == head_sha || _hygiene_fail(
            "release ref does not match the checked-out commit",
        )
        return (:preflight, _stable_version(release_version, "release version"))
    elseif has_tag && !has_version && !has_ref
        is_stable_release_tag(release_tag) || _hygiene_fail(
            "release tag must match stable vX.Y.Z syntax",
        )
        return (:post_tag, _stable_version(release_tag[2:end], "release tag"))
    end
    _hygiene_fail(
        "release mode must be development, version plus ref preflight, or tag-only post-tag",
    )
end

function _finite_compat(value)::Bool
    value isa String || return false
    spec = try
        Pkg.Types.semver_spec(value)
    catch
        return false
    end
    isempty(spec.ranges) && return false
    for range in spec.ranges
        range.upper.n == 0 && return false
        lower_major = Int(range.lower.t[1])
        upper_major = Int(range.upper.t[1])
        lower_major == 0 && upper_major > 0 && return false
        upper_major == 0 && range.upper.n == 1 && return false
    end
    return true
end

function validate_project(path::AbstractString)::Tuple{VersionNumber,Dict{String,Any}}
    isfile(path) || _hygiene_fail("Project.toml is missing")
    project = try
        TOML.parsefile(path)
    catch
        _hygiene_fail("Project.toml is invalid")
    end
    for key in ("name", "uuid", "version")
        haskey(project, key) || _hygiene_fail("Project.toml is missing $key")
    end
    version = _stable_version(String(project["version"]), "Project.toml version")
    dependencies = get(project, "deps", Dict{String,Any}())
    compat = get(project, "compat", Dict{String,Any}())
    haskey(compat, "julia") && _finite_compat(compat["julia"]) || _hygiene_fail(
        "Project.toml requires finite julia compat",
    )
    for (name, uuid) in dependencies
        String(uuid) in STDLIB_UUIDS && continue
        haskey(compat, name) && _finite_compat(compat[name]) || _hygiene_fail(
            "Project.toml requires finite compat for $name",
        )
    end
    return (version, project)
end

function _cff_scalar(source::AbstractString, key::AbstractString)
    matched = match(Regex("(?m)^" * key * ":\\s*([^\\n#]+?)\\s*\$"), source)
    return isnothing(matched) ? nothing : strip(matched.captures[1])
end

function _cff_semantic_scalar(value)::Union{Nothing,String}
    isnothing(value) && return nothing
    normalized = strip(String(value))
    if ncodeunits(normalized) >= 2 &&
       ((first(normalized) == '"' && last(normalized) == '"') ||
        (first(normalized) == '\'' && last(normalized) == '\''))
        normalized = strip(normalized[2:(end - 1)])
    end
    return normalized
end

function _cff_text(source::AbstractString, key::AbstractString)::Union{Nothing,String}
    return _cff_semantic_scalar(_cff_scalar(source, key))
end

function _cff_message_present(source::AbstractString)::Bool
    scalar = _cff_text(source, "message")
    isnothing(scalar) && return false
    scalar in ("|", "|-", "|+", ">", ">-", ">+") || return !isempty(scalar)
    block = match(
        r"(?ms)^message:\s*[>|][-+]?\s*\n((?:[ \t]+[^\n]*(?:\n|\z))+)",
        source,
    )
    return !isnothing(block) && any(
        line -> !isempty(strip(line)),
        split(block.captures[1], '\n'),
    )
end

function _cff_author_present(source::AbstractString)::Bool
    occursin(r"(?m)^authors:\s*$", source) || return false
    for matched in eachmatch(
        r"(?m)^\s+(?:-\s+)?(?:given|family)-names:\s*([^\n#]*?)\s*$",
        source,
    )
        value = _cff_semantic_scalar(matched.captures[1])
        !isnothing(value) && !isempty(value) && return true
    end
    return false
end

function validate_citation(
    path::AbstractString;
    release_version::Union{Nothing,VersionNumber}=nothing,
)
    isfile(path) || _hygiene_fail("CITATION.cff is missing")
    source = read(path, String)
    _cff_text(source, "cff-version") == "1.2.0" || _hygiene_fail(
        "CITATION.cff requires cff-version 1.2.0",
    )
    _cff_text(source, "type") == "software" || _hygiene_fail(
        "CITATION.cff type must be software",
    )
    _cff_message_present(source) || _hygiene_fail(
        "CITATION.cff requires a non-empty message",
    )
    for key in ("title", "repository-code", "license")
        value = _cff_text(source, key)
        !isnothing(value) && !isempty(value) || _hygiene_fail(
            "CITATION.cff is missing $key",
        )
    end
    _cff_author_present(source) || _hygiene_fail(
        "CITATION.cff requires at least one non-empty author name",
    )

    if !isnothing(release_version)
        citation_version = _cff_text(source, "version")
        citation_version == string(release_version) || _hygiene_fail(
            "CITATION.cff version does not match the release",
        )
        released = _cff_text(source, "date-released")
        isnothing(released) && _hygiene_fail("CITATION.cff is missing date-released")
        try
            Date(released)
        catch
            _hygiene_fail("CITATION.cff date-released must use YYYY-MM-DD")
        end
    end
    return nothing
end

function _release_heading_date(
    changelog::AbstractString,
    version::AbstractString,
)::Date
    escaped = replace(version, "." => "\\.")
    matched = match(
        Regex("(?m)^## \\[" * escaped * "\\] - ([0-9]{4}-[0-9]{2}-[0-9]{2})\$"),
        changelog,
    )
    isnothing(matched) && _hygiene_fail(
        "CHANGELOG.md is missing the dated $version release section",
    )
    date_text = matched.captures[1]
    released = try
        Date(date_text, dateformat"yyyy-mm-dd")
    catch
        _hygiene_fail("CHANGELOG.md release date must be a real YYYY-MM-DD date")
    end
    string(released) == date_text || _hygiene_fail(
        "CHANGELOG.md release date must use canonical YYYY-MM-DD form",
    )
    return released
end

function _unreleased_is_empty(changelog::AbstractString)::Bool
    without_comments = replace(_unreleased_body(changelog), r"(?s)<!--.*?-->" => "")
    return isempty(strip(without_comments))
end

function _unreleased_body(changelog::AbstractString)::String
    matched = match(r"(?ms)^## \[Unreleased\]\s*(.*?)(?=^## \[|\z)", changelog)
    isnothing(matched) && _hygiene_fail("CHANGELOG.md requires [Unreleased]")
    return matched.captures[1]
end

function validate_changelog(
    path::AbstractString;
    release_version::Union{Nothing,VersionNumber}=nothing,
)
    isfile(path) || _hygiene_fail("CHANGELOG.md is missing")
    source = read(path, String)
    _unreleased_body(source)
    if isnothing(release_version)
        occursin(
            r"(?mi)^\[unreleased\]:\s+\S+/compare/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.HEAD\s*$",
            source,
        ) || _hygiene_fail("CHANGELOG.md has an invalid Unreleased compare link")
        return nothing
    end

    version = string(release_version)
    _release_heading_date(source, version)
    unreleased_link = Regex(
        "(?mi)^\\[unreleased\\]:\\s+\\S+/compare/v" *
        replace(version, "." => "\\.") * "\\.\\.\\.HEAD\\s*\$",
    )
    occursin(unreleased_link, source) || _hygiene_fail(
        "CHANGELOG.md Unreleased link is not advanced to $version",
    )
    release_link = Regex(
        "(?mi)^\\[" * replace(version, "." => "\\.") *
        "\\]:\\s+\\S+/(?:compare/v[0-9]+\\.[0-9]+\\.[0-9]+\\.\\.\\.v" *
        replace(version, "." => "\\.") * "|releases/tag/v" *
        replace(version, "." => "\\.") * ")\\s*\$",
    )
    occursin(release_link, source) || _hygiene_fail(
        "CHANGELOG.md is missing the $version release link",
    )
    _unreleased_is_empty(source) || _hygiene_fail(
        "CHANGELOG.md Unreleased section must be empty for a release",
    )
    return nothing
end

function validate_migration_metadata(metadata)
    schema_version = metadata.schema_version
    versions = collect(metadata.versions)
    schema_version isa Integer && schema_version >= 1 || _hygiene_fail(
        "POSTGRES_SCHEMA_VERSION must be a positive integer",
    )
    versions == collect(1:schema_version) || _hygiene_fail(
        "PostgreSQL migration versions must be contiguous through POSTGRES_SCHEMA_VERSION",
    )
    metadata.checksums_valid || _hygiene_fail(
        "PostgreSQL migration checksum validation failed",
    )
    return nothing
end

function _current_migration_metadata()
    try
        schema = Tiingo.DB.Schema
        migrations = schema.POSTGRES_MIGRATIONS
        return (
            schema_version = Tiingo.POSTGRES_SCHEMA_VERSION,
            versions = [migration.version for migration in migrations],
            checksums_valid = all(
                migration -> migration.checksum == schema.migration_checksum(
                    migration.version,
                    migration.name,
                    migration.definition,
                ),
                migrations,
            ),
        )
    catch
        _hygiene_fail("Unable to validate PostgreSQL migration metadata")
    end
end

function _git_head(root::AbstractString)::String
    try
        return strip(read(`git -C $root rev-parse HEAD`, String))
    catch
        _hygiene_fail("Unable to resolve the checked-out commit")
    end
end

function validate_release_hygiene(
    root::AbstractString=pwd();
    environ::AbstractDict=ENV,
    head_sha::AbstractString=_git_head(root),
    tracked_files::AbstractVector{<:AbstractString}=_tracked_files(root),
    migration_metadata=_current_migration_metadata(),
)
    mode, requested_version = release_hygiene_mode(environ; head_sha)
    version, _ = validate_project(joinpath(root, "Project.toml"))
    !isnothing(requested_version) && requested_version != version && _hygiene_fail(
        "requested release version does not match Project.toml",
    )
    validate_changelog(
        joinpath(root, "CHANGELOG.md");
        release_version = requested_version,
    )
    validate_citation(
        joinpath(root, "CITATION.cff");
        release_version = requested_version,
    )
    validate_config(joinpath(root, "config.toml"))
    validate_config(joinpath(root, "config.example.toml"))
    validate_tracked_env_files(tracked_files)
    validate_migration_metadata(migration_metadata)
    return (mode = mode, version = version, head_sha = String(head_sha))
end

function main()::Int
    try
        result = validate_release_hygiene()
        println("Release hygiene checks passed in $(result.mode) mode.")
        return 0
    catch error
        error isa InterruptException && rethrow()
        message = error isa ReleaseHygieneError ? error.message : "Unexpected validation failure"
        println(stderr, "ERROR: $message")
        return 1
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main())
end
