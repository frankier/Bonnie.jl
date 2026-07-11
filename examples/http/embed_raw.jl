# Embedding app fragments in a caller-owned template (mirror of mplbed's
# embed2_raw.py): two independent apps on one page via app_html +
# head_content, instead of the app_page one-liner.
#
#     julia --project=. examples/http/embed_raw.jl

using Bonito, Bonnie, HTTP

function slider_app()
    return App() do
        slider = Bonito.Slider(1:10)
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end
end

function handler(req::HTTP.Request)
    Bonnie.target_path(req.target) == "/" || return HTTP.Response(404)
    html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>Bonnie embed_raw</title>
    $(head_content())
    </head>
    <body>
    <h1>Two embedded apps</h1>
    <p>head_content carries the shared bootstrap; each app is a subsession
    of one per-page root session sharing a single websocket.</p>
    $(app_html(slider_app()))
    <hr>
    $(app_html(slider_app()))
    </body>
    </html>
    """
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"]; body = html)
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    mw = bonnie_middleware(handler)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    @info "Bonnie example running" url = "http://127.0.0.1:$(port)/"
    return (; server, mw)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
