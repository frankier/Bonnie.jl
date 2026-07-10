# Smoke-test scaffolding (port of mplbed's conftest.py): the example table,
# free-port/port-wait helpers and the two launch modes. Subprocess mode is the
# faithful mplbed port (fresh julia per example, PORT env var, SIGTERM + reap,
# child output dumped on failure); in-process mode includes the example into
# an anonymous module and calls its main(; port) for a fast dev loop —
# select with ENV["BONNIE_SMOKE_MODE"] = "subprocess" (default) | "inprocess".

struct ExampleSpec
    id::String
    path::String              # relative to the package root
    routes::Vector{String}    # all must answer 200; "/" must mention the prefix
    project::String           # env to run under (relative to root); "." = root
end
ExampleSpec(id, path, routes) = ExampleSpec(id, path, routes, ".")

const EXAMPLE_SPECS = [
    ExampleSpec("basic", "examples/http/basic.jl", ["/", "/probe"]),
    ExampleSpec("embed_raw", "examples/http/embed_raw.jl", ["/"]),
    ExampleSpec("mount_app", "examples/http/mount_app.jl", ["/"]),
    ExampleSpec("interactive", "examples/http/interactive.jl", ["/", "/probe"]),
    ExampleSpec("oxygen_basic", "examples/oxygen/basic.jl", ["/", "/probe"], "examples/oxygen"),
    ExampleSpec("oxygen_templates", "examples/oxygen/templates.jl", ["/", "/plot"], "examples/oxygen"),
    # WGLMakie is heavy (long install + startup): smoke runs it only with
    # BONNIE_SMOKE_WGLMAKIE=1, e2e with BONNIE_E2E_WGLMAKIE=1 (CI jobs do).
    ExampleSpec("wglmakie_streaming", "examples/wglmakie/streaming.jl",
                ["/", "/probe"], "examples/wglmakie"),
]

smoke_enabled(spec::ExampleSpec) =
    spec.id != "wglmakie_streaming" || get(ENV, "BONNIE_SMOKE_WGLMAKIE", "") == "1"

pkg_root() = pkgdir(Bonnie)

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

# Launch `spec` as a subprocess, wait for its port and run `f(base_url)`
# against it; SIGTERM + reap on the way out, dumping child output if `f`
# threw or the server never came up. Shared by the smoke and e2e suites.
function with_example(f, spec::ExampleSpec)
    root = pkg_root()
    port = free_port()
    logfile = tempname()
    project = spec.project == "." ? root : joinpath(root, spec.project)
    # Pkg.test runs us inside a sandbox env whose JULIA_LOAD_PATH must not
    # leak into example subprocesses; reset it to the default.
    scrub(cmd) = addenv(cmd, "JULIA_LOAD_PATH" => "@:@v#.#:@stdlib", "PORT" => string(port))
    if project != root
        # Example envs ([sources]-based) need instantiating on first use;
        # cheap once the depot is warm.
        instantiate = scrub(Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$project
                                 -e 'import Pkg; Pkg.instantiate()'`; dir = root))
        instproc = run(pipeline(ignorestatus(instantiate); stdout = logfile, stderr = logfile))
        if !success(instproc)
            @error "instantiating $(spec.project) failed; output follows"
            print(stderr, read(logfile, String))
            @test success(instproc)
            return
        end
    end
    cmd = scrub(
        Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(root, spec.path))`;
            dir = root))
    proc = run(pipeline(cmd; stdout = logfile, stderr = logfile); wait = false)
    ok = false
    try
        up = wait_port(port; alive = () -> process_running(proc))
        @test up
        if up
            f("http://127.0.0.1:$port")
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

smoke_subprocess(spec::ExampleSpec) = with_example(base -> check_routes(base, spec), spec)

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
