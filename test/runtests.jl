# Canary test for plan step 1 (see plan.md "Trouble areas" #2): renders a
# slider app through Bonnie's EmbeddedConnection/EmbeddedAssetServer on a
# hand-rolled HTTP.jl server, then exercises the page, asset and websocket
# routes as a client — including Bonito's connection handshake and an
# observable update in each direction. If a Bonito release changes the
# embedding surface (setup_connection, process_message, asset key scheme,
# message protocol), this is the test that should break first.
using Test
using Bonito, Bonnie, HTTP
using HTTP.WebSockets

const LAST_VALUE = Bonito.Observable(0)
const SLIDER_VALUE = Ref{Any}(nothing)
const STATE = Ref{Any}(nothing)

function index(req::HTTP.Request)
    Bonnie.target_path(req.target) == "/" || return HTTP.Response(404)
    return app_page(STATE[].state, App() do
        slider = Bonito.Slider(1:10)
        SLIDER_VALUE[] = slider.value
        Bonito.on(v -> LAST_VALUE[] = v, slider.value)
        return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
    end)
end

# The browser side of Bonito's protocol: plain msgpack, gzipped only if the
# session negotiated compression. (Bonito.serialize_binary is the *server*
# encoder and wraps payloads in msgpack extensions process_message rejects.)
function client_message(session, msg::AbstractDict)
    bytes = Bonito.MsgPack.pack(msg)
    session.compression_enabled && (bytes = Bonito.transcode(Bonito.GzipCompressor, bytes))
    return bytes
end

function wait_for(f; timeout = 10.0)
    deadline = time() + timeout
    while !f() && time() < deadline
        sleep(0.05)
    end
    return f()
end

@testset "spike: slider app end-to-end" begin
    port = 8199
    STATE[] = serve_spike(index; port = port)
    state = STATE[].state
    base = "http://127.0.0.1:$port"

    # Page render through EmbeddedConnection/EmbeddedAssetServer
    resp = HTTP.get("$base/")
    body = String(resp.body)
    @test resp.status == 200
    @test startswith(body, "<!doctype html>")
    @test occursin("<script", body)
    @test occursin("/bonito/assets/", body)
    @test length(state.sessions) == 1
    session = first(values(lock(() -> copy(state.sessions.sessions), state.sessions.lock)))
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
            obj === SLIDER_VALUE[] && (obs_id = id)
        end
        @test obs_id !== nothing
        WebSockets.send(ws, client_message(session, Dict{String, Any}(
            "msg_type" => Bonito.UpdateObservable,
            "id" => obs_id,
            "payload" => 7,
        )))
        @test wait_for(() -> LAST_VALUE[] == 7)

        # server -> client: a push down our websocket doesn't throw
        @test (Bonito.evaljs(session, Bonito.js"console.log('spike test')"); true)
    end

    # Disconnect closes the session and empties the registry (spike policy)
    @test wait_for(() -> length(state.sessions) == 0)
    @test !isopen(session)

    close(STATE[].server)
end
