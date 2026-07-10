# Helpers shared between the main suite, the smoke harness (conftest.jl) and
# the standalone WGLMakie canary. Expects `using Test, Bonito, Bonnie, HTTP`
# in the includer.

using Sockets

function wait_for(f; timeout = 10.0)
    deadline = time() + timeout
    while !f() && time() < deadline
        sleep(0.05)
    end
    return f()
end

slider_app() = App() do
    slider = Bonito.Slider(1:10)
    return Bonito.DOM.div(slider, Bonito.DOM.div(slider.value))
end

# The browser side of Bonito's protocol: plain msgpack, gzipped only if the
# session negotiated compression. (Bonito.serialize_binary is the *server*
# encoder and wraps payloads in msgpack extensions process_message rejects.)
function client_message(session, msg::AbstractDict)
    bytes = Bonito.MsgPack.pack(msg)
    session.compression_enabled && (bytes = Bonito.transcode(Bonito.GzipCompressor, bytes))
    return bytes
end

function free_port()
    server = Sockets.listen(Sockets.InetAddr(Sockets.ip"127.0.0.1", 0))
    _, port = Sockets.getsockname(server)
    close(server)
    return Int(port)
end
