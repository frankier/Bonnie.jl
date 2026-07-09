# Plan step 1 spike example: one slider app rendered through Bonnie's
# EmbeddedConnection/EmbeddedAssetServer on a hand-rolled HTTP.jl server.
#
#     julia --project=. examples/http/spike_slider.jl
#
# then open http://127.0.0.1:8081/ — moving the slider updates the label via
# the websocket served by the host server (Bonito opens no port of its own).

using Bonito, Bonnie, HTTP

const STATE = Ref{Any}(nothing)
# Exposed so tests can assert the server saw slider values (plan's /probe idea).
const LAST_VALUE = Bonito.Observable(0)

function index(req::HTTP.Request)
    Bonnie.target_path(req.target) == "/" || return HTTP.Response(404)
    return app_page(STATE[].state, App() do
        slider = Bonito.Slider(1:10)
        Bonito.on(slider.value) do v
            LAST_VALUE[] = v
        end
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    STATE[] = serve_spike(index; port = port)
    @info "Spike server running" url = "http://127.0.0.1:$(port)/"
    return STATE[]
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
    wait(STATE[].server)
end
