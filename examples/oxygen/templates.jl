# Template embedding under Oxygen (mirror of mplbed's quart templates
# example): "/" embeds one app as a fragment in a caller-owned template plus
# a second app through an iframe; "/plot" is the iframed standalone page.
#
#     julia --project=. examples/oxygen/templates.jl

using Oxygen, Bonito, Bonnie, HTTP

const BONNIE = Bonnie.setup!(Val(:oxygen))

function slider_app()
    return App() do
        slider = Bonito.Slider(1:10)
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end
end

@get "/" function (req::HTTP.Request)
    page = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>Bonnie Oxygen templates</title>
    $(head_content())
    </head>
    <body>
    <h1>Embedded fragment</h1>
    $(app_html(slider_app()))
    <h1>Iframed page</h1>
    $(iframe_for("/plot"; height = 120))
    </body>
    </html>
    """
    # `html` is exported by both Oxygen and Bonito, so qualify it.
    return Oxygen.html(page)
end

@get "/plot" function (req::HTTP.Request)
    return app_page(slider_app())
end

function main(; port = parse(Int, get(ENV, "PORT", "8081")))
    server = serve(; port, middleware = [BONNIE.middleware], async = true,
                   show_banner = false)
    @info "Bonnie Oxygen example running" url = "http://127.0.0.1:$(port)/"
    return (; server)
end

if abspath(PROGRAM_FILE) == @__FILE__
    handle = main()
    wait(handle.server)
end
