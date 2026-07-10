# Oxygen extension tests: extension loads, setup! registers working routes
# through Oxygen's API, the middleware scopes the Bonnie context, and the
# websocket roundtrip works end-to-end through an Oxygen server.

import Oxygen

@testset "Oxygen extension" begin
    @test Base.get_extension(Bonnie, :BonnieOxygenExt) !== nothing

    bonnie = Bonnie.setup!(Val(:oxygen))
    @test bonnie.prefix == "/bonito"
    @test bonnie.context isa BonnieContext
    @test bonnie.app === Oxygen

    last_value = Bonito.Observable(0)
    slider_value = Ref{Any}(nothing)
    native_app = Ref{Any}(nothing)

    Oxygen.get("/") do req::HTTP.Request
        native_app[] = get_native_app()
        return app_page(App() do
            slider = Bonito.Slider(1:10)
            slider_value[] = slider.value
            Bonito.on(v -> last_value[] = v, slider.value)
            return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
        end)
    end

    port = free_port()
    server = Oxygen.serve(; port, middleware = [bonnie.middleware],
                          async = true, show_banner = false)
    base = "http://127.0.0.1:$port"

    try
        # Page renders through the middleware-scoped context
        resp = HTTP.get("$base/")
        body = String(resp.body)
        @test resp.status == 200
        @test occursin("/bonito/assets/", body)
        @test native_app[] === Oxygen
        @test length(bonnie.context.sessions) == 1
        session = Bonnie.lookup(bonnie.context.sessions,
                                only(keys(bonnie.context.sessions.entries)))
        @test occursin(session.id, body)

        # Assets served through the Oxygen-registered route
        asset_urls = unique(m.match for m in eachmatch(r"/bonito/assets/[A-Za-z0-9._%-]+", body))
        @test !isempty(asset_urls)
        for u in asset_urls
            @test HTTP.get("$base$u"; status_exception = false).status == 200
        end
        @test HTTP.get("$base/bonito/assets/deadbeef-x.js"; status_exception = false).status == 404

        # Websocket roundtrip through the Oxygen-registered WEBSOCKET route
        WebSockets.open("ws://127.0.0.1:$port/bonito/ws/$(session.id)") do ws
            WebSockets.send(ws, client_message(session, Dict{String, Any}(
                "msg_type" => Bonito.JSDoneLoading,
                "exception" => "nothing",
                "session" => session.id,
            )))
            @test wait_for(() -> Bonito.isready(session; throw = false))

            obs_id = nothing
            for (id, entry) in session.session_objects
                obj = entry isa Bonito.CachedEntry ? entry.object : entry
                obj === slider_value[] && (obs_id = id)
            end
            @test obs_id !== nothing
            WebSockets.send(ws, client_message(session, Dict{String, Any}(
                "msg_type" => Bonito.UpdateObservable,
                "id" => obs_id,
                "payload" => 5,
            )))
            @test wait_for(() -> last_value[] == 5)
        end
        @test wait_for(() -> length(bonnie.context.sessions) == 0)
    finally
        close(server)
        close(bonnie.context.sessions)
    end
end
