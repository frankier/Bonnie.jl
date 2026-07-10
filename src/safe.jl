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

end # module
