# Server-push (mirror of mplbed's draw_idle.py): a server-side timer updates
# an Observable once a second and every connected page follows along over its
# websocket — no client interaction needed.
#
#     julia --project=. examples/http/interactive.jl

using Bonito, Bonnie, HTTP

const TICKS = Bonito.Observable(0)

function handler(req::HTTP.Request)
    path = Bonnie.target_path(req.target)
    path == "/probe" && return HTTP.Response(200, string(TICKS[]))
    path == "/" || return HTTP.Response(404)
    return app_page(App() do
        return Bonito.DOM.div("Server ticks: ", TICKS)
    end)
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    timer = Timer(1; interval = 1) do _
        TICKS[] += 1
    end
    mw = bonnie_middleware(handler)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    @info "Bonnie example running" url = "http://127.0.0.1:$(port)/"
    return (; server, mw, timer)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
