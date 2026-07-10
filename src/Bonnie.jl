module Bonnie

using Bonito
using Bonito: AbstractAsset, AbstractAssetServer, App, FrontendConnection, Session,
    WebSocketHandler, @js_str
using HTTP
using HTTP: WebSockets
using HTTP.WebSockets: WebSocket

export EmbeddedConnection, EmbeddedAssetServer,
    BonnieContext, BonnieRouter, MissingBonnieContext,
    bonnie_middleware, bonnie_router_factory,
    current_context, with_bonnie, get_native_app, url_path_for,
    app_page, app_html, app_page_html, head_content, default_app_page_template,
    setup!

include("consts.jl")
include("registry.jl")
include("connection.jl")
include("assets.jl")
include("router.jl")
include("context.jl")
include("middleware.jl")
include("html.jl")
include("pages.jl")
include("safe.jl")

"""
    setup!(::Val{framework}; kw...)

Entry point for host-framework integrations (mirror of mplbed's per-framework
`setup()`), implemented by package extensions. `setup!(Val(:oxygen); ...)`
will be provided by the Oxygen extension once Oxygen.jl is loaded.
"""
function setup! end

function setup!(::Val{F}; kw...) where {F}
    if F === :oxygen
        error("Bonnie's Oxygen integration is provided by a package extension: " *
              "run `using Oxygen` before calling `setup!(Val(:oxygen))`. " *
              "(If Oxygen is already loaded, this Bonnie version does not ship " *
              "the extension yet — see plan step 4.)")
    end
    error("Bonnie has no integration for framework `$(F)`. Available: :oxygen " *
          "(requires `using Oxygen`).")
end

end # module
