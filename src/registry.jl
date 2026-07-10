# Registries shared between render time (session/asset creation) and serve
# time (ws upgrade, asset GET). HTTP.jl handles requests on arbitrary tasks,
# so both are lock-guarded.

mutable struct SessionEntry
    const session::Session
    const created::Float64
    connected::Bool
end

"""
    SessionRegistry(; ttl = 300.0, sweep_interval = max(1.0, ttl / 4))

Lock-guarded map from session id to live `Bonito.Session`. Sessions register
themselves during render (via `Bonito.setup_connection`) and are removed when
their websocket disconnects. Sessions that render a page but never connect
(tab closed before JS ran, crawlers) are closed by a TTL sweeper once they are
older than `ttl` seconds; the sweeper timer starts with the first registration
and stops itself when the registry empties.
"""
mutable struct SessionRegistry
    const lock::ReentrantLock
    const entries::Dict{String, SessionEntry}
    const ttl::Float64
    const sweep_interval::Float64
    sweeper::Union{Nothing, Timer}
end

function SessionRegistry(; ttl::Real = 300.0, sweep_interval::Real = max(1.0, ttl / 4))
    return SessionRegistry(ReentrantLock(), Dict{String, SessionEntry}(),
                           Float64(ttl), Float64(sweep_interval), nothing)
end

function register!(r::SessionRegistry, s::Session)
    lock(r.lock) do
        r.entries[s.id] = SessionEntry(s, time(), false)
        ensure_sweeper!(r)
    end
    return s
end

function lookup(r::SessionRegistry, id::AbstractString)
    entry = lock(() -> get(r.entries, id, nothing), r.lock)
    return isnothing(entry) ? nothing : entry.session
end

function mark_connected!(r::SessionRegistry, id::AbstractString)
    lock(r.lock) do
        entry = get(r.entries, id, nothing)
        isnothing(entry) || (entry.connected = true)
    end
    return
end

remove!(r::SessionRegistry, id::AbstractString) = lock(() -> delete!(r.entries, id), r.lock)
Base.length(r::SessionRegistry) = lock(() -> length(r.entries), r.lock)

# Caller must hold r.lock.
function ensure_sweeper!(r::SessionRegistry)
    isnothing(r.sweeper) || return
    r.sweeper = Timer(r.sweep_interval; interval = r.sweep_interval) do _
        try
            sweep!(r)
        catch e
            @warn "Bonnie session sweeper failed" exception = (e, catch_backtrace())
        end
    end
    return
end

function sweep!(r::SessionRegistry)
    now = time()
    victims = Session[]
    lock(r.lock) do
        for (id, entry) in r.entries
            if !entry.connected && now - entry.created > r.ttl
                push!(victims, entry.session)
            end
        end
        for s in victims
            delete!(r.entries, s.id)
        end
        if isempty(r.entries) && !isnothing(r.sweeper)
            close(r.sweeper)
            r.sweeper = nothing
        end
    end
    # Close outside the lock: Session close cascades into the connection,
    # which re-enters the registry to deregister itself.
    for s in victims
        try
            close(s)
        catch e
            @warn "error closing expired session" session = s.id exception = (e, catch_backtrace())
        end
    end
    return length(victims)
end

"""
    close(r::SessionRegistry)

Stop the sweeper and close every remaining session (server shutdown).
"""
function Base.close(r::SessionRegistry)
    sessions = lock(r.lock) do
        isnothing(r.sweeper) || (close(r.sweeper); r.sweeper = nothing)
        sessions = [entry.session for entry in values(r.entries)]
        empty!(r.entries)
        sessions
    end
    foreach(s -> (try close(s) catch end), sessions)
    return
end

struct AssetRegistry
    lock::ReentrantLock
    assets::Dict{String, AbstractAsset}
end
AssetRegistry() = AssetRegistry(ReentrantLock(), Dict{String, AbstractAsset}())

register!(r::AssetRegistry, key::AbstractString, asset::AbstractAsset) =
    lock(() -> r.assets[key] = asset, r.lock)
lookup(r::AssetRegistry, key::AbstractString) = lock(() -> get(r.assets, key, nothing), r.lock)
