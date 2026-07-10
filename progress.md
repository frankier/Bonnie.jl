# Bonnie.jl — progress

Tracks implementation state against `plan.md`'s suggested order.

## Step 1: spike — DONE (2026-07-09)

Compat check + minimal `EmbeddedConnection`/`EmbeddedAssetServer` rendering a
slider app through a hand-rolled HTTP.jl server. Verified end-to-end by
`Pkg.test()` (20 assertions) and `examples/http/spike_slider.jl`.

### What exists

```
Project.toml                 # deps: Bonito 5.1, HTTP 2.4+; julia 1.11+; Test target
src/Bonnie.jl                # module, exports
src/registry.jl              # SessionRegistry / AssetRegistry (lock-guarded dicts)
src/connection.jl            # EmbeddedConnection + setup_connection + ws handler
src/assets.jl                # EmbeddedAssetServer + asset GET responder
src/spike_server.jl          # BonnieState, app_page, hand-rolled HTTP.listen! server
test/runtests.jl             # canary test: full client-side exercise of the spike
examples/http/spike_slider.jl
```

- `EmbeddedConnection <: Bonito.FrontendConnection` wraps Bonito's own
  `WebSocketHandler`; the host server upgrades `GET <prefix>/ws/<session-id>`
  and calls `Bonnie.handle_websocket`, which runs
  `Bonito.run_connection_loop` (feeds `session.inbox`; per-session processing
  is naturally serial). `setup_connection` returns a JS snippet that builds an
  absolute proxy URL from `window.location` + prefix (Bonito's `Websocket.js`
  does `proxy_url.replace("http","ws") + "/" + session_id`; relative URLs
  would depend on newer-browser `new WebSocket` behaviour).
- `EmbeddedAssetServer <: Bonito.AbstractAssetServer` registers assets under
  `Bonito.unique_file_key` (content-addressed) and emits
  `<prefix>/assets/<key>` URLs; serving reuses `Bonito.serve_asset` (Range,
  If-Modified-Since, cache-control profiles).
- `app_page(state, app)` = `Session(EmbeddedConnection; asset_server=EmbeddedAssetServer)`
  + `Bonito.page_html` → `HTTP.Response`. Session registers itself during
  render (via `setup_connection`).
