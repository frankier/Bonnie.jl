# EmbeddedConnection: like Bonito.WebSocketConnection, but instead of
# registering a route on a Bonito.Server it parks itself in Bonnie's session
# registry and waits for the host HTTP.jl server to hand it an upgraded
# HTTP.WebSocket. All context (prefix, registry) is captured eagerly at
# construction — the ws handler runs outside the originating request's scope.

mutable struct EmbeddedConnection <: FrontendConnection
    registry::SessionRegistry
    prefix::String
    handler::WebSocketHandler
    session::Union{Nothing, Session}
end

function EmbeddedConnection(registry::SessionRegistry, prefix::String = DEFAULT_PREFIX)
    return EmbeddedConnection(registry, prefix, WebSocketHandler(), nothing)
end

Base.isopen(c::EmbeddedConnection) = isopen(c.handler)
Base.write(c::EmbeddedConnection, bytes::AbstractVector{UInt8}) = write(c.handler, bytes)

function Base.close(c::EmbeddedConnection)
    close(c.handler)
    session = c.session
    # Break the cycle before cascading: close(session) closes the connection.
    c.session = nothing
    if !isnothing(session)
        remove!(c.registry, session.id)
        close(session)
    end
    return
end

function Bonito.setup_connection(session::Session{EmbeddedConnection})
    c = session.connection
    c.session = session
    register!(c.registry, session)
    # The JS side (Websocket.js) does proxy_url.replace("http", "ws") and
    # appends "/<session_id>", so hand it an absolute http(s) URL ending at
    # our ws mount point, built from window.location at page load.
    ws_base = c.prefix * "/ws"
    return js"""
        $(Bonito.Websocket).then(WS => {
            const proxy_url = window.location.protocol + "//" + window.location.host + $(ws_base);
            WS.setup_connection({
                proxy_url: proxy_url,
                session_id: $(session.id),
                compression_enabled: $(session.compression_enabled),
                query: "",
                main_connection: true
            })
        })
    """
end

# Called by the host server once it has upgraded GET <prefix>/ws/<session_id>.
# One receive-loop task per connection keeps per-session message processing
# naturally serial.
function handle_websocket(registry::SessionRegistry, session_id::AbstractString, ws::WebSocket)
    session = lookup(registry, session_id)
    if isnothing(session)
        close(ws)
        return
    end
    connection = session.connection::EmbeddedConnection
    try
        Bonito.run_connection_loop(session, connection.handler, ws)
    finally
        # Mirror Bonito's own WebSocketConnection teardown: only the loop
        # owning the handler's current socket tears down (a stale loop whose
        # browser already reconnected must not touch the live session), and
        # with a soft-close window the session stays registered so a
        # reconnect within the window resumes it; the registry sweeper reaps
        # it via should_cleanup once the window passes.
        if Bonito.is_current_socket(connection.handler, ws)
            if Bonito.allow_soft_close(registry.cleanup_policy)
                Bonito.soft_close(session)
            else
                remove!(registry, session.id)
                close(session)
            end
        end
    end
    return
end
