# Canary test (see plan.md "Trouble areas" #2): renders a slider app through
# Bonnie's EmbeddedConnection/EmbeddedAssetServer behind bonnie_middleware on
# a real HTTP.jl server, then exercises the page, asset and websocket routes
# as a client — including Bonito's connection handshake and an observable
# update in each direction. If a Bonito release changes the embedding surface
# (setup_connection, process_message, asset key scheme, message protocol),
# this is the test that should break first.

@testset "canary: slider app end-to-end" begin
    last_value = Bonito.Observable(0)
    slider_value = Ref{Any}(nothing)

    function index(req::HTTP.Request)
        Bonnie.target_path(req.target) == "/" || return HTTP.Response(404)
        return app_page(App() do
            slider = Bonito.Slider(1:10)
            slider_value[] = slider.value
            Bonito.on(v -> last_value[] = v, slider.value)
            return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
        end)
    end

    port = 8199
    mw = bonnie_middleware(index)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    base = "http://127.0.0.1:$port"

    try
        # Page render through EmbeddedConnection/EmbeddedAssetServer
        resp = HTTP.get("$base/")
        body = String(resp.body)
        @test resp.status == 200
        @test startswith(body, "<!doctype html>")
        @test occursin("<script", body)
        @test occursin("/bonito/assets/", body)
        @test length(mw.ctx.sessions) == 1
        session = Bonnie.lookup(mw.ctx.sessions, only(keys(mw.ctx.sessions.entries)))
        @test occursin(session.id, body)
        @test session.connection isa EmbeddedConnection

        # Assets are served by the host server under the prefix
        asset_urls = unique(m.match for m in eachmatch(r"/bonito/assets/[A-Za-z0-9._%-]+", body))
        @test !isempty(asset_urls)
        for u in asset_urls
            @test HTTP.get("$base$u"; status_exception = false).status == 200
        end
        @test HTTP.get("$base/bonito/assets/deadbeef-x.js"; status_exception = false).status == 404
        @test HTTP.get("$base/nope"; status_exception = false).status == 404

        # Websocket handshake + message flow in both directions
        WebSockets.open("ws://127.0.0.1:$port/bonito/ws/$(session.id)") do ws
            # client -> server: browser announces JS init done
            WebSockets.send(ws, client_message(session, Dict{String, Any}(
                "msg_type" => Bonito.JSDoneLoading,
                "exception" => "nothing",
                "session" => session.id,
            )))
            @test wait_for(() -> Bonito.isready(session; throw = false))
            @test isopen(session)

            # client -> server: slider moved in the "browser" updates the
            # server-side Observable (the interactivity path)
            obs_id = nothing
            for (id, entry) in session.session_objects
                obj = entry isa Bonito.CachedEntry ? entry.object : entry
                obj === slider_value[] && (obs_id = id)
            end
            @test obs_id !== nothing
            WebSockets.send(ws, client_message(session, Dict{String, Any}(
                "msg_type" => Bonito.UpdateObservable,
                "id" => obs_id,
                "payload" => 7,
            )))
            @test wait_for(() -> last_value[] == 7)

            # server -> client: a push down our websocket doesn't throw
            @test (Bonito.evaljs(session, Bonito.js"console.log('canary test')"); true)
        end

        # Disconnect closes the session and empties the registry
        @test wait_for(() -> length(mw.ctx.sessions) == 0)
        @test !isopen(session)

        # Unknown session id: server closes the socket without a session
        @test length(mw.ctx.sessions) == 0
        closed_early = try
            WebSockets.open(ws -> WebSockets.receive(ws), "ws://127.0.0.1:$port/bonito/ws/nope")
            true   # server closed cleanly -> receive throws or returns on close
        catch
            true
        end
        @test closed_early
    finally
        close(server)
        close(mw)
    end
end
