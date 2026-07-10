# HTML rendering (mirror of mplbed's html/impl.py + raw.py): fragments,
# standalone pages and the head_content hook for template users.

"""
    bonnie_session(ctx::BonnieContext; title = "Bonnie App") -> Bonito.Session

Fresh `Session` backed by Bonnie's [`EmbeddedConnection`](@ref) and
[`EmbeddedAssetServer`](@ref); prefix and registries are captured eagerly
from `ctx` (session callbacks run outside the request's scope).
"""
function bonnie_session(ctx::BonnieContext; title::String = "Bonnie App")
    connection = EmbeddedConnection(ctx.sessions, ctx.prefix)
    asset_server = EmbeddedAssetServer(ctx.assets, ctx.prefix)
    return Session(connection; asset_server = asset_server, title = title)
end

render_dom(dom) = sprint(io -> show(io, MIME"text/html"(), dom))

# Lazily create/emit the request's root session (see PageState in
# context.jl). Returns the root-init HTML the first time, "" afterwards.
function page_root_html(ctx::BonnieContext, page::PageState)
    isnothing(page.root) && (page.root = bonnie_session(ctx))
    page.root_emitted && return ""
    page.root_emitted = true
    # An empty root app: emits the BonitoLib import, the websocket bootstrap
    # (setup_connection, which also registers the session) and the root
    # init_session call — the shared machinery every fragment on the page
    # plugs into.
    dom = Bonito.session_dom(page.root, App(nothing))
    html = render_dom(dom)
    # Sets status = DISPLAYED and stamps closing_time, which is what the
    # cleanup policy's never-connected timeout keys off (Bonito's own
    # display paths do this; our render path must too).
    Bonito.mark_displayed!(page.root)
    return html
end

"""
    app_html(app::App; context = current_context()) -> String

HTML fragment for one Bonito app, for embedding in a caller-owned
template/page; mplbed's `figure_html`. Also callable as
`app_html(f::Function; kw...)` with `f() -> App`.

Inside a request (`bonnie_middleware` scope) each app renders as a
**subsession** of one per-page root session that owns the page's websocket —
Bonito's client keeps a single connection sender per page, so several
independent root sessions on one page cannot all work. The root's bootstrap
scripts are emitted by [`head_content`](@ref) if it was called earlier,
otherwise they are prepended to the first fragment.

Outside any request scope the fragment is a self-contained root session
(fine for a single app per page).
"""
function app_html(app::App; context::BonnieContext = current_context())
    page = CURRENT_PAGE[]
    if isnothing(page)
        session = bonnie_session(context; title = app.title)
        dom = Bonito.session_dom(session, app)
        html = render_dom(dom)
        Bonito.mark_displayed!(session)
        return html
    end
    root_html = page_root_html(context, page)
    sub = Session(page.root)
    dom = Bonito.session_dom(sub, app)
    html = render_dom(dom)
    Bonito.mark_displayed!(sub)
    return root_html * html
end

app_html(f::Function; kw...) = app_html(App(f); kw...)

"""
    head_content(; context = current_context()) -> String

The page-level Bonito bootstrap (script imports, websocket setup, root
session init) that every [`app_html`](@ref) fragment on the page plugs into;
mplbed's `head_content`. Calling it is optional — the first fragment emits
the bootstrap itself if it hasn't been placed yet — but templates that embed
several apps should put it once near the top (browsers relocate the wrapper
into `<body>` when placed in `<head>`; script order is preserved). Returns
`""` outside a request scope, where fragments are self-contained.
"""
function head_content(; context::Union{Nothing, BonnieContext} = nothing)
    page = CURRENT_PAGE[]
    isnothing(page) && return ""
    return page_root_html(@something(context, current_context()), page)
end

"""
    default_app_page_template(; head = "", title = "", body = "") -> String

Minimal standalone HTML page wrapping `body` (typically [`app_html`](@ref)
output). A `template` keyword with this signature can be passed to
[`app_page`](@ref)/[`app_page_html`](@ref).
"""
function default_app_page_template(; head::String = "", title::String = "", body::String = "")
    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$(escape_html(title))</title>
    $(head)
    </head>
    <body>
    $(body)
    </body>
    </html>
    """
end

"""
    iframe_for(path; width = "100%", height = "400") -> String

Iframe snippet pointing at a route that serves an [`app_page`](@ref)
(mplbed's `iframe_for`). `Bonnie.Safe.iframe_for` returns it pre-trusted for
HTML templating macros.
"""
function iframe_for(path::AbstractString; width = "100%", height = "400")
    return "<iframe src=\"$(escape_html(path))\" width=\"$(escape_html(string(width)))\" " *
           "height=\"$(escape_html(string(height)))\" frameborder=\"0\"></iframe>"
end

"""
    app_page_html(app::App; context = current_context(),
                  template = default_app_page_template, title = app.title) -> String

Full standalone HTML page for one Bonito app, as a string.
"""
function app_page_html(app::App; context::BonnieContext = current_context(),
                       template = default_app_page_template,
                       title::String = app.title)
    return template(; head = head_content(; context), title = title,
                    body = app_html(app; context = context))
end

app_page_html(f::Function; kw...) = app_page_html(App(f); kw...)
