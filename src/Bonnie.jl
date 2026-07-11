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
    iframe_for, setup!,
    figure_page, figure_html, figure_page_html

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
    figure_page(fig; kw...) / figure_html(fig) / figure_page_html(fig)

Makie-figure variants of [`app_page`](@ref)/[`app_html`](@ref)/
[`app_page_html`](@ref) (mplbed's `figure_page`/`figure_html`), provided by
the WGLMakie package extension: load WGLMakie to enable them. `Safe.figure_html`
returns pre-trusted markup like the other `Safe` variants.
"""
function figure_page end
function figure_html end
function figure_page_html end

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
              "run `using Oxygen` before calling `setup!(Val(:oxygen))`.")
    end
    error("Bonnie has no integration for framework `$(F)`. Available: :oxygen " *
          "(requires `using Oxygen`).")
end

end # module
