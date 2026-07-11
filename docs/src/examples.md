# Examples

All examples live in [`examples/`](https://github.com/frankier/Bonnie.jl/tree/main/examples),
honour a `PORT` environment variable, and can be either run as scripts or
`include`d (call `main(; port)` for a closeable handle).

## Raw HTTP.jl (`examples/http/`, run with `--project=.`)

- **`basic.jl`** — one slider app via `app_page`, plus a `/probe` route
  exposing the last slider value the server saw.
- **`embed_raw.jl`** — two apps embedded as fragments in a hand-written
  template via `head_content` + `app_html` (one shared websocket, each app a
  subsession).
- **`mount_app.jl`** — `manage_routing = false`: the host owns an
  `HTTP.Router` and mounts Bonnie's sub-router itself via `Bonnie.dispatch`.
- **`interactive.jl`** — server push: a `Timer` updates an `Observable` and
  every connected page follows.

## Oxygen (`examples/oxygen/`, run with `--project=examples/oxygen`)

- **`basic.jl`** — `setup!(Val(:oxygen))` + `app_page` + `/probe`.
- **`templates.jl`** — fragment embedding and `iframe_for` under Oxygen.

## WGLMakie (`examples/wglmakie/`, run with `--project=examples/wglmakie`)

- **`streaming.jl`** — a figure with both interactivity (button-driven
  counter) and 1 Hz server push into a lines plot; the per-session ticker is
  tied to `session.on_close`.
