# Request-scoped context (mirror of mplbed's ContextVars in asgi.py), carried
# by Base.ScopedValues. `bonnie_middleware` establishes the scope for every
# request; tasks spawned inside inherit it (snapshot at task creation), so
# Bonito tasks spawned during rendering see the right context.
#
# Do not read these lazily from long-lived objects: the websocket handler and
# session callbacks run outside the originating request's scope. Everything a
# session needs later is captured eagerly into EmbeddedConnection /
# EmbeddedAssetServer at render time.

using Base.ScopedValues

"""
    MissingBonnieContext

Thrown by context-dependent calls (`app_page`, `url_path_for`, ...) made
outside a `bonnie_middleware`/[`with_bonnie`](@ref) scope.
"""
struct MissingBonnieContext <: Exception end

function Base.showerror(io::IO, ::MissingBonnieContext)
    print(io, "MissingBonnieContext: no Bonnie context is in scope. This call must run " *
              "inside a request handled by `bonnie_middleware`, or inside " *
              "`with_bonnie(ctx) do ... end`.")
end

"""
    BonnieContext

Everything Bonnie needs to render and serve apps: the mount `prefix`, the
[`BonnieRouter`](@ref) (named routes for [`url_path_for`](@ref)) and the
session/asset registries. Constructed by `bonnie_middleware` /
[`bonnie_router_factory`](@ref) and made available to handlers via a
`ScopedValue`; read it with [`current_context`](@ref).
"""
struct BonnieContext
    prefix::String
    router::BonnieRouter
    sessions::SessionRegistry
    assets::AssetRegistry
end

BonnieContext(router::BonnieRouter) =
    BonnieContext(router.prefix, router, router.sessions, router.assets)

const CURRENT_CONTEXT = ScopedValue{Union{BonnieContext, Nothing}}(nothing)
const CURRENT_NATIVE_APP = ScopedValue{Any}(nothing)

# Per-request page state. Bonito's client JS keeps one connection sender per
# page (`Bonito.on_connection_open` is global), so several independent root
# sessions on one page fight over it — the last one wins and the others go
# deaf. The fix is Bonito's own multi-app model: ONE root session per
# rendered page owning the websocket, with every app on the page a
# subsession sharing it. The middleware installs a fresh PageState per
# request; `head_content`/`app_html` lazily create and emit the root.
mutable struct PageState
    root::Union{Nothing, Session}
    root_emitted::Bool
end
PageState() = PageState(nothing, false)

const CURRENT_PAGE = ScopedValue{Union{Nothing, PageState}}(nothing)

# Establish the per-request dynamic scope: context + fresh page state.
# Shared by bonnie_middleware and the framework-integration middlewares.
with_bonnie_request(f, ctx::BonnieContext) =
    with(f, CURRENT_CONTEXT => ctx, CURRENT_PAGE => PageState())

"""
    current_context() -> BonnieContext

The context established by `bonnie_middleware` for the request in flight.
Throws [`MissingBonnieContext`](@ref) outside such a scope.
"""
function current_context()
    ctx = CURRENT_CONTEXT[]
    isnothing(ctx) && throw(MissingBonnieContext())
    return ctx
end

"""
    get_native_app()

The host framework's app object for the request in flight (e.g. the Oxygen
context), or `nothing`. Set by framework integrations.
"""
get_native_app() = CURRENT_NATIVE_APP[]

"""
    with_bonnie(f, ctx::BonnieContext)

Run `f()` with `ctx` in scope, as `bonnie_middleware` does per request. Useful
for rendering outside a request (startup, tests, REPL).
"""
with_bonnie(f, ctx::BonnieContext) = with(f, CURRENT_CONTEXT => ctx)

with_native_app(f, app) = with(f, CURRENT_NATIVE_APP => app)

"""
    url_path_for(name::Symbol; params...) -> String

Resolve a named route of the Bonnie sub-router against the current prefix,
e.g. `url_path_for(:ws; session_id = id)` or `url_path_for(:assets; key = k)`.
"""
url_path_for(name::Symbol; params...) = url_path_for(current_context().router, name; params...)
