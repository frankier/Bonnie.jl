# Smoke-test scaffolding (port of mplbed's conftest.py): the example table,
# free-port/port-wait helpers and the two launch modes. Subprocess mode is the
# faithful mplbed port (fresh julia per example, PORT env var, SIGTERM + reap,
# child output dumped on failure); in-process mode includes the example into
# an anonymous module and calls its main(; port) for a fast dev loop —
# select with ENV["BONNIE_SMOKE_MODE"] = "subprocess" (default) | "inprocess".

using Sockets

struct ExampleSpec
    id::String
    path::String              # relative to the package root
    routes::Vector{String}    # all must answer 200; "/" must mention the prefix
end

const EXAMPLE_SPECS = [
    ExampleSpec("basic", "examples/http/basic.jl", ["/", "/probe"]),
    ExampleSpec("embed_raw", "examples/http/embed_raw.jl", ["/"]),
    ExampleSpec("mount_app", "examples/http/mount_app.jl", ["/"]),
    ExampleSpec("interactive", "examples/http/interactive.jl", ["/", "/probe"]),
]

pkg_root() = pkgdir(Bonnie)

function free_port()
    server = Sockets.listen(Sockets.InetAddr(Sockets.ip"127.0.0.1", 0))
    _, port = Sockets.getsockname(server)
    close(server)
    return Int(port)
end

function wait_port(port; timeout = 180.0, alive = () -> true)
    deadline = time() + timeout
    while time() < deadline
        alive() || return false
        try
            close(Sockets.connect("127.0.0.1", port))
            return true
        catch
            sleep(0.2)
        end
    end
    return false
end

function check_routes(base::String, spec::ExampleSpec)
    for route in spec.routes
        resp = HTTP.get(base * route; status_exception = false, retry = false)
        @test resp.status == 200
        body = String(resp.body)
        @test !isempty(body)
        # Pages must have been rendered through Bonnie (prefix in asset URLs).
        route == "/" && @test occursin("/bonito/assets/", body)
    end
end

function smoke_subprocess(spec::ExampleSpec)
    root = pkg_root()
    port = free_port()
    logfile = tempname()
    cmd = addenv(
        Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$root $(joinpath(root, spec.path))`;
            dir = root),
        "PORT" => string(port))
    proc = run(pipeline(cmd; stdout = logfile, stderr = logfile); wait = false)
    ok = false
    try
        up = wait_port(port; alive = () -> process_running(proc))
        @test up
        if up
            check_routes("http://127.0.0.1:$port", spec)
            @test process_running(proc)
            ok = true
        end
    finally
        if process_running(proc)
            kill(proc)                       # SIGTERM
            reaper = Timer(10) do _
                process_running(proc) && kill(proc, Base.SIGKILL)
            end
            wait(proc)
            close(reaper)
        end
        if !ok
            @error "example $(spec.id) failed; child output follows" exitcode = proc.exitcode
            isfile(logfile) && print(stderr, read(logfile, String))
        end
    end
end

function smoke_inprocess(spec::ExampleSpec)
    port = free_port()
    mod = Module(Symbol("BonnieExample_", spec.id))
    Base.include(mod, joinpath(pkg_root(), spec.path))
    example_main = Base.invokelatest(getglobal, mod, :main)
    handle = Base.invokelatest(example_main; port)
    try
        check_routes("http://127.0.0.1:$port", spec)
    finally
        foreach(close, handle)
    end
end
