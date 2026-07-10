using Documenter, Bonnie

makedocs(;
    sitename = "Bonnie.jl",
    modules = [Bonnie],
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references],
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "Examples" => "examples.md",
    ],
)

deploydocs(; repo = "github.com/frankier/Bonnie.jl", push_preview = false)
