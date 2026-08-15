using QuansiftMarketData
using Documenter

DocMeta.setdocmeta!(
    QuansiftMarketData,
    :DocTestSetup,
    :(using QuansiftMarketData);
    recursive = true,
)

const page_rename = Dict("developer.md" => "Developer docs") # Without the numbers
const numbered_pages = [
    file for file in readdir(joinpath(@__DIR__, "src")) if
    file != "index.md" && splitext(file)[2] == ".md"
]

makedocs(;
    modules = [QuansiftMarketData],
    authors = "Kojiroh <kojiroh.homma@gmail.com> and contributors",
    repo = "https://github.com/Quansift/QuansiftMarketData.jl/blob/{commit}{path}#{line}",
    sitename = "QuansiftMarketData.jl",
    warnonly = [:missing_docs, :cross_references],
    format = Documenter.HTML(;
        canonical = "https://quansift.github.io/QuansiftMarketData.jl",
    ),
    pages = ["index.md"; numbered_pages],
)

if lowercase(get(ENV, "DOCS_DEPLOY", "true")) in ("1", "true", "yes")
    deploydocs(;
        repo = "github.com/Quansift/QuansiftMarketData.jl",
        devbranch = "main",
    )
else
    @info "DOCS_DEPLOY is false; skipping deploydocs"
end
