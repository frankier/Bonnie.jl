# Bonito app served through Oxygen (mirror of mplbed's quart/basic.py):
# setup! registers Bonnie's asset + websocket routes through Oxygen's own
# API, and the returned middleware scopes the context for app_page.
#
#     julia --project=. examples/oxygen/basic.jl

using Oxygen, Bonito, Bonnie, HTTP

# Exposed via /probe so tests can assert the server saw slider values.
const LAST_VALUE = Bonito.Observable(0)

const BONNIE = Bonnie.setup!(Val(:oxygen))

@get "/" function (req::HTTP.Request)
    return app_page(App() do
        slider = Bonito.Slider(1:10)
        Bonito.on(slider.value) do v
            LAST_VALUE[] = v
        end
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

@get "/probe" function (req::HTTP.Request)
    return string(LAST_VALUE[])
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    server = serve(; port, middleware = [BONNIE.middleware], async = true,
                   show_banner = false)
    @info "Bonnie Oxygen example running" url = "http://127.0.0.1:$(port)/"
    return (; server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
