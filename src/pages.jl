# app_page call styles (mirror of mplbed's integration/common.py). Julia has
# no decorators, so mplbed's two decorator usages become two call styles:
# pass the App directly, or pass a zero-arg closure returning an App.

"""
    app_page(app::App; status = 200, headers = [], kw...) -> HTTP.Response

Full standalone HTML page for one Bonito app, as an `HTTP.Response`. Must run
with a Bonnie context in scope (inside `bonnie_middleware`, or pass
`context = ctx` explicitly). Remaining keywords (`context`, `template`,
`title`) go to [`app_page_html`](@ref). Also callable as
`app_page(f::Function; kw...)` with `f() -> App`.
"""
function app_page(app::App; status::Integer = 200, headers = Pair{String, String}[], kw...)
    html = app_page_html(app; kw...)
    return HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8", headers...];
                         body = html)
end

app_page(f::Function; kw...) = app_page(App(f); kw...)
