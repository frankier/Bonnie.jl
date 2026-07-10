# One slider app rendered through Bonnie's middleware on a raw HTTP.jl server.
#
#     julia --project=. examples/http/basic.jl
#
# then open http://127.0.0.1:8081/ — moving the slider updates the label via
# the websocket served by the host server (Bonito opens no port of its own).

using Bonito, Bonnie, HTTP

# Exposed via /probe so tests can assert the server saw slider values.
const LAST_VALUE = Bonito.Observable(0)

function handler(req::HTTP.Request)
    path = Bonnie.target_path(req.target)
    path == "/probe" && return HTTP.Response(200, string(LAST_VALUE[]))
    path == "/" || return HTTP.Response(404)
    return app_page(App() do
        slider = Bonito.Slider(1:10)
        Bonito.on(slider.value) do v
            LAST_VALUE[] = v
        end
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    mw = bonnie_middleware(handler)
    # listen! (not serve): the middleware is a stream handler so it can
    # upgrade the /bonito/ws/<session-id> websockets.
    server = HTTP.listen!(mw, "127.0.0.1", port)
    @info "Bonnie example running" url = "http://127.0.0.1:$(port)/"
    return (; server, mw)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
