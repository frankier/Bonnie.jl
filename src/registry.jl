# Registries shared between render time (session/asset creation) and serve
# time (ws upgrade, asset GET). HTTP.jl handles requests on arbitrary tasks,
# so both are lock-guarded.

"""
    SessionRegistry(; cleanup_policy = Bonito.DefaultCleanupPolicy(),
                    session_ttl = 300.0, reconnect_window = 30.0,
                    sweep_interval = 15.0)

Lock-guarded map from session id to live `Bonito.Session`. Sessions register
themselves during render (via `Bonito.setup_connection`) and lifecycle is
governed by a `Bonito.CleanupPolicy`:

- a session whose page renders but never connects (tab closed before JS ran,
  crawlers) is closed once it is older than `session_ttl` seconds;
- on websocket disconnect the session is **soft-closed** and stays
  registered for `reconnect_window` seconds so a reconnecting browser
  (flaky network, laptop sleep) resumes the same session; with
  `reconnect_window = 0` it is closed immediately instead.

`session_ttl`/`reconnect_window` are conveniences filling in a
`Bonito.DefaultCleanupPolicy`; pass `cleanup_policy` to override with any
policy implementing `should_cleanup`/`allow_soft_close`. A sweeper timer
(started with the first registration, stopped when the registry empties)
closes sessions `should_cleanup` approves of.
"""
mutable struct SessionRegistry
    const lock::ReentrantLock
    const entries::Dict{String, Session}
    const cleanup_policy::Bonito.CleanupPolicy
    const sweep_interval::Float64
    sweeper::Union{Nothing, Timer}
end

function SessionRegistry(; session_ttl::Real = 300.0, reconnect_window::Real = 30.0,
                         cleanup_policy::Bonito.CleanupPolicy =
                             Bonito.DefaultCleanupPolicy(session_ttl, reconnect_window / 60 / 60),
                         sweep_interval::Real = 15.0)
    return SessionRegistry(ReentrantLock(), Dict{String, Session}(),
                           cleanup_policy, Float64(sweep_interval), nothing)
end

function register!(r::SessionRegistry, s::Session)
    lock(r.lock) do
        r.entries[s.id] = s
        ensure_sweeper!(r)
    end
    return s
end

lookup(r::SessionRegistry, id::AbstractString) = lock(() -> get(r.entries, id, nothing), r.lock)
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
    victims = Session[]
    lock(r.lock) do
        for (id, session) in r.entries
            Bonito.should_cleanup(r.cleanup_policy, session) && push!(victims, session)
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
        sessions = collect(values(r.entries))
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
