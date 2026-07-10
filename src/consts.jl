const DEFAULT_PREFIX = "/bonito"

# HTTP 2.x no longer re-exports URIs.URI; we only ever need the path, so
# strip the query/fragment by hand instead of pulling in a URIs dependency.
target_path(target::AbstractString) = String(first(split(target, ('?', '#'); limit = 2)))

escape_html(s::AbstractString) =
    replace(s, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")
