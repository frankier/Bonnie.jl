# Oxygen.jl integration (mirror of mplbed's integration/quart.py). Oxygen's
# route-registration API is module-level (`Oxygen.get`/`Oxygen.websocket`
# register on the calling module's CONTEXT[]), and `Oxygen.instance()` modules
# carry the same API — so `setup!` takes the module as `app` and covers both
# the default app and instance mode. Keep this module free of top-level side
# effects (plan trouble area 8).

module BonnieOxygenExt

using Bonnie, Oxygen, HTTP
using Bonnie: BonnieContext, BonnieRouter, bonnie_router_factory,
    serve_asset_response, handle_websocket, status_response,
    with_bonnie_request, with_native_app

"""
    setup!(Val(:oxygen); app = Oxygen, prefix = "/bonito", manage_routing = true,
           router = nothing, kw...) -> handle

Wire Bonnie into an Oxygen app (mirror of mplbed's per-framework `setup()`):

1. **Route registration** (`manage_routing = true`): registers
   `GET <prefix>/assets/{key}` and `WS <prefix>/ws/{session_id}` through
   Oxygen's own API so its docs page, metrics and middleware see them
   (plus `GET <prefix>/status` when `status_page_auth` is given). With
   `manage_routing = false`, mount `Bonnie.dispatch(handle.router, req)`
   yourself and register the websocket route manually — the escape hatch
   for wrapping the routes with auth/instrumentation.
2. **Middleware**: `handle.middleware` scopes the Bonnie context (and the
   Oxygen app as native app) around every request so `app_page`/`app_html`/
   `url_path_for` work in handlers. Install it with
   `serve(middleware = [handle.middleware])`.

`app` is the Oxygen module to register on — pass an `Oxygen.instance()`
module for instance mode. Remaining keywords go to
[`Bonnie.bonnie_router_factory`](@ref).

Returns `(; middleware, context, router, prefix, app)`.
"""
function Bonnie.setup!(::Val{:oxygen};
                       app::Module = Oxygen,
                       prefix::String = Bonnie.DEFAULT_PREFIX,
                       router::Union{Nothing, BonnieRouter} = nothing,
                       manage_routing::Bool = true, kw...)
    r = isnothing(router) ? bonnie_router_factory(; prefix, kw...) : router
    ctx = BonnieContext(r)
    manage_routing && register_routes!(app, ctx)
    middleware = bonnie_oxygen_middleware(ctx, app)
    return (; middleware, context = ctx, router = r, prefix = r.prefix, app)
end

function register_routes!(app::Module, ctx::BonnieContext)
    # Oxygen performs the websocket upgrade itself for WEBSOCKET routes
    # (from the stream stashed in req.context), so unlike the raw-HTTP.jl
    # path no stream-level middleware is needed here (plan trouble area 5).
    app.websocket(ctx.prefix * "/ws/{session_id}") do ws::HTTP.WebSockets.WebSocket, session_id::String
        handle_websocket(ctx.sessions, session_id, ws)
    end
    app.get(ctx.prefix * "/assets/{key}") do req::HTTP.Request, key::String
        serve_asset_response(ctx.assets, req, key)
    end
    if !isnothing(ctx.router.status_page_auth)
        app.get((req::HTTP.Request) -> status_response(ctx.router, req), ctx.prefix * "/status")
    end
    return
end

# Oxygen middleware: handler -> handler, scoping the ScopedValues per request
# (same body as bonnie_middleware minus the routing, which Oxygen owns).
function bonnie_oxygen_middleware(ctx::BonnieContext, app::Module)
    return function (handler)
        return function (req::HTTP.Request)
            with_bonnie_request(ctx) do
                with_native_app(app) do
                    handler(req)
                end
            end
        end
    end
end

end # module
