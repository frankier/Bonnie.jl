# WGLMakie integration: WGLMakie already renders through Bonito (an `App`
# containing a figure renders via WGLMakie's jsrender), so Bonnie's
# connection/asset/lifecycle layer needs no changes — this extension only
# provides the mplbed-vocabulary conveniences dispatching on FigureLike.

module BonnieMakieExt

using Bonnie, WGLMakie
using WGLMakie: Makie
using Bonito: App

Bonnie.figure_page(fig::Makie.FigureLike; kw...) = Bonnie.app_page(App(fig); kw...)
Bonnie.figure_html(fig::Makie.FigureLike; kw...) = Bonnie.app_html(App(fig); kw...)
Bonnie.figure_page_html(fig::Makie.FigureLike; kw...) = Bonnie.app_page_html(App(fig); kw...)

end # module
