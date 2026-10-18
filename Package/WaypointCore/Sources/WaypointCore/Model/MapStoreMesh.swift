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

    /// The 3D surface file is built in the background AFTER a scan is saved (it takes seconds on a big scan). Until it is attached the saved
    /// map has no `meshAssets`, so an upload in that window would publish the map without its 3D scan. This marker file says "still building".
    /// It ignores a marker older than `maxAge` so a crash during the build cannot block uploads forever.
    public func markMeshPending(mapId: UUID) {
        try? Data().write(to: directory(for: mapId).appendingPathComponent(".mesh-pending"), options: .atomic)
    }

    public func clearMeshPending(mapId: UUID) {
        try? FileManager.default.removeItem(at: directory(for: mapId).appendingPathComponent(".mesh-pending"))
    }

    public func isMeshPending(mapId: UUID, maxAge: TimeInterval = 600, now: Date = Date()) -> Bool {
        let url = directory(for: mapId).appendingPathComponent(".mesh-pending")
        guard let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(made) < maxAge
    }

    public func loadMesh(mapId: UUID, assetId: UUID) -> Data? {
        if let data = try? Data(contentsOf: meshURL(mapId: mapId, assetId: assetId)) { return data }
        // Earlier U3 bundles used uppercase UUID filenames; retain read compatibility.
        return try? Data(contentsOf: directory(for: mapId).appendingPathComponent("mesh-\(assetId.uuidString).obj"))
    }

    /// Stores `data` and adds `asset` to the saved map. The asset must describe the data (size and SHA-256), or nothing is changed.
    @discardableResult
    public func attachMesh(_ asset: MeshAsset, data: Data, mapId: UUID) throws -> BuildingMap {
        guard asset.byteCount == data.count, asset.sha256 == ObjExport.sha256Hex(data) else {
            throw MapStoreError.rejected("The 3D surface file does not match its description.")
        }
        var map = try load(id: mapId)
        if !(map.meshAssets ?? []).contains(where: { $0.id == asset.id }) { map.meshAssets = (map.meshAssets ?? []) + [asset] }
        else { map.meshAssets = (map.meshAssets ?? []).map { $0.id == asset.id ? asset : $0 } }
        return try importBundle(MapBundle(map: map, meshFiles: [asset.id.uuidString: data]))
    }
}
