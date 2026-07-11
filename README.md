# Bonnie.jl

Embed interactive, server-side [Bonito.jl](https://github.com/SimonDanisch/Bonito.jl)
apps — including WGLMakie figures — in web applications built on
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) 2.x, **without Bonito opening
its own port**. The host server serves Bonito's assets and per-session
websockets under a prefix (default `/bonito`): one port, one auth story, one
reverse-proxy config. Mirrors the structure of
[mplbed](https://github.com/frankier/mplbed/).

```julia
using HTTP, Bonito, Bonnie

index(req) = app_page(App() do
    slider = Bonito.Slider(1:10)
    Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
end)

server = HTTP.listen!(bonnie_middleware(index), "127.0.0.1", 8080)
wait(server)
```

Also ships an [Oxygen.jl](https://github.com/OxygenFramework/Oxygen.jl)
integration (`Bonnie.setup!(Val(:oxygen))`, package extension) and
`figure_page`/`figure_html` for WGLMakie figures. See `docs/` and
`examples/` for the full story: template embedding (`app_html` +
`head_content`, multiple apps per page over one websocket), iframes,
bring-your-own-router, session lifecycle (TTL sweeping +
soft-close/reconnect via Bonito's `CleanupPolicy`).

Status: pre-release. Bonito is pinned tightly (canary tests cover the
non-public embedding surface); Oxygen support currently requires the HTTP 2.x
fork branch declared in `[sources]`.
