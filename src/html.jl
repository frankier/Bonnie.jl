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

"""
    app_html(app::App; context = current_context()) -> String

HTML fragment (session init + DOM) for one Bonito app, for embedding in a
caller-owned template/page. The session registers itself during render so the
host server can complete the websocket handshake. Also callable as
`app_html(f::Function; kw...)` with `f() -> App`.

The fragment is self-contained: Bonito inlines its script imports, styles and
the connection bootstrap into the fragment itself (imports are ES modules, so
browsers deduplicate them across several fragments on one page). See also
[`head_content`](@ref).
"""
function app_html(app::App; context::BonnieContext = current_context())
    session = bonnie_session(context; title = app.title)
    dom = Bonito.session_dom(session, app)
    return sprint(io -> show(io, MIME"text/html"(), dom))
end

app_html(f::Function; kw...) = app_html(App(f); kw...)

"""
    head_content(; core = false) -> String

Script/link tags the page `<head>` needs. Currently empty: unlike matplotlib's
WebAgg, Bonito emits self-contained fragments (see [`app_html`](@ref)), so
there is nothing that must go in the head. Kept as the stable API point for
template users, mirroring mplbed's `head_content`.
"""
head_content(; core::Bool = false) = ""

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
    app_page_html(app::App; context = current_context(),
                  template = default_app_page_template, title = app.title) -> String

Full standalone HTML page for one Bonito app, as a string.
"""
function app_page_html(app::App; context::BonnieContext = current_context(),
                       template = default_app_page_template,
                       title::String = app.title)
    return template(; head = head_content(), title = title,
                    body = app_html(app; context = context))
end

app_page_html(f::Function; kw...) = app_page_html(App(f); kw...)
