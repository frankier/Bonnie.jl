# Registries shared between render time (session/asset creation) and serve
# time (ws upgrade, asset GET). HTTP.jl handles requests on arbitrary tasks,
# so both are lock-guarded. TTL sweeping is deferred to plan step 2.

struct SessionRegistry
    lock::ReentrantLock
    sessions::Dict{String, Session}
end
SessionRegistry() = SessionRegistry(ReentrantLock(), Dict{String, Session}())

register!(r::SessionRegistry, s::Session) = lock(() -> r.sessions[s.id] = s, r.lock)
lookup(r::SessionRegistry, id::AbstractString) = lock(() -> get(r.sessions, id, nothing), r.lock)
remove!(r::SessionRegistry, id::AbstractString) = lock(() -> delete!(r.sessions, id), r.lock)
Base.length(r::SessionRegistry) = lock(() -> length(r.sessions), r.lock)

struct AssetRegistry
    lock::ReentrantLock
    assets::Dict{String, AbstractAsset}
end
AssetRegistry() = AssetRegistry(ReentrantLock(), Dict{String, AbstractAsset}())

register!(r::AssetRegistry, key::AbstractString, asset::AbstractAsset) =
    lock(() -> r.assets[key] = asset, r.lock)
lookup(r::AssetRegistry, key::AbstractString) = lock(() -> get(r.assets, key, nothing), r.lock)
