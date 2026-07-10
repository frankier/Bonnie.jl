using Test
using Bonito, Bonnie, HTTP
using HTTP.WebSockets

function wait_for(f; timeout = 10.0)
    deadline = time() + timeout
    while !f() && time() < deadline
        sleep(0.05)
    end
    return f()
end

slider_app() = App() do
    slider = Bonito.Slider(1:10)
    return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
end

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
    include("test_smoke.jl")
end
