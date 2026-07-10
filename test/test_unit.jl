# Unit tests for the step 2 core: ScopedValue plumbing, url_path_for, the
# html/pages split, registry TTL sweeping and the request-level sub-router.
# No server, no browser (the in-process server + websocket roundtrip lives in
# test_canary.jl).

@testset "context and url_path_for" begin
    # Outside any Bonnie scope everything context-dependent must throw.
    @test_throws MissingBonnieContext current_context()
    @test_throws MissingBonnieContext url_path_for(:ws; session_id = "x")
    @test_throws MissingBonnieContext app_html(slider_app())

    router = bonnie_router_factory()
    ctx = BonnieContext(router)
    with_bonnie(ctx) do
        @test current_context() === ctx
        @test url_path_for(:ws; session_id = "abc") == "/bonito/ws/abc"
        @test url_path_for(:assets; key = "k.js") == "/bonito/assets/k.js"
        @test url_path_for(:status) == "/bonito/status"
        @test_throws ArgumentError url_path_for(:nope)
        @test_throws ArgumentError url_path_for(:ws)                      # missing param
        @test_throws ArgumentError url_path_for(:ws; session_id = "x", bogus = 1)
        # Scope inherits into spawned tasks (Bonito render tasks rely on this).
        @test fetch(Threads.@spawn url_path_for(:status)) == "/bonito/status"
    end
    @test_throws MissingBonnieContext current_context()   # scope ended
    @test get_native_app() === nothing

    # Custom prefix propagates; bad prefixes rejected.
    ctx2 = BonnieContext(bonnie_router_factory(; prefix = "/custom/bonito"))
    with_bonnie(() -> @test(url_path_for(:status) == "/custom/bonito/status"), ctx2)
    @test_throws ArgumentError bonnie_router_factory(; prefix = "nope")
    @test_throws ArgumentError bonnie_router_factory(; prefix = "/nope/")
    @test_throws ArgumentError bonnie_router_factory(; prefix = "/")
end

@testset "app_html / app_page_html / app_page" begin
    ctx = BonnieContext(bonnie_router_factory(; prefix = "/embed"))
    with_bonnie(ctx) do
        @test length(ctx.sessions) == 0
        frag = app_html(slider_app())
        @test length(ctx.sessions) == 1
        session = Bonnie.lookup(ctx.sessions, only(keys(ctx.sessions.entries)))
        @test occursin(session.id, frag)
        @test occursin("<script", frag)
        # Prefix propagates into asset URLs. (The ws URL is interpolated into
        # the serialized init bundle, not the HTML text — the canary's
        # websocket roundtrip covers it.)
        @test occursin("/embed/assets/", frag)
        @test !occursin("<html", frag)                  # fragment, not a page

        page = app_page_html(slider_app; title = "T<itle")
        @test length(ctx.sessions) == 2
        @test startswith(page, "<!doctype html>")
        @test occursin("<title>T&lt;itle</title>", page)
        @test occursin("/embed/assets/", page)

        # Custom template receives head/title/body.
        custom = app_page_html(slider_app();
            template = (; head, title, body) -> "H:$(head)|T:$(title)|B:$(length(body))")
        @test startswith(custom, "H:|T:")

        resp = app_page(slider_app(); status = 201)
        @test resp isa HTTP.Response
        @test resp.status == 201
        @test HTTP.header(resp, "Content-Type") == "text/html; charset=utf-8"
        @test occursin("/embed/assets/", String(resp.body))

        @test Bonnie.Safe.app_html(slider_app()) isa HTML
        @test head_content() == ""
        @test iframe_for("/plot"; height = 120) ==
              "<iframe src=\"/plot\" width=\"100%\" height=\"120\" frameborder=\"0\"></iframe>"
        @test Bonnie.Safe.iframe_for("/plot") isa HTML
    end
    close(ctx.sessions)
end

@testset "registry TTL sweeper" begin
    sessions = Bonnie.SessionRegistry(; ttl = 0.3, sweep_interval = 0.1)
    ctx = BonnieContext(bonnie_router_factory(; sessions))
    app_html(slider_app(); context = ctx)
    @test length(sessions) == 1
    @test !isnothing(sessions.sweeper)
    session = Bonnie.lookup(sessions, only(keys(sessions.entries)))
    # Never-connected session is swept after the TTL and closed...
    @test wait_for(() -> length(sessions) == 0; timeout = 5)
    @test session.status == Bonito.CLOSED
    # ...and the sweeper stops itself once the registry empties.
    @test wait_for(() -> isnothing(sessions.sweeper); timeout = 5)

    # A connected session survives the TTL.
    app_html(slider_app(); context = ctx)
    id = only(keys(sessions.entries))
    Bonnie.mark_connected!(sessions, id)
    sleep(0.6)
    @test length(sessions) == 1
    close(sessions)
    @test length(sessions) == 0
end

@testset "registry concurrency" begin
    sessions = Bonnie.SessionRegistry(; ttl = 60)
    @sync for _ in 1:8
        Threads.@spawn for _ in 1:50
            s = Session(EmbeddedConnection(sessions))
            Bonnie.register!(sessions, s)
            Bonnie.mark_connected!(sessions, s.id)
            @test Bonnie.lookup(sessions, s.id) === s
            Bonnie.remove!(sessions, s.id)
        end
    end
    @test length(sessions) == 0
    close(sessions)
end

@testset "middleware request-level dispatch" begin
    hits = Ref(0)
    mw = bonnie_middleware(; prefix = "/bonito", status_page_auth = req -> HTTP.header(req, "X-Auth") == "letmein") do req
        hits[] += 1
        # The app handler runs inside the Bonnie scope.
        @test current_context() === mw.ctx
        return HTTP.Response(200, "app")
    end

    # Outside the prefix: falls through to the app handler.
    @test String(mw(HTTP.Request("GET", "/")).body) == "app"
    @test hits[] == 1
    # Prefix collision rules: /bonitofoo is NOT ours, /bonito (bare) is.
    @test String(mw(HTTP.Request("GET", "/bonitofoo")).body) == "app"
    @test mw(HTTP.Request("GET", "/bonito")).status == 404

    # Assets: registered key served, unknown key 404.
    page = with_bonnie(() -> app_page_html(slider_app()), mw.ctx)
    asset_path = match(r"/bonito/assets/[A-Za-z0-9._%-]+", page).match
    @test mw(HTTP.Request("GET", String(asset_path))).status == 200
    @test mw(HTTP.Request("GET", "/bonito/assets/deadbeef-x.js")).status == 404

    # Websocket route at request level: 426 (needs the stream middleware).
    @test mw(HTTP.Request("GET", "/bonito/ws/some-session")).status == 426

    # Status page: auth required.
    @test mw(HTTP.Request("GET", "/bonito/status")).status == 403
    ok = mw(HTTP.Request("GET", "/bonito/status", ["X-Auth" => "letmein"]))
    @test ok.status == 200
    @test occursin("sessions: 1", String(ok.body))

    # Status page disabled entirely without an auth callable.
    mw2 = bonnie_middleware(req -> HTTP.Response(200))
    @test mw2(HTTP.Request("GET", "/bonito/status")).status == 404

    close(mw)
    close(mw2)
end

@testset "setup! stubs" begin
    @test_throws ErrorException setup!(Val(:oxygen))
    @test_throws ErrorException setup!(Val(:starlette))
end
