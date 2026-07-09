# Plan step 1 spike: a hand-rolled HTTP.jl server that renders Bonito apps
# through EmbeddedConnection/EmbeddedAssetServer without Bonito opening its
# own port. The middleware/sub-router split (bonnie_middleware,
# bonnie_router_factory, ScopedValues) lands in step 2 — here everything is
# threaded through BonnieState explicitly.

struct BonnieState
    prefix::String
    sessions::SessionRegistry
    assets::AssetRegistry
end

BonnieState(prefix::String = DEFAULT_PREFIX) = BonnieState(prefix, SessionRegistry(), AssetRegistry())

"""
    app_page(state::BonnieState, app::Bonito.App) -> HTTP.Response

Render `app` as a full standalone HTML page against a fresh `Session` backed
by Bonnie's connection and asset server, register the session so the host
server can complete the websocket handshake, and return the page response.
"""
function app_page(state::BonnieState, app::App; status::Integer = 200)
    connection = EmbeddedConnection(state.sessions, state.prefix)
    asset_server = EmbeddedAssetServer(state.assets, state.prefix)
    session = Session(connection; asset_server = asset_server, title = app.title)
    io = IOBuffer()
    Bonito.page_html(io, session, app)
    return HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8"]; body = take!(io))
end

app_page(state::BonnieState, f::Function; kw...) = app_page(state, App(f); kw...)

# HTTP 2.x no longer re-exports URIs.URI; the spike only needs the path, so
# strip the query/fragment by hand instead of pulling in a URIs dependency.
target_path(target::AbstractString) = String(first(split(target, ('?', '#'); limit = 2)))

function handle_request(state::BonnieState, handler, req::HTTP.Request)
    path = target_path(req.target)
    assets_base = state.prefix * "/assets/"
    if startswith(path, assets_base)
        key = path[nextind(path, lastindex(assets_base)):end]
        return serve_asset_response(state.assets, req, key)
    end
    return handler(req)
end

# HTTP.jl 2.0 dropped the `HTTP.Streams` submodule; `Stream` lives at top level.
function stream_handler(state::BonnieState, handler, stream::HTTP.Stream)
    req = stream.message
    if WebSockets.isupgrade(req)
        ws_base = state.prefix * "/ws/"
        path = target_path(req.target)
        if !startswith(path, ws_base)
            HTTP.setstatus(stream, 404)
            HTTP.startwrite(stream)
            return
        end
        session_id = path[nextind(path, lastindex(ws_base)):end]
        try
            # check_origin relaxed like Bonito's own server (webviews etc.);
            # revisit before this graduates from spike to library code.
            # Frame caps lifted like Bonito's own server: HTTP 2.4 defaults to
            # 16 MiB frames / 1024 fragments and Bonito round-trips larger
            # binary payloads (e.g. WGLMakie buffers).
            WebSockets.upgrade(stream; check_origin = (_...) -> true,
                               maxframesize = typemax(Int),
                               maxfragmentation = typemax(Int)) do ws
                handle_websocket(state.sessions, session_id, ws)
            end
        catch e
            e isa Base.IOError || rethrow(e)
        end
        return
    end
    http_handler = HTTP.streamhandler() do req
        handle_request(state, handler, req)
    end
    try
        http_handler(stream)
    catch e
        e isa Base.IOError || rethrow(e)
    end
end

"""
    serve_spike(handler; host="127.0.0.1", port=8081, prefix=DEFAULT_PREFIX)

Start the spike server. `handler(req) -> HTTP.Response` is the host app;
requests under `prefix` (assets, websocket) are intercepted before it runs.
Returns `(; server, state)`; `close(server)` stops it.
"""
function serve_spike(handler; host = "127.0.0.1", port::Integer = 8081,
                     prefix::String = DEFAULT_PREFIX)
    state = BonnieState(prefix)
    server = HTTP.listen!(host, port) do stream
        stream_handler(state, handler, stream)
    end
    return (; server, state)
end
