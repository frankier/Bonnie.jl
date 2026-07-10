# WGLMakie canary (plan step 5): render a figure through Bonnie's
# EmbeddedConnection/EmbeddedAssetServer, assert the WGLMakie ES module is
# registered and served through the prefix, and that the init handshake
# completes — the heavier sibling of test_canary.jl, exercising the
# es6-module asset path and much larger init payloads.
#
# Runs standalone against the WGLMakie example env:
#
#     julia --startup-file=no --project=examples/wglmakie test/test_wglmakie.jl
#
# or as part of runtests.jl when the test env provides WGLMakie.

if !@isdefined(wait_for)
    using Test
    using Bonito, Bonnie, HTTP
    using HTTP.WebSockets
    include("helpers.jl")
end

import WGLMakie
using WGLMakie: Makie

@testset "WGLMakie canary: figure end-to-end" begin
    @test Base.get_extension(Bonnie, :BonnieMakieExt) !== nothing
    WGLMakie.activate!()

    ys = Bonito.Observable(collect(1.0:4.0))

    function handler(req::HTTP.Request)
        Bonnie.target_path(req.target) == "/" || return HTTP.Response(404)
        fig = Makie.lines(ys)
        return figure_page(fig)
    end

    port = free_port()
    mw = bonnie_middleware(handler; reconnect_window = 0)
    server = HTTP.listen!(mw, "127.0.0.1", port)
    base = "http://127.0.0.1:$port"

    try
        resp = HTTP.get("$base/"; request_timeout = 120)
        body = String(resp.body)
        @test resp.status == 200
        @test occursin("/bonito/assets/", body)
        @test length(mw.ctx.sessions) == 1
        session = Bonnie.lookup(mw.ctx.sessions, only(keys(mw.ctx.sessions.entries)))
        @test occursin(session.id, body)

        # The WGLMakie ES module must be registered with Bonnie's asset
        # server and served through the prefix.
        wgl_keys = filter(k -> occursin(r"wglmakie"i, k), collect(keys(mw.ctx.assets.assets)))
        @test !isempty(wgl_keys)
        for key in wgl_keys
            asset_resp = HTTP.get("$base/bonito/assets/$key"; status_exception = false)
            @test asset_resp.status == 200
            @test length(asset_resp.body) > 10_000    # the real module, not a stub
        end

        # Handshake: after JSDoneLoading the session must go ready without
        # errors — this fails if the (large, binary) init bundle for the
        # scene graph could not be serialized/served.
        WebSockets.open("ws://127.0.0.1:$port/bonito/ws/$(session.id)") do ws
            WebSockets.send(ws, client_message(session, Dict{String, Any}(
                "msg_type" => Bonito.JSDoneLoading,
                "exception" => "nothing",
                "session" => session.id,
            )))
            @test wait_for(() -> Bonito.isready(session; throw = false); timeout = 30)
            @test isopen(session)

            # Server-push down our websocket: an observable update on the
            # figure data doesn't throw with a connected session.
            ys[] = collect(4.0:-1.0:1.0)
            @test isopen(session)
        end
        @test wait_for(() -> length(mw.ctx.sessions) == 0)
    finally
        close(server)
        close(mw)
    end
end
