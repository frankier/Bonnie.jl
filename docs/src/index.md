# Bonnie.jl

Bonnie embeds interactive, server-side [Bonito.jl](https://github.com/SimonDanisch/Bonito.jl)
apps (including WGLMakie figures) in web applications built on
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) 2.x — **without Bonito opening
its own port**. The host server serves Bonito's assets and the per-session
websocket under a prefix (default `/bonito`), so one port, one auth story,
one reverse-proxy config. It mirrors the structure of
[mplbed](https://github.com/frankier/mplbed/) (the same idea for matplotlib
WebAgg figures).

## Quickstart: raw HTTP.jl

```julia
using HTTP, Bonito, Bonnie

function index(req)
    return app_page(App() do
        slider = Bonito.Slider(1:10)
        Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

# Wraps the handler: mounts the Bonito sub-router at the prefix and scopes
# the Bonnie context per request. listen! (not serve): the middleware is a
# stream handler so it can upgrade the /bonito/ws/<session-id> websockets.
mw = bonnie_middleware(index)
server = HTTP.listen!(mw, "127.0.0.1", 8080)
wait(server)
```

## Quickstart: Oxygen.jl

```julia
using Oxygen, Bonito, Bonnie

bonnie = Bonnie.setup!(Val(:oxygen))   # registers the asset + websocket routes

@get "/" function (req)
    app_page(App() do
        Bonito.Card(Bonito.Slider(1:10))
    end)
end

serve(middleware = [bonnie.middleware])
```

Pass an `Oxygen.instance()` module as `app` to `setup!` for instance mode.
Oxygen currently needs the HTTP 2.x fork branch declared in Bonnie's
`[sources]`.

## Quickstart: WGLMakie

With WGLMakie loaded, `figure_page`/`figure_html` accept a figure directly:

```julia
using WGLMakie, Bonnie   # + the HTTP.jl or Oxygen setup above

@get "/plot" function (req)
    figure_page(WGLMakie.lines(cumsum(randn(100))))
end
```

## Embedding in your own templates

`app_html` returns a fragment; `head_content` returns the page-level
bootstrap it plugs into. Every app on a page is a subsession of one per-page
root session sharing a single websocket, so any number of apps can coexist:

```julia
function index(req)
    body = """
    <!doctype html><html><head>$(head_content())</head><body>
    <h1>Two apps</h1>
    $(app_html(app_a()))
    $(app_html(app_b()))
    $(iframe_for("/plot"))
    </body></html>
    """
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"]; body)
end
```

`Bonnie.Safe.*` variants return `HTML(...)`-wrapped (pre-trusted) markup for
templating macros such as HypertextLiteral's `@htl`.

## Session lifecycle

Every rendered page registers a session. Sessions whose browser never
connects are closed after `session_ttl` (default 300 s); on websocket
disconnect a session is soft-closed and can be resumed for
`reconnect_window` (default 30 s). Both are keywords of
`bonnie_middleware`/`bonnie_router_factory`/`setup!`, and any
`Bonito.CleanupPolicy` can be substituted.
