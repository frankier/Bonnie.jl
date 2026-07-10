# The Bonnie sub-router (mirror of mplbed's server/impl.py Starlette sub-app):
# a small named-route table so `url_path_for` works by name, plus the request-
# level handlers for assets and the status page. The websocket upgrade itself
# is stream-level and lives in middleware.jl (HTTP.jl can only upgrade from a
# stream handler).

"""
    BonnieRouter

Named-route table plus the registries the routes serve. Routes:

- `:assets` — `GET <prefix>/assets/{key}`, registered Bonito assets.
- `:ws` — `<prefix>/ws/{session_id}`, per-session websocket endpoint.
- `:status` — `GET <prefix>/status`, optional status page (session count,
  uptime); only served when `status_page_auth` is provided.

Build one with [`bonnie_router_factory`](@ref).
"""
struct BonnieRouter
    prefix::String
    sessions::SessionRegistry
    assets::AssetRegistry
    routes::Dict{Symbol, String}
    status_page_auth::Union{Nothing, Function}
    created::Float64
end

"""
    bonnie_router_factory(; prefix = DEFAULT_PREFIX, session_ttl = 300.0,
                          reconnect_window = 30.0, sessions, assets,
                          status_page_auth = nothing)

Build the [`BonnieRouter`](@ref) that `bonnie_middleware` mounts under
`prefix`. `session_ttl` (seconds) controls when never-connected sessions are
swept and `reconnect_window` (seconds) how long a disconnected session stays
resumable (see [`SessionRegistry`](@ref)); pass `sessions`/`assets` to share
registries across routers. The status page is disabled unless
`status_page_auth(req)::Bool` is given — authentication is mandatory,
mirroring mplbed's `MplPageAuth`.
"""
function bonnie_router_factory(; prefix::String = DEFAULT_PREFIX,
                               session_ttl::Real = 300.0,
                               reconnect_window::Real = 30.0,
                               sessions::SessionRegistry = SessionRegistry(; session_ttl, reconnect_window),
                               assets::AssetRegistry = AssetRegistry(),
                               status_page_auth::Union{Nothing, Function} = nothing)
    startswith(prefix, "/") || throw(ArgumentError("prefix must start with '/': $(repr(prefix))"))
    (prefix == "/" || endswith(prefix, "/")) &&
        throw(ArgumentError("prefix must not end with '/': $(repr(prefix))"))
    routes = Dict{Symbol, String}(
        :assets => "/assets/{key}",
        :ws => "/ws/{session_id}",
        :status => "/status",
    )
    return BonnieRouter(prefix, sessions, assets, routes, status_page_auth, time())
end

function url_path_for(router::BonnieRouter, name::Symbol; params...)
    template = get(router.routes, name) do
        throw(ArgumentError("no Bonnie route named $(repr(name)); available: " *
                            join(sort!(collect(keys(router.routes))), ", ")))
    end
    path = template
    for (k, v) in pairs(params)
        needle = "{$(k)}"
        occursin(needle, path) ||
            throw(ArgumentError("route $(repr(name)) has no parameter $(repr(k))"))
        path = replace(path, needle => string(v))
    end
    occursin('{', path) &&
        throw(ArgumentError("missing parameter(s) for route $(repr(name)): $(path)"))
    return router.prefix * path
end

# Relative path under the router's prefix, or nothing if the request is not
# ours. "/bonito" and "/bonito/..." match; "/bonitofoo" does not.
function prefix_relative(router::BonnieRouter, path::AbstractString)
    path == router.prefix && return ""
    base = router.prefix * "/"
    startswith(path, base) || return nothing
    return path[lastindex(base):end]   # keep the leading '/'
end

"""
    dispatch(router::BonnieRouter, req::HTTP.Request) -> Union{HTTP.Response, Nothing}

Handle a request under the router's prefix; return `nothing` when the request
is outside the prefix (the caller passes it on to the host app). Websocket
paths reached at request level answer 426: the upgrade needs the stream-level
middleware (serve through `HTTP.listen!`, see `bonnie_middleware`).
"""
function dispatch(router::BonnieRouter, req::HTTP.Request)
    rel = prefix_relative(router, target_path(req.target))
    isnothing(rel) && return nothing
    if startswith(rel, "/assets/")
        key = rel[nextind(rel, lastindex("/assets/")):end]
        return serve_asset_response(router.assets, req, key)
    elseif startswith(rel, "/ws/")
        return HTTP.Response(426, ["Upgrade" => "websocket"];
                             body = "websocket endpoint: this server is not running Bonnie's " *
                                    "stream-level middleware (serve it with HTTP.listen!)")
    elseif rel == "/status"
        return status_response(router, req)
    end
    return HTTP.Response(404)
end

# Matches "<prefix>/ws/<session_id>" and returns the session id, else nothing.
function match_ws_path(router::BonnieRouter, path::AbstractString)
    rel = prefix_relative(router, path)
    (isnothing(rel) || !startswith(rel, "/ws/")) && return nothing
    id = rel[nextind(rel, lastindex("/ws/")):end]
    return isempty(id) || occursin('/', id) ? nothing : id
end

function status_response(router::BonnieRouter, req::HTTP.Request)
    auth = router.status_page_auth
    isnothing(auth) && return HTTP.Response(404)
    auth(req) === true || return HTTP.Response(403)
    body = """
    sessions: $(length(router.sessions))
    uptime_seconds: $(round(time() - router.created; digits = 1))
    prefix: $(router.prefix)
    """
    return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"]; body)
end
