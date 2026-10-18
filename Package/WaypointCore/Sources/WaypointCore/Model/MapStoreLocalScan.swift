//
// File:     Model/MapStoreLocalScan.swift
// Module:   WaypointCore
// Owner:    A (scan) / D (storage)
// Purpose:  Saving a scan THIS PHONE just recorded, and measuring scan files on disk. Kept in its own file (an extension of MapStore) so
//           the shared MapStore stays small.
// Why a separate save path: `importBundle` is the gate for maps from OTHER people and refuses a world map over `MapBundle.maxWorldMapBytes`
//           (50 MB, the cloud limit). Routing the phone's own fresh scan through it meant a long scan could not even be SAVED. A local scan
//           is validated like any map (nodes, edges, extents, mesh files) but its scan file may be larger; `SharePolicy` then keeps such a
//           map from leaving the phone.
// Status:   DONE (logic, unit tested).
//
import Foundation

extension MapStore {

    /// Sanity cap for a scan file on THIS phone (an ARWorldMap this large would not load on a phone anyway).
    public static let maxLocalWorldMapBytes = 500_000_000

    /// Saves a scan recorded on this phone: validates and merges the map JSON exactly like an import, then writes the scan file with
    /// no 50 MB sharing limit. Returns the stored (possibly merged) map.
    @discardableResult
    public func saveLocalScan(map: BuildingMap, worldMap: Data, segmentId: String) throws -> BuildingMap {
        guard SegmentID.isValid(segmentId) else { throw MapStoreError.rejected("Unsafe segment id.") }
        guard worldMap.count <= Self.maxLocalWorldMapBytes else { throw MapStoreError.rejected("This scan is too large to store on the phone.") }
        let stored = try importBundle(MapBundle(map: map, worldMaps: [:])) // map JSON: same validation and merge rules as any import
        try saveWorldMap(worldMap, mapId: stored.id, segmentId: segmentId)
        return stored
    }

    /// Size in bytes of each scan segment file stored for `mapId`, read from file attributes (nothing is loaded into memory).
    public func worldMapByteCounts(mapId: UUID) -> [String: Int] {
        let dir = directory(for: mapId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var sizes: [String: Int] = [:]
        for name in names where name.hasPrefix("worldmap-") && name.hasSuffix(".arworldmap") {
            let segment = String(name.dropFirst("worldmap-".count).dropLast(".arworldmap".count))
            guard SegmentID.isValid(segment),
                  let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size]) as? Int
            else { continue }
            sizes[segment] = size
        }
        return sizes
    }

    /// Whether this map may be uploaded or sent to a nearby phone (see `SharePolicy`).
    public func shareVerdict(mapId: UUID) -> SharePolicy.Verdict {
        SharePolicy.evaluate(worldMapBytes: worldMapByteCounts(mapId: mapId))
    }
}
