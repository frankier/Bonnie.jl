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

## Step 3: examples + smoke harness — NOT STARTED

`examples/http/spike_slider.jl` was ported to the middleware API and smoke-
checked in-process, but the ExampleSpec subprocess harness and the further
examples (embed_raw, mount_app, interactive) remain.

## Steps 4–5 — NOT STARTED

Oxygen extension (dev Oxygen 1.10.2 with HTTP 2.x support is installed);
e2e/CI/docs.
