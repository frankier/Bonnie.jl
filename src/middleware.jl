# bonnie_middleware (mirror of mplbed's MplbedMiddleware): wraps the host
# app's handler, establishes the ScopedValue context for every request, and —
# with manage_routing = true — intercepts <prefix>/... for the sub-router.
#
# The middleware is callable both as a request handler (assets, status,
# context scoping) and as a stream handler. HTTP.jl can only upgrade a
# websocket from a stream handler (HTTP/1.1 streams; see
# HTTP.WebSockets.upgrade), so serve it with `HTTP.listen!(mw, host, port)` —
# plain request-handler serving would answer the ws route with 426.

struct BonnieMiddleware{H}
    ctx::BonnieContext
    handler::H
    manage_routing::Bool
end

"""
    bonnie_middleware(handler; prefix = DEFAULT_PREFIX, router = nothing,
                      manage_routing = true, kw...) -> BonnieMiddleware

Wrap the host app's request handler. Every request runs with the
[`BonnieContext`](@ref) in scope (so `app_page`/`app_html`/`url_path_for`
work); requests under `prefix` are dispatched to the Bonnie sub-router before
`handler` sees them (disable with `manage_routing = false` to mount the
router yourself via `dispatch`). Remaining keywords go to
[`bonnie_router_factory`](@ref); pass `router` to bring your own.

Serve the result with `HTTP.listen!(mw, host, port)` — the middleware is a
stream handler so it can upgrade `<prefix>/ws/<session-id>` websockets.
`close(mw)` stops the session sweeper and closes remaining sessions.
"""
function bonnie_middleware(handler; prefix::String = DEFAULT_PREFIX,
                           router::Union{Nothing, BonnieRouter} = nothing,
                           manage_routing::Bool = true, kw...)
    r = isnothing(router) ? bonnie_router_factory(; prefix, kw...) : router
    return BonnieMiddleware(BonnieContext(r), handler, manage_routing)
end

function (m::BonnieMiddleware)(req::HTTP.Request)
    with_bonnie_request(m.ctx) do
        if m.manage_routing
            resp = dispatch(m.ctx.router, req)
            isnothing(resp) || return resp
        end
        return m.handler(req)
    end
end

function (m::BonnieMiddleware)(stream::HTTP.Stream)
    req = stream.message
    if WebSockets.isupgrade(req)
        session_id = match_ws_path(m.ctx.router, target_path(req.target))
        if !isnothing(session_id)
            handle_ws_upgrade(m.ctx.router, stream, session_id)
            return
        end
        # Not our websocket: fall through — the request handler's response
        # (however it answers) rejects the upgrade.
    end
    try
        HTTP.streamhandler(m)(stream)
    catch e
        e isa Base.IOError || rethrow(e)
    end
    return
end

function handle_ws_upgrade(router::BonnieRouter, stream::HTTP.Stream, session_id::AbstractString)
    try
        # check_origin relaxed like Bonito's own server (webviews etc.).
        # Frame caps lifted like Bonito's own server: HTTP 2.x defaults to
        # 16 MiB frames / 1024 fragments and Bonito round-trips larger binary
        # payloads (e.g. WGLMakie buffers).
        WebSockets.upgrade(stream; check_origin = (_...) -> true,
                           maxframesize = typemax(Int),
                           maxfragmentation = typemax(Int)) do ws
            handle_websocket(router.sessions, session_id, ws)
        end
    catch e
        e isa Base.IOError || rethrow(e)
    end
    return
end

Base.close(m::BonnieMiddleware) = close(m.ctx.sessions)
