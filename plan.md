# Bonnie.jl — plan

`Bonnie.jl` is a library of support code for embedding interactive, server-side
[Bonito.jl](https://github.com/SimonDanisch/Bonito.jl) apps in web applications
built on [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) (2.x series), mirroring
the structure of [mplbed](https://github.com/frankier/mplbed/):

| mplbed (Python)                          | Bonnie.jl (Julia)                                  |
|------------------------------------------|----------------------------------------------------|
| matplotlib WebAgg figures                | Bonito.jl `App`s                                   |
| ASGI middleware (`MplbedMiddleware`)     | HTTP.jl handler wrapper (`bonnie_middleware`)      |
| `contextvars.ContextVar`                 | `Base.ScopedValues.ScopedValue`                    |
| Starlette sub-app (`mplbed_app_factory`) | HTTP.jl sub-router (`bonnie_router_factory`)       |
| Flask/Quart + Starlette integrations     | Oxygen.jl integration (package extension)          |
| `webaggext` custom mpl backend           | custom Bonito `FrontendConnection` + asset server  |
| Python decorators (`@figure_page`)       | higher-order functions (`app_page(f)`)             |

Like mplbed, the aim is "usually-works" defaults for quick demos, plus enough
hooks (prefix control, bring-your-own-router, connection/session management)
to scale to internal-dashboard use.

## Architecture overview

mplbed's job is to bolt matplotlib's WebAgg protocol (static assets + one
websocket per figure + download endpoints) onto a host web app, and to give
view functions a one-liner to turn a figure into a page. Bonito already *is* a
web framework with its own `Bonito.Server`, so Bonnie's job shifts slightly:
instead of embedding a foreign GUI protocol, Bonnie makes Bonito render into a
host HTTP.jl server **without Bonito opening its own port**. Concretely:

1. **Rendering**: a handler builds a `Bonito.App`; Bonnie renders it to HTML
   via a `Bonito.Session` configured with Bonnie's own connection and asset
   server (below), registers the session in a registry, and returns the HTML
   (standalone page or fragment for template inclusion).
2. **Serving**: Bonnie mounts a sub-router under a prefix (default
   `/bonito`) on the host server that serves (a) Bonito's JS/CSS/binary
   assets and (b) the per-session websocket endpoint. This is the analogue of
   mplbed's `mplbed_app_factory` Starlette sub-app.
3. **Context plumbing**: a middleware (handler wrapper) sets ScopedValues for
   the current prefix, sub-router, and native app so that `figure`/page
   helpers and `url_path_for` work without threading arguments through user
   code — the analogue of mplbed's `MplbedMiddleware` + ContextVars.

### Bonito internals we build on

Bonito is designed for pluggable backends via two interfaces, both of which we
implement rather than reusing the `Bonito.Server`-bound defaults:

- **`EmbeddedConnection <: Bonito.FrontendConnection`** — like
  `Bonito.WebSocketConnection`, but instead of registering a route on a
  `Bonito.Server`, it parks itself in Bonnie's session registry keyed by
  session id and waits for the host server to hand it an upgraded
  `HTTP.WebSocket`. Implements the documented connection interface:
  `Base.write(::EmbeddedConnection, bytes)`, `Base.isopen`, `Base.close`,
  `Bonito.setup_connection(session)` (returns the JS snippet that opens the
  websocket back to `<prefix>/ws/<session-id>`).
- **`EmbeddedAssetServer <: Bonito.AbstractAssetServer`** — like
  `Bonito.HTTPAssetServer`, but generates URLs under `<prefix>/assets/...`
  and registers the asset bytes/files in a registry served by Bonnie's
  sub-router. Implements `Bonito.url(server, asset)`,
  `Bonito.import_in_js(...)`, `Bonito.setup_asset_server(...)`.

This is the moral equivalent of mplbed's `webaggext` backend: the piece that
redirects the toolkit's client/server chatter through URLs we control.

## User-level API

### Core (framework-agnostic, HTTP.jl only)

```julia
using HTTP, Bonito, Bonnie

function index(req)
    app = App() do
        slider = Slider(1:10)
        DOM.div(slider, DOM.div(slider.value))
    end
    return app_page(app)          # -> HTTP.Response, full HTML page
end

router = HTTP.Router()
HTTP.register!(router, "GET", "/", index)

# Wrap the top-level handler: mounts the Bonito sub-router at `prefix` and
# sets the ScopedValue context for every request.
handler = bonnie_middleware(router; prefix = "/bonito")
HTTP.serve(handler, "127.0.0.1", 8080)
```

Core vocabulary (all mirroring mplbed's `html`/`integration.common` split):

- `app_page(app; template = default_app_page_template) -> HTTP.Response` —
  full standalone HTML page for one Bonito app. Also callable as
  `app_page(f::Function; kw...)` where `f() -> App`, the closure style.
- `app_html(app; ...) -> String` — HTML fragment (session init + DOM) for
  embedding in a caller-owned template; mplbed's `figure_html`.
- `head_content(; core = false) -> String` — script/link tags the page
  `<head>` needs (Bonito JS, styles); mplbed's `head_content`.
- `app_page_html(app; template) -> String` — full page as a string;
  mplbed's `figure_page_html`.
- `default_app_page_template(; head, title, body) -> String`.
- `url_path_for(name; params...)` — resolves named routes of the Bonnie
  sub-router (`:ws`, `:assets`) against the current prefix from scope.
- `Bonnie.Safe.app_html` / `Bonnie.Safe.head_content` — variants returning
  `HypertextLiteral.Result` (pre-escaped/trusted markup) for use inside
  `@htl` templates, mirroring mplbed's `html/safe.py` markupsafe wrappers.

No decorators in Julia, so mplbed's two decorator usages become the two call
styles above: pass the `App` directly (view style computes it first), or pass
a zero-arg closure returning an `App` (closure style). No sync/async variant
explosion is needed — Julia handlers are just functions and Bonito manages its
own tasks — which deletes mplbed's whole `mk_figure_page_variants` machinery.

### Oxygen.jl integration (package extension)

Oxygen is an optional dependency (`weakdeps` + `extensions` in Project.toml).
Target user experience:

```julia
using Oxygen, Bonito, Bonnie

bonnie = Bonnie.setup!(Val(:oxygen); prefix = "/bonito")
# registers GET <prefix>/assets/**, WS <prefix>/ws/{session}, and returns a
# handle carrying the middleware + config

@get "/" function(req)
    app_page(App() do
        Card(Slider(1:10))
    end)
end

serve(middleware = [bonnie.middleware])
```

What `setup!` does (mirror of mplbed's per-framework `setup()`):

1. **Route registration** (`manage_routing = true` default): registers the
   asset route and websocket route through Oxygen's own API
   (`Oxygen.get`/`Oxygen.websocket` function forms, not macros), so Oxygen's
   docs page, metrics and middleware see them. With
   `manage_routing = false` the user mounts `bonnie_router` themselves.
2. **Middleware**: returns (and by default relies on the user installing) an
   Oxygen middleware `handler -> handler` that scopes the ScopedValues per
   request — same body as `bonnie_middleware`, minus the routing.
3. **Backend configuration**: sets Bonnie's `EmbeddedConnection` /
   `EmbeddedAssetServer` as the defaults used by `app_page`/`app_html`
   (mirror of mplbed's `do_use_mpl_backend`).

Keyword surface mirrors mplbed: `prefix`, `manage_routing`,
`do_install_middleware`, `do_configure_backend`, plus
`context = Oxygen.CONTEXT[]`-style targeting for Oxygen's `instance()` /
multi-app mode.

Also in the extension:

- `iframe_for(path; width, height)` — iframe snippet helper.
- `app_page` methods returning whatever Oxygen prefers (it accepts
  `HTTP.Response` directly, so likely no-op specialisation; kept as an
  extension point mirroring `_mk_quart_response`).

**Extension dispatch problem** (see trouble areas): extensions can only add
methods to existing functions, and much of Oxygen's API is module-level
(global default app) rather than type-based, so there is no natural argument
type to dispatch on for `setup!()`. Plan: define stubs in the core package —
`setup!(::Val{:oxygen}; kw...)` and `setup!(ctx; kw...)` — with a fallback
error message ("load Oxygen to enable the integration"); the extension
overrides `setup!(::Val{:oxygen}; ...)` (module-level Oxygen app) and
`setup!(::Oxygen.Context; ...)` (instance mode). A `Val`-less alias
`setup_oxygen!` can be added for discoverability.

## Implementation details

### ScopedValues instead of ContextVars

mplbed uses `ContextVar`s (`_native_app`, `_prefix_and_app`) set by the
middleware for the duration of a request. The Julia analogue is
`Base.ScopedValues` (Julia ≥ 1.11; the `ScopedValues.jl` compat package if we
want 1.8–1.10 — proposal: require Julia 1.11+ and skip the dependency):

```julia
# src/context.jl
using Base.ScopedValues

struct BonnieContext
    prefix::String
    router::BonnieRouter        # the sub-router, for url_path_for
    session_registry::SessionRegistry
end

const CURRENT_CONTEXT = ScopedValue{Union{BonnieContext, Nothing}}(nothing)
const CURRENT_NATIVE_APP = ScopedValue{Any}(nothing)   # Oxygen context, etc.

function bonnie_middleware(handler; prefix = DEFAULT_PREFIX, router = nothing, kw...)
    ctx = BonnieContext(prefix, something(router, bonnie_router_factory(; kw...)), ...)
    return function (req::HTTP.Request)
        with(CURRENT_CONTEXT => ctx) do
            if startswith(req.target, prefix)   # manage_routing
                return dispatch(ctx.router, req)
            end
            handler(req)
        end
    end
end

current_context() = @something CURRENT_CONTEXT[] throw(MissingBonnieContext())
get_native_app()  = CURRENT_NATIVE_APP[]
```

Notes:

- `with(...) do` establishes dynamic scope exactly like
  `ContextVar.set(...)` context managers; any `Task` spawned inside the
  scope **inherits** the values (snapshot at task creation), matching
  asyncio's copy-on-task semantics — so Bonito tasks spawned during
  rendering see the right context.
- **Do not read ScopedValues lazily from long-lived objects.** The websocket
  handler and Bonito session callbacks run *outside* the originating
  request's scope. Everything the session needs later (prefix, registry)
  must be captured eagerly into the `EmbeddedConnection` /
  `EmbeddedAssetServer` at render time. mplbed has the same pattern
  (`_prefix_and_app` is only read while a request is in flight; the manager
  dict is global).
- ScopedValues are immutable per scope — fine, we never mutate mid-request.

### The sub-router (mirror of `server/impl.py`)

`bonnie_router_factory(; kw...) -> BonnieRouter`, a small named-route table on
top of `HTTP.Router` so `url_path_for` can work by name:

- `GET <prefix>/assets/{key}` → serve registered Bonito assets
  (content-addressed like `HTTPAssetServer`: key = `<hash>-<filename>`, so
  caching headers can be aggressive/immutable). Name: `:assets`.
- `GET/upgrade <prefix>/ws/{session_id}` → websocket upgrade; look up the
  pending `EmbeddedConnection` in the session registry, attach the
  `HTTP.WebSocket`, then run the receive loop feeding
  `Bonito.process_message(session, bytes)`. On close: mark connection
  closed, schedule session cleanup. Name: `:ws`.
- `GET <prefix>/status` → optional status page (session count, uptime),
  gated behind `enable_status_page` + mandatory `status_page_auth` callable,
  mirroring mplbed's `MplPageAuth`.

Session registry (mirror of mplbed's `managers` dict, but done properly since
mplbed flags this as its own scaling story):

- `Dict{String, SessionEntry}` guarded by a `ReentrantLock` (HTTP.jl serves
  requests on arbitrary threads/tasks).
- TTL sweeper task for sessions that render a page but never connect
  (user closed the tab before JS ran) — Bonito's `CleanupPolicy` is tied to
  its own server, so we own this.
- Close/`Bonito.free` sessions on websocket disconnect.

### HTML module (mirror of `html/`)

`app_html(app)` does, in order: build `Session(EmbeddedConnection(registry),
asset_server = EmbeddedAssetServer(ctx))`; `Bonito.session_dom(session, app)`
(or `show(io, MIME"text/html"(), ...)` route — whichever Bonito API is stable
for "render app to HTML against an explicit session"); register session;
return HTML string. `head_content` returns the Bonito setup scripts that
`session_dom` would put in `<head>` so template users can place them
explicitly — needs a look at how Bonito splits head/body; if Bonito insists on
inline setup, `head_content(core = true)` may be nearly empty and the fragment
self-contained, which is fine and simpler than mplbed's situation.

### Package layout

```
Bonnie.jl/
├── Project.toml                 # deps: Bonito, HTTP (2.x), HypertextLiteral
│                                # weakdeps: Oxygen; extensions: BonnieOxygenExt
├── src/
│   ├── Bonnie.jl                # module, exports, extension stubs (setup!, ...)
│   ├── consts.jl                # DEFAULT_PREFIX = "/bonito", etc.
│   ├── context.jl               # ScopedValues, BonnieContext, url_path_for,
│   │                            #   get_native_app          (≈ asgi.py)
│   ├── middleware.jl            # bonnie_middleware          (≈ asgi.py)
│   ├── router.jl                # BonnieRouter, bonnie_router_factory,
│   │                            #   asset/ws/status handlers (≈ server/impl.py)
│   ├── registry.jl              # SessionRegistry, locking, TTL sweeper
│   │                            #                            (≈ server/utils.py + managers)
│   ├── connection.jl            # EmbeddedConnection         (≈ webaggext/)
│   ├── assets.jl                # EmbeddedAssetServer        (≈ webaggext/)
│   ├── html.jl                  # app_html, head_content, app_page_html,
│   │                            #   default_app_page_template (≈ html/impl.py+raw.py)
│   ├── safe.jl                  # Bonnie.Safe: HypertextLiteral wrappers
│   │                            #                            (≈ html/safe.py)
│   └── pages.jl                 # app_page / app_standalone call styles
│                                #                            (≈ integration/common.py)
├── ext/
│   └── BonnieOxygenExt.jl       # setup!, install_middleware!, register_routes!,
│                                #   iframe_for               (≈ integration/quart.py)
├── examples/
│   ├── http/                    # raw HTTP.jl examples       (≈ examples/starlette/)
│   │   ├── embed_raw.jl         # ≈ embed2_raw.py: manual head_content + template
│   │   ├── mount_app.jl         # ≈ mount_app.py: manage_routing=false
│   │   └── interactive.jl      # ≈ draw_idle.py: server-push via Observables
│   └── oxygen/
│       ├── basic.jl             # ≈ quart/basic.py: setup! + app_page
│       └── templates.jl         # iframe_for + fragment embedding
├── test/
│   ├── runtests.jl
│   ├── conftest.jl              # example specs, subprocess launch, port wait
│   ├── test_unit.jl
│   ├── test_smoke.jl
│   └── test_e2e.jl
├── docs/                        # Documenter.jl: index, api, examples
├── .github/workflows/           # tests.yml, qa.yml, docs.yml (mirror mplbed CI)
└── README.md
```

## Trouble areas (flagged now)

1. **HTTP.jl 2.x ecosystem compat — the biggest risk.** Bonito and Oxygen
   both depend on HTTP.jl with their own `[compat]` bounds. If either still
   caps at HTTP 1.x, we cannot co-install with HTTP 2.x at all (Julia
   resolver picks one version per environment). **First task of
   implementation: check released compat bounds of Bonito and Oxygen against
   HTTP 2.x**; if Bonito lags, either contribute the compat bump upstream or
   temporarily target the HTTP version Bonito supports and isolate all
   HTTP-API touchpoints (router, websocket upgrade, streaming) in
   `router.jl`/`middleware.jl` so the 2.x port is one file. The websocket
   upgrade API is the part most likely to have changed between 1.x and 2.x.
2. **Bonito's private-ish embedding surface.** `FrontendConnection` /
   `AbstractAssetServer` are designed for extension (Pluto/Jupyter/Electron
   all do this), but the exact hooks (`setup_connection`, `session_dom`,
   `process_message`, asset key scheme) are not all committed public API and
   have churned between Bonito releases. Pin a tight `[compat]` on Bonito,
   add a canary unit test that renders a trivial app through our connection,
   and upstream anything we need made public.
3. **Head/body split.** mplbed cleanly separates `head_content` from the
   figure fragment. Bonito's `session_dom` produces a self-contained blob;
   extracting head-only content for the template-integration story may
   require reaching into rendering internals or accepting that fragments
   carry their own setup scripts (duplicate-inclusion guards needed when a
   page embeds several apps — Bonito subsessions may already solve this;
   investigate `Session` parent/child before rolling our own).
4. **Oxygen extension ergonomics.** (a) No type to dispatch on for the
   default module-level app → `Val(:oxygen)` stubs as described above.
   (b) Oxygen's macro API (`@get`) registers into a global context at macro
   expansion relative to `Oxygen`; the extension must use the function API
   (`Oxygen.get(path, handler)` / websocket equivalent) so it works from
   within an extension module and against `instance()` apps. (c) Oxygen
   wraps/instruments handlers (docs generation, metrics) — verify a raw
   websocket route registered by us doesn't get broken by its middleware
   pipeline, and that `serve(middleware=[...])` ordering puts our scope
   around user handlers.
5. **Websocket upgrade inside a middleware-managed prefix.** When
   `manage_routing = true` we intercept `<prefix>/ws/...` in the middleware
   before the host router sees it, and must perform the upgrade ourselves.
   Whether a plain request handler can upgrade (vs. needing to be registered
   as a websocket route with the host server) differs between raw HTTP.jl
   and Oxygen — this is why the Oxygen path registers a real websocket route
   instead of relying on the middleware (`manage_routing` effectively
   defaults to "register real routes" there).
6. **Concurrency.** HTTP.jl handlers run concurrently on multiple
   tasks/threads; Bonito sessions assume messages for one session are
   processed in order. Serialise per-session message processing (one
   receive-loop task per connection is naturally serial; guard cross-session
   registry access with the lock; document that one `App` closure may run
   concurrently across requests).
7. **Session lifecycle / leakage.** Every page render creates a session that
   holds observables and assets. Without the TTL sweeper (registry above),
   crawlers hitting pages without running JS leak memory — mplbed has the
   same issue with `managers` and we should do better from day one.
8. **World-age / extension load order.** `setup!` called before `using
   Oxygen` hits the stub error — make the message actionable. Also ensure
   the extension doesn't get loaded into precompile-broken states: keep
   `BonnieOxygenExt` free of top-level side effects.

## Testing plan (mirroring mplbed)

mplbed's suite = example-driven smoke tests (subprocess + port poll + GET) and
Playwright e2e tests (find every figure, interact, assert the canvas visibly
changed). Bonnie mirrors this:

### 1. Unit tests (`test_unit.jl`) — no browser, fast

- ScopedValue plumbing: `url_path_for` inside/outside `bonnie_middleware`
  scope (outside must throw `MissingBonnieContext`); prefix propagation into
  generated HTML (ws URL, asset URLs contain the prefix).
- `app_html`/`app_page_html` render a trivial `App`; output contains the
  session id, a `<script>`, and registry gains exactly one entry.
- Registry: TTL sweep removes never-connected sessions; disconnect frees the
  session; concurrent register/remove under `Threads.@spawn` hammering.
- Asset routes: request a registered asset → 200 + right content-type;
  unknown key → 404. Websocket route with unknown session id → 4xx.
- In-process roundtrip without a browser: open a client-side
  `HTTP.WebSockets.open` against a served test app, replay the connection
  handshake Bonito's JS would do, assert an `Observable` update is pushed
  down the wire. (This is the cheap stand-in for most e2e coverage.)
- Extension: with Oxygen loaded, `Base.get_extension(Bonnie,
  :BonnieOxygenExt) !== nothing`; `setup!(Val(:oxygen))` registers the
  expected routes; without Oxygen (separate test env), stubs throw the
  guidance error and the core test suite passes — proving Oxygen is truly
  optional.
- `Aqua.jl` (ambiguities, stale deps, piracy) as the qa-workflow analogue of
  ruff/ty.

### 2. Smoke tests (`test_smoke.jl`) — examples as subprocesses

Port of `conftest.py`/`test_smoke.py`:

- `ExampleSpec(id, path, routes)` table covering every file in `examples/`;
  each example honours a `PORT` env var (mirror of the `script` kind; no
  daphne analogue needed since Julia examples self-serve).
- Launch with `run(setenv(`julia --project=examples $file`, "PORT" => p))`
  as a detached process, poll the port with `Sockets.connect` until
  deadline, GET each route with HTTP.jl, assert 200 and non-trivial body,
  assert the process is still alive, then SIGTERM + reap. Capture and dump
  child output on failure exactly as mplbed does.
- Keep a shared depot/precompile cache in CI or these will dominate runtime
  (Julia startup ≠ Python startup — see note below).

### 3. End-to-end browser tests (`test_e2e.jl`, tagged, opt-in like `-m e2e`)

The mplbed e2e test pans each figure and asserts pixels changed. The Bonito
analogue: **drive a widget and assert the DOM/server state round-trips** —
that proves JS loaded from our asset route, the websocket connected through
our route, and messages flow both ways.

- Driver: headless Chromium. Options, in order of preference:
  `ChromeDevToolsLite.jl` / `Blink`-free CDP driving from Julia, or shell
  out to Node Playwright (what mplbed effectively does via pytest-playwright)
  with a small JS runner reading a route list. Decide during implementation;
  keep the assertion helpers driver-agnostic.
- Per example route: load page; wait for Bonito's "connection open" marker
  (Bonito exposes a JS-side connected state — else poll for absence of its
  "disconnected" banner); for each embedded app: click the test button /
  move the slider rendered by the example; assert (a) a DOM node's text
  updates (client←server roundtrip) and (b) the server-side `Observable`
  saw the value (exposed by the example via a `/probe` route, giving us a
  stronger assertion than mplbed's pixel-diff).
- Multi-app page example: two apps on one page must both connect (guards
  the duplicate-head-content trouble area #3).
- Iframe example (`iframe_for`): find the app inside the iframe, same
  roundtrip — mirrors mplbed's iframe traversal.

### CI (mirror mplbed's three workflows)

- `tests.yml`: matrix over Julia (min supported = 1.11 for ScopedValues,
  1.x latest) × unit+smoke; separate job with browser install for e2e;
  `julia-actions/cache` for depot. A dedicated job runs the core test suite
  in an env **without Oxygen installed**.
- `qa.yml`: Aqua + JuliaFormatter check + (optionally) JET.
- `docs.yml`: Documenter build + deploy to gh-pages, with `docs/api.md`
  and `docs/examples.md` mirroring mplbed's docs layout.

### Testing risk note

Julia subprocess startup + package load per example is tens of seconds, not
milliseconds; mplbed's launch-a-fresh-process-per-example pattern is ported
but examples should be written to also be `include`-able into an existing
process (guard the `serve` call behind `abspath(PROGRAM_FILE) == @__FILE__`),
so the smoke suite can optionally run them in-process with `HTTP.serve!` on
port 0 for a fast dev loop, keeping true subprocess isolation for CI.

## Suggested implementation order

1. Spike: compat check (HTTP 2.x × Bonito × Oxygen) + minimal
   `EmbeddedConnection`/`EmbeddedAssetServer` rendering one slider app
   through a hand-rolled HTTP.jl server (de-risks trouble areas 1–3).
2. Core package: context/middleware/router/registry/html/pages + unit tests.
3. Examples (`examples/http/`) + smoke harness.
4. Oxygen extension + `examples/oxygen/` + extension tests.
5. E2E harness, CI workflows, docs.
