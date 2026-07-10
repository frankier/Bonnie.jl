# Bring-your-own-router (mirror of mplbed's mount_app.py): with
# manage_routing = false the middleware only scopes the context, and the host
# app mounts Bonnie's sub-router itself — here on an HTTP.Router, so Bonnie's
# routes live alongside the app's own. The websocket upgrade is still handled
# at stream level by the middleware (request routers cannot upgrade).
#
#     julia --project=. examples/http/mount_app.jl

using Bonito, Bonnie, HTTP

const BONNIE_ROUTER = bonnie_router_factory()

function index(req::HTTP.Request)
    return app_page(App() do
        slider = Bonito.Slider(1:10)
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

function make_handler()
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", index)
    HTTP.register!(router, "GET", "/bonito/**",
                   req -> Bonnie.dispatch(BONNIE_ROUTER, req))
    return router
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    mw = bonnie_middleware(make_handler(); router = BONNIE_ROUTER, manage_routing = false)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    @info "Bonnie example running" url = "http://127.0.0.1:$(port)/"
    return (; server, mw)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
