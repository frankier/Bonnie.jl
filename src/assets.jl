# EmbeddedAssetServer: like Bonito.HTTPAssetServer, but generates URLs under
# <prefix>/assets/<key> and registers the assets in Bonnie's registry, served
# by the host server. Content-addressed keys (Bonito.unique_file_key) make the
# URLs safely cacheable.

struct EmbeddedAssetServer <: AbstractAssetServer
    registry::AssetRegistry
    prefix::String
end

EmbeddedAssetServer(prefix::String = DEFAULT_PREFIX) = EmbeddedAssetServer(AssetRegistry(), prefix)

function Bonito.url(s::EmbeddedAssetServer, asset::AbstractAsset)
    Bonito.is_online(asset) && return Bonito.online_path(asset)
    key = Bonito.unique_file_key(asset)
    register!(s.registry, key, asset)
    suffix = (asset isa Bonito.Asset && asset.es6module) ? "?" * asset.content_hash[] : ""
    return s.prefix * "/assets/" * key * suffix
end

Bonito.setup_asset_server(::EmbeddedAssetServer) = nothing
# Subsessions share the same registry/prefix; refcounted per-session release
# (Bonito's ChildAssetServer) is deferred past the spike.
Base.similar(s::EmbeddedAssetServer) = s

# Serve GET <prefix>/assets/<key>. Reuses Bonito's serve_asset, which handles
# Range requests, Last-Modified/If-Modified-Since and content types.
function serve_asset_response(registry::AssetRegistry, req::HTTP.Request, key::AbstractString)
    asset = lookup(registry, key)
    isnothing(asset) && return HTTP.Response(404)
    if asset isa Bonito.BinaryAsset
        return Bonito.serve_asset(req, asset.data, nothing, asset.mime,
                                  Bonito.cache_control_for(asset))
    elseif asset isa Bonito.Asset
        path = Bonito.local_path(asset)
        if !isempty(asset.bundle_data)
            return Bonito.serve_asset(req, Bonito.bundle_data_snapshot(asset), nothing,
                                      Bonito.file_mimetype(path), Bonito.cache_control_for(asset))
        elseif isfile(path)
            return Bonito.serve_asset(req, nothing, path,
                                      Bonito.file_mimetype(path), Bonito.cache_control_for(asset))
        end
    end
    return HTTP.Response(404)
end
