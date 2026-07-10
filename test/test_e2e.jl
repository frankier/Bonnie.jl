# End-to-end browser tests (plan step 7; opt-in via BONNIE_E2E=1): drive the
# widgets of real example servers in headless Chrome and assert the
# client<->server roundtrip — that proves the JS loaded from our asset route,
# the websocket connected through our route, and messages flow both ways
# (Bonito updates the value label server-side). The mplbed analogue panned
# figures and diffed pixels; asserting DOM + /probe is stronger.

include("cdp.jl")

spec_by_id(id) = only(filter(s -> s.id == id, EXAMPLE_SPECS))

# Bonito's Slider is <input type=range> whose index Observable is notified
# from an 'input' listener; setting the 7th index makes the value 7 for the
# examples' 1:10 sliders. Wrapped in a poll: driving before the websocket is
# connected is a no-op, so retry until the server (or DOM) reflects it.
slider_drive_js(scope = "document") = """
(() => {
    const el = $scope.querySelector('input[type=range]');
    if (!el) return false;
    el.value = '7';
    el.dispatchEvent(new Event('input', {bubbles: true}));
    return true;
})()
"""

function drive_until(cond, page::CdpPage, drive_js::String; timeout = 30.0)
    return wait_for(; timeout) do
        evaluate(page, drive_js) === true && cond()
    end
end

probe(base) = String(HTTP.get("$base/probe"; retry = false).body)

@testset "e2e (headless Chrome)" begin
    browser = launch_chrome()
    try
        @testset "basic: slider roundtrip + probe" begin
            with_example(spec_by_id("basic")) do base
                with_page(browser, "$base/") do page
                    @test poll_js(page, "document.querySelector('input[type=range]') !== null")
                    # server-side roundtrip: the probe sees the driven value
                    @test drive_until(() -> probe(base) == "7", page, slider_drive_js())
                    # client-side roundtrip: the value label is updated by the server
                    @test poll_js(page, "document.body.innerText.includes('7')")
                end
            end
        end

        @testset "embed_raw: two fragments both connect" begin
            with_example(spec_by_id("embed_raw")) do base
                with_page(browser, "$base/") do page
                    @test poll_js(page,
                        "document.querySelectorAll('input[type=range]').length === 2")
                    @test drive_until(page, slider_drive_js()) do
                        evaluate(page, "document.body.innerText.includes('7')") === true
                    end
                end
            end
        end

        @testset "oxygen templates: fragment + iframe traversal" begin
            with_example(spec_by_id("oxygen_templates")) do base
                with_page(browser, "$base/") do page
                    # fragment app on the host page
                    @test drive_until(page, slider_drive_js()) do
                        evaluate(page, "document.body.innerText.includes('7')") === true
                    end
                    # app inside the iframe (same-origin: reach through
                    # contentDocument, mirroring mplbed's iframe traversal)
                    frame = "document.querySelector('iframe').contentDocument"
                    @test poll_js(page, "$frame !== null && $frame.querySelector('input[type=range]') !== null")
                    @test drive_until(page, slider_drive_js(frame)) do
                        evaluate(page, "$frame.body.innerText.includes('7')") === true
                    end
                end
            end
        end

        if get(ENV, "BONNIE_E2E_WGLMAKIE", "") == "1"
            @testset "wglmakie: button + canvas" begin
                with_example(spec_by_id("wglmakie_streaming")) do base
                    with_page(browser, "$base/") do page
                        @test poll_js(page, "document.querySelector('canvas') !== null";
                                      timeout = 60)
                        click = "(() => { const b = document.querySelector('button'); " *
                                "if (!b) return false; b.click(); return true; })()"
                        @test drive_until(() -> probe(base) != "0", page, click; timeout = 60)
                    end
                end
            end
        end
    finally
        close(browser)
    end
end
