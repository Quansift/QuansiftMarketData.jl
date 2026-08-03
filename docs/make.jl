using Tiingo
using Documenter

DocMeta.setdocmeta!(Tiingo, :DocTestSetup, :(using Tiingo); recursive = true)

const page_rename = Dict("developer.md" => "Developer docs") # Without the numbers
const numbered_pages = [
    file for file in readdir(joinpath(@__DIR__, "src")) if
    file != "index.md" && splitext(file)[2] == ".md"
]

makedocs(;
    modules = [Tiingo],
    authors = "Kojiroh <kojiroh.homma@gmail.com> and contributors",
    repo = "https://github.com/Quansift/Tiingo.jl/blob/{commit}{path}#{line}",
    sitename = "Tiingo.jl",
    warnonly = [:missing_docs, :cross_references],
    format = Documenter.HTML(; canonical = "https://quansift.github.io/Tiingo.jl"),
    pages = ["index.md"; numbered_pages],
)

if lowercase(get(ENV, "DOCS_DEPLOY", "true")) in ("1", "true", "yes")
    deploydocs(; repo = "github.com/Quansift/Tiingo.jl", devbranch = "main")
else
    @info "DOCS_DEPLOY is false; skipping deploydocs"
end
