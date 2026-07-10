# Smoke tests (port of mplbed's test_smoke.py): launch every example, wait
# for its port, GET each route and assert the server stays up. See
# conftest.jl for the modes.

const SMOKE_MODE = get(ENV, "BONNIE_SMOKE_MODE", "subprocess")

@testset "smoke: examples ($SMOKE_MODE)" begin
    for spec in EXAMPLE_SPECS
        smoke_enabled(spec) || continue
        @testset "$(spec.id)" begin
            if SMOKE_MODE == "inprocess"
                smoke_inprocess(spec)
            else
                smoke_subprocess(spec)
            end
        end
    end
end
