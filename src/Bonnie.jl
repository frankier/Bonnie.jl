module Bonnie

using Bonito
using Bonito: AbstractAsset, AbstractAssetServer, App, FrontendConnection, Session,
    WebSocketHandler, @js_str
using HTTP
using HTTP: WebSockets
using HTTP.WebSockets: WebSocket

export EmbeddedConnection, EmbeddedAssetServer, BonnieState, app_page, serve_spike

const DEFAULT_PREFIX = "/bonito"

include("registry.jl")
include("connection.jl")
include("assets.jl")
include("spike_server.jl")

end # module
