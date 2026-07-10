# Minimal Chrome DevTools Protocol client for the e2e suite: launch headless
# Chrome, open pages via the /json HTTP endpoints, and run JS through
# Runtime.evaluate over the page's debugger websocket. Driver-agnostic
# assertion helpers live in test_e2e.jl (plan: keep them separable in case
# the driver is ever swapped for Playwright).

using JSON3

function chrome_executable()
    for candidate in (get(ENV, "CHROME_BIN", ""), "google-chrome",
                      "google-chrome-stable", "chromium", "chromium-browser")
        isempty(candidate) && continue
        path = Sys.which(candidate)
        isnothing(path) || return path
    end
    return nothing
end

struct ChromeBrowser
    proc::Base.Process
    port::Int
end

function launch_chrome()
    exe = chrome_executable()
    isnothing(exe) && error("no Chrome/Chromium executable found (set CHROME_BIN)")
    port = free_port()
    cmd = `$exe --headless=new --disable-gpu --no-sandbox --disable-dev-shm-usage
           --user-data-dir=$(mktempdir()) --remote-debugging-port=$port about:blank`
    proc = run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
    up = wait_for(; timeout = 60) do
        process_running(proc) || return true   # fail fast below
        try
            HTTP.get("http://127.0.0.1:$port/json/version"; retry = false).status == 200
        catch
            false
        end
    end
    (up && process_running(proc)) || error("headless Chrome failed to start")
    return ChromeBrowser(proc, port)
end

function Base.close(browser::ChromeBrowser)
    process_running(browser.proc) && kill(browser.proc)
    wait(browser.proc)
    return
end

mutable struct CdpPage
    ws::Any
    next_id::Int
end

"""
    with_page(f, browser, url)

Open `url` in a fresh tab and run `f(page::CdpPage)`; the tab is closed
afterwards.
"""
function with_page(f, browser::ChromeBrowser, url::String)
    devtools = "http://127.0.0.1:$(browser.port)"
    target = JSON3.read(HTTP.request("PUT", "$devtools/json/new?$url").body)
    try
        WebSockets.open(String(target.webSocketDebuggerUrl)) do ws
            f(CdpPage(ws, 0))
        end
    finally
        HTTP.get("$devtools/json/close/$(target.id)"; status_exception = false)
    end
end

"""
    evaluate(page, expression) -> value

Run `expression` in the page and return its JSON-serializable value.
"""
function evaluate(page::CdpPage, expression::String)
    id = (page.next_id += 1)
    WebSockets.send(page.ws, JSON3.write((;
        id, method = "Runtime.evaluate",
        params = (; expression, returnByValue = true))))
    while true
        msg = JSON3.read(WebSockets.receive(page.ws))
        (haskey(msg, :id) && msg.id == id) || continue   # skip protocol events
        haskey(msg, :error) && error("CDP error: $(msg.error)")
        result = msg.result.result
        if get(result, :subtype, "") == "error"
            error("JS error: $(get(result, :description, result))")
        end
        return get(result, :value, nothing)
    end
end

"""
    poll_js(page, expression; timeout = 15) -> Bool

Evaluate `expression` (which must yield a boolean) until it is true.
"""
function poll_js(page::CdpPage, expression::String; timeout = 15.0)
    return wait_for(; timeout) do
        evaluate(page, expression) === true
    end
end
