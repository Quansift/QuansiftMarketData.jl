# docs/architecture is an Open Knowledge Format (OKF) v0.2 bundle:
# https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
#
# WHY THIS TEST EXISTS
#   The pages claim to be derived from named source files ("is this document still
#   true?" must have a mechanical answer). That claim rots silently when a source
#   file is renamed or deleted, or when a page is added without being listed in the
#   index. This checks the parts of OKF conformance (§11) and of our own conventions
#   that a plain Markdown link checker cannot see. Text inspection only: no YAML
#   parser, no network.

using Test

const OKF_BUNDLE = normpath(joinpath(@__DIR__, "..", "docs", "architecture"))
const OKF_RESERVED = ("index.md", "log.md")

function okf_split(text)
    m = match(r"\A---\n(.*?)\n---\n(.*)\z"s, text)
    m === nothing ? (nothing, text) : (String(m.captures[1]), String(m.captures[2]))
end

@testset "docs/architecture is a conformant OKF bundle" begin
    pages = sort(filter(f -> endswith(f, ".md") && !(f in OKF_RESERVED), readdir(OKF_BUNDLE)))
    @test !isempty(pages)

    @testset "$page" for page in pages
        fm, _ = okf_split(read(joinpath(OKF_BUNDLE, page), String))
        @test fm !== nothing                                              # §11.1
        fm === nothing && continue
        @test occursin(r"(?m)^type:\s*\S", fm)                           # §11.2
        @test occursin(r"(?m)^description:\s*\S", fm)
        @test !occursin("source_of_truth", fm)                            # replaced by `sources`
        @test !occursin("external_authority", fm)
        for m in eachmatch(r"(?m)^\s+resource:\s*(\S.*?)\s*$", fm)
            resource = String(m.captures[1])
            # Path-valued resources (§6.2) must exist; URLs and scope descriptors are not paths.
            (startswith(resource, "./") || startswith(resource, "../")) || continue
            @test ispath(normpath(joinpath(OKF_BUNDLE, resource)))
        end
        v = match(r"(?m)^last_verified:\s*(\S+)\s*$", fm)
        v === nothing || @test occursin(r"^\d{4}-\d{2}-\d{2}$", v.captures[1])
    end

    @testset "index.md" begin
        text = read(joinpath(OKF_BUNDLE, "index.md"), String)
        fm, body = okf_split(text)
        # §8: no frontmatter except okf_version on the bundle root.
        fm === nothing || @test occursin(r"\A\s*okf_version:\s*\"0\.2\"\s*\z", fm)
        linked = Set(String(m.captures[1]) for m in eachmatch(r"(?m)^\* \[[^\]]+\]\(([^)]+)\)", body))
        for target in linked
            @test ispath(joinpath(OKF_BUNDLE, target))
        end
        # Progressive disclosure is only honest if every page is listed.
        for page in pages
            @test page in linked
        end
    end

    @testset "log.md" begin
        text = read(joinpath(OKF_BUNDLE, "log.md"), String)
        dates = [String(m.captures[1]) for m in eachmatch(r"(?m)^## (\S+)\s*$", text)]
        @test !isempty(dates)
        @test all(d -> occursin(r"^\d{4}-\d{2}-\d{2}$", d), dates)       # §9: ISO 8601
        @test issorted(dates; rev = true)                                  # newest first
    end
end
