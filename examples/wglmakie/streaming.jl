# WGLMakie figure with interactivity and server-push in one page (port of
# the demo from Oxygen.jl PR #212): a button increments a counter, and a
# server-side ticker streams (tick, counter) points into a lines plot. The
# per-session ticker is tied to session close — the PR's bare @async loop
# leaked forever.
#
#     julia --project=examples/wglmakie examples/wglmakie/streaming.jl

using Bonito, Bonnie, HTTP
using WGLMakie
using WGLMakie: Makie

# Exposed via /probe so tests can assert the server saw button clicks.
const LAST_COUNTER = Bonito.Observable(0)

function streaming_app()
    return App() do session::Bonito.Session
        points = Bonito.Observable(Makie.Point2f[(0, 0)])
        counter = Bonito.Observable(0)
        button = Bonito.Button("increment")
        Bonito.on(button.value) do _
            counter[] += 1
            LAST_COUNTER[] = counter[]
        end

        tick = 0
        ticker = Timer(1; interval = 1) do _
            tick += 1
            pts = push!(copy(points[]), Makie.Point2f(tick, counter[]))
            length(pts) > 10 && popfirst!(pts)
            points[] = pts
        end
        Bonito.on(_ -> close(ticker), session.on_close)

        fig = Makie.Figure()
        ax = Makie.Axis(fig[1, 1])
        Makie.lines!(ax, points)
        Bonito.on(_ -> Makie.autolimits!(ax), points)

        return Bonito.DOM.div(Bonito.DOM.h2(counter), button, fig)
    end
end

function handler(req::HTTP.Request)
    path = Bonnie.target_path(req.target)
    path == "/probe" && return HTTP.Response(200, string(LAST_COUNTER[]))
    path == "/" || return HTTP.Response(404)
    return app_page(streaming_app())
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    WGLMakie.activate!()
    mw = bonnie_middleware(handler)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    @info "Bonnie WGLMakie example running" url = "http://127.0.0.1:$(port)/"
    return (; server, mw)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
