using Test
using Bonito, Bonnie, HTTP
using HTTP.WebSockets

include("helpers.jl")
include("conftest.jl")

@testset "Bonnie" begin
    include("test_unit.jl")
    include("test_canary.jl")
    # Oxygen is optional (weakdep): the extension tests only run where the
    # test env provides it (the dedicated no-Oxygen CI job proves the core
    # works without it).
    if !isnothing(Base.find_package("Oxygen"))
        include("test_oxygen.jl")
    end
    # WGLMakie is a heavy weakdep: its canary only runs where the env
    # provides it (standalone: julia --project=examples/wglmakie
    # test/test_wglmakie.jl; CI runs it as a dedicated job).
    if !isnothing(Base.find_package("WGLMakie"))
        include("test_wglmakie.jl")
    end
    include("test_smoke.jl")
end