- Spike lifecycle policy: session closed + deregistered immediately on ws
  disconnect; sessions that never connect are leaked until step 2's TTL
  sweeper. `Base.similar(::EmbeddedAssetServer)` returns itself (no
  per-session refcounting yet — Bonito's `ChildAssetServer` is the model).

### Bonito internals we rely on (plan trouble area 2 — pin Bonito tightly)

Non-exported surface used: `WebSocketHandler`, `run_connection_loop`,
`is_current_socket`, `setup_connection`, `page_html`, `session_dom`,
`unique_file_key`, `is_online`/`online_path`/`local_path`/`file_mimetype`,
`serve_asset`, `cache_control_for`, `bundle_data_snapshot`, message-protocol
constants (`JSDoneLoading`, `UpdateObservable`), `MsgPack`/gzip wire format
(plain msgpack from client; `serialize_binary` is server-side only and wraps
in msgpack extensions). `test/runtests.jl` is the canary that should break
first if a Bonito release moves any of this.

### Verification

- `julia --project=. -e 'import Pkg; Pkg.test()'` → 20/20 pass (~21 s).
- Example: `PORT=8210 julia --project=. examples/http/spike_slider.jl` then
  `curl localhost:8210/` → doc page with `/bonito/assets/...` script tags.
- Browser-driven e2e is deliberately deferred to step 5.

## Step 2: core package — DONE (2026-07-10)

`spike_server.jl`/`BonnieState` dissolved into the planned layout; verified by
`Pkg.test()` (79 assertions: unit + canary) and an in-process smoke run of
`examples/http/spike_slider.jl`.

### What exists

```
src/consts.jl        # DEFAULT_PREFIX, target_path, escape_html
src/registry.jl      # SessionRegistry (TTL sweeper) + AssetRegistry
src/connection.jl    # EmbeddedConnection (+ mark_connected!, close-cycle guard)
src/assets.jl        # EmbeddedAssetServer (unchanged from spike)
src/router.jl        # BonnieRouter, bonnie_router_factory, dispatch,
                     #   url_path_for(router, ...), status page (auth-gated)
src/context.jl       # BonnieContext, CURRENT_CONTEXT/CURRENT_NATIVE_APP
                     #   ScopedValues, current_context, with_bonnie,
                     #   url_path_for, MissingBonnieContext
src/middleware.jl    # bonnie_middleware -> BonnieMiddleware, callable on both
                     #   HTTP.Request and HTTP.Stream; ws upgrade handling
src/html.jl          # bonnie_session, app_html, head_content (empty — Bonito
                     #   fragments are self-contained), app_page_html,
                     #   default_app_page_template
src/pages.jl         # app_page (App and closure call styles)
src/safe.jl          # Bonnie.Safe: HTML(...) wrappers (Base HTML suffices;
                     #   no HypertextLiteral dep needed — @htl splices
                     #   text/html-showable objects verbatim)
src/Bonnie.jl        # module, exports, setup! extension stubs
test/runtests.jl     # shared helpers + includes
test/test_unit.jl    # context/url_path_for, html/pages, TTL sweeper,
                     #   registry concurrency, request-level dispatch, stubs
test/test_canary.jl  # spike e2e test ported to the middleware API
```

### Design notes / deviations from plan

- **Websocket upgrade needs a stream handler** (HTTP 2.5:
  `WebSockets.upgrade(f, stream)`, HTTP/1.1 only). `BonnieMiddleware` is
  therefore callable both as a request handler (context scoping + sub-router
  dispatch; ws paths answer 426) and as a stream handler (performs the
  upgrade). Serve with `HTTP.listen!(mw, host, port)`, not `HTTP.serve`.
- **`head_content()` returns `""`**: Bonito `session_dom` fragments carry
  their own imports/styles/init inline (plan trouble area 3's accepted
  outcome); ES-module imports dedupe across fragments in the browser. The
  function stays as the stable API point.
- **`Bonnie.Safe` uses Base `HTML`** instead of a HypertextLiteral dep —
  `@htl` splices `text/html`-showable objects verbatim, so no new dependency.
- Lifecycle: never-connected sessions swept after `session_ttl` (default
  300 s; sweeper timer starts on first registration, stops when registry
  empties); connected sessions closed immediately on ws disconnect (no
  soft-close/reconnect window yet). `close(mw)` = shutdown (stops sweeper,
  closes sessions).
- The ws prefix does not appear as literal text in rendered HTML (it is
  msgpack-serialized into the init bundle), so prefix-propagation tests
  assert on asset URLs; the canary's ws roundtrip covers the ws URL.
- Oxygen remains a hard dep in Project.toml for now (dev install of
  HTTP-2.x-compatible Oxygen 1.10.2 preserved for step 4); the
  weakdeps/extension migration happens in step 4 together with
  `ext/BonnieOxygenExt.jl`. `setup!(Val(:oxygen))` stub errors with guidance.

## Step 3: examples + smoke harness — DONE (2026-07-10)

Verified by `Pkg.test()` (103 assertions, ~75 s: unit + canary + subprocess
smoke of all four examples).

- `examples/http/`: `basic.jl` (spike_slider renamed; slider + `/probe`
  route exposing the last slider value for later e2e), `embed_raw.jl` (two
  fragments in a caller-owned template via `app_html`/`head_content`),
  `mount_app.jl` (`manage_routing = false`, sub-router mounted on an
  `HTTP.Router` at `GET /bonito/**` via `Bonnie.dispatch`), `interactive.jl`
  (server-push: a `Timer` bumps an Observable all pages follow). Every
  example honours `PORT`, guards serving behind
  `abspath(PROGRAM_FILE) == @__FILE__`, and returns a closeable handle from
  `main(; port)` so it can be `include`d in-process.
- `test/conftest.jl`: `ExampleSpec` table, free-port/port-wait helpers, and
  the two launch modes — subprocess (fresh `julia --project=<root>` with
  `PORT` env, port poll, per-route GETs, process-alive check, SIGTERM +
  10 s SIGKILL reaper, child output dumped on failure) and in-process
  (include into an anonymous module + `main(; port)`; ~27 s for all four).
  `test/test_smoke.jl` selects via `ENV["BONNIE_SMOKE_MODE"]`
  ("subprocess" default | "inprocess").
- Sockets (stdlib) added to test extras/target.

## Step 4: Oxygen extension — DONE (2026-07-11)

Verified by `Pkg.test()` (137 assertions incl. extension tests + oxygen
example smoke as subprocesses).

- `ext/BonnieOxygenExt.jl`: `setup!(Val(:oxygen); app::Module = Oxygen, ...)`
  registers `WS <prefix>/ws/{session_id}` + `GET <prefix>/assets/{key}`
  (+ auth-gated `/status`) through Oxygen's function API and returns
  `(; middleware, context, router, prefix, app)`. Passing an
  `Oxygen.instance()` module as `app` covers instance mode — Oxygen's
  route functions register on the calling module's `CONTEXT[]`, so the
  module *is* the natural dispatch handle (no `Oxygen.Context` method
  needed). Oxygen performs the ws upgrade itself for WEBSOCKET routes
  (from `req.context[:stream]`), so no stream-level middleware on this
  path.
- Project.toml: Oxygen moved to `[weakdeps]`/`[extensions]`, added to test
  extras; `[sources]` pins Oxygen to the `frankier/Oxygen.jl` fork branch
  `http-2` (released Oxygen still caps HTTP at 1.x), which makes local
  resolve and CI both use the HTTP 2.x port.
- `iframe_for` landed in core `html.jl` (+ `Safe.iframe_for`) rather than
  the extension — it is plain HTML with no Oxygen types to dispatch on.
- `examples/oxygen/{basic,templates}.jl` with own Project.toml
  (`[sources]`: Bonnie by path, Oxygen by fork URL); smoke harness gained
  per-spec `project` envs, instantiates them on first use, and scrubs the
  Pkg.test sandbox `JULIA_LOAD_PATH` from subprocess launches.
- `test/test_oxygen.jl` (runs when the env provides Oxygen): extension
  loads, routes work end-to-end incl. ws roundtrip, `get_native_app()`
  returns the Oxygen module inside handlers.
- Gotchas hit: `HTTP.WebSocket` is `HTTP.WebSockets.WebSocket` in 2.x;
  `html` is exported by both Oxygen and Bonito (qualify in user code).

## Step 5: WGLMakie extension — DONE (2026-07-11)

Verified by the standalone canary (12 assertions, `julia
--project=examples/wglmakie test/test_wglmakie.jl`), an in-process smoke of
the streaming example, and the unchanged main suite (137).

- `ext/BonnieMakieExt.jl` (weakdep WGLMakie 0.13): `figure_page` /
  `figure_html` / `figure_page_html` on `Makie.FigureLike` =
  `app_page(App(fig))` etc.; stubs + exports + `Safe` variants in core.
  No connection/asset changes were needed — WGLMakie rides on Bonito as
  predicted.
- `test/test_wglmakie.jl`: canary asserting the WGLMakie ES module is
  registered/served through the prefix (>10 kB body) and the init
  handshake reaches ready (fails if the big binary scene bundle can't be
  serialized/served). Self-bootstrapping: runs standalone under
  `examples/wglmakie` env or from runtests when the env has WGLMakie.
  Shared test helpers factored into `test/helpers.jl`.
- `examples/wglmakie/streaming.jl` (own env, Bonnie via `[sources]` path):
  port of Oxygen PR #212's demo — button-driven counter + 1 Hz server-push
  into a lines plot — with the per-session ticker closed via
  `session.on_close` (the PR's bare `@async` loop leaked). Smoke spec is
  opt-in via `BONNIE_SMOKE_WGLMAKIE=1`.

## Steps 6–7 — NOT STARTED

Registry soft-close/reconnect hardening; e2e/CI/docs.
