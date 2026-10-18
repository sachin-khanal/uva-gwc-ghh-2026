//
// File:     Model/MapStoreMesh.swift
// Module:   WaypointCore
// Owner:    D (storage) with U3 (web viewer)
// Purpose:  Keeps the OBJ surface files of a map next to `map.json` and lists them in `BuildingMap.meshAssets` so SyncEngine can
//           publish them for the web viewer. Layout: <map dir>/mesh-<asset uuid>.obj. The file is written BEFORE the manifest entry, so
//           a listed asset always has its file; the manifest is validated like any imported map (size, SHA-256 shape, bounds).
//
import Foundation

extension MapStore {

    public func meshURL(mapId: UUID, assetId: UUID) -> URL {
        directory(for: mapId).appendingPathComponent("mesh-\(assetId.uuidString.lowercased()).obj")
    }

    public func loadMesh(mapId: UUID, assetId: UUID) -> Data? {
        try? Data(contentsOf: meshURL(mapId: mapId, assetId: assetId))
    }

    /// Stores `data` and adds `asset` to the saved map. The asset must describe the data (size and SHA-256), or nothing is changed.
    @discardableResult
    public func attachMesh(_ asset: MeshAsset, data: Data, mapId: UUID) throws -> BuildingMap {
        guard asset.byteCount == data.count, asset.sha256 == ObjExport.sha256Hex(data) else {
            throw MapStoreError.rejected("The 3D surface file does not match its description.")
        }
        var map = try load(id: mapId)
        var assets = (map.meshAssets ?? []).filter { $0.id != asset.id }
        assets.append(asset)
        map.meshAssets = assets
        try MapBundle(map: map).validate() // size limits, known segment, bounds; throws before anything is written
        try data.write(to: meshURL(mapId: mapId, assetId: asset.id), options: .atomic)
        try save(map)
        return map
    }
}
