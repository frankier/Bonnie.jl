"""
    Bonnie.Safe

Variants of the HTML helpers returning `HTML(...)` wrappers (Base's trusted
markup type) instead of `String`, for interpolation into HTML templating
macros such as HypertextLiteral's `@htl` — which escape plain strings but
splice `text/html`-showable objects verbatim. Mirrors mplbed's `html/safe.py`
markupsafe wrappers.
"""
module Safe

import ..Bonnie

app_html(args...; kw...) = HTML(Bonnie.app_html(args...; kw...))
app_page_html(args...; kw...) = HTML(Bonnie.app_page_html(args...; kw...))
head_content(; kw...) = HTML(Bonnie.head_content(; kw...))
iframe_for(args...; kw...) = HTML(Bonnie.iframe_for(args...; kw...))
figure_html(args...; kw...) = HTML(Bonnie.figure_html(args...; kw...))
figure_page_html(args...; kw...) = HTML(Bonnie.figure_page_html(args...; kw...))

end # module
