//
// File:     Model/MapStore.swift
// Module:   WaypointCore
// Owner:    D (App/Sync) - A (Maps) calls it to save scans.
// Purpose:  Reads/writes building maps on local disk, and packs/unpacks a `MapBundle`
//           (map JSON + the binary ARWorldMap files) for transfer to another phone.
// Layout:   <root>/<map-uuid>/map.json
//           <root>/<map-uuid>/worldmap-<segmentId>.arworldmap
// Pure Foundation: no ARKit. The ARWorldMap is treated as opaque `Data` here; archiving it
//           with NSKeyedArchiver happens in the app target (Waypoint/Capture).
//
// Status: Schema 3 implementation; native tests pending Mac; UNVERIFIED ON DEVICE.
import Foundation
import simd

/// Everything needed to recreate one building map on another device.
public struct MapBundle: Codable, Sendable {
    public var map: BuildingMap
    /// segmentId -> archived ARWorldMap bytes. May be empty (e.g. a hand-written sample map).
    public var worldMaps: [String: Data]
    /// Schema 3 optional OBJ payloads, keyed by asset UUID string. Absent in legacy bundles.
    public var meshFiles: [String: Data]?

    public init(map: BuildingMap, worldMaps: [String: Data] = [:], meshFiles: [String: Data]? = nil) {
        self.map = map
        self.worldMaps = worldMaps
        self.meshFiles = meshFiles
    }
}

public enum MapStoreError: Error, Equatable {
    case notFound(UUID)
    /// Incoming data failed `MapBundle.validate()` or the merge safety check. Message is user-presentable.
    case rejected(String)
}

extension MapBundle {
    /// Hard limits so a hostile or corrupt bundle cannot exhaust memory or confuse routing.
    public static let maxNodes = 5_000
    public static let maxEdges = 20_000
    public static let maxWorldMapBytes = 50_000_000
    /// One visual fingerprint every ~2.5 m walked; 5000 is far more than any building we will scan,
    /// while still bounding a hostile or runaway map.
    public static let maxKeyframes = 5_000
    /// An Apple Vision feature print archives to a few KB; 64 KB leaves generous headroom and still
    /// stops one fingerprint bloating the map JSON.
    public static let maxKeyframeDescriptorBytes = 64 * 1024

    /// Structural sanity check for a bundle that came from ANOTHER device (sync / AirDrop).
    /// Does not prove the map is truthful - a human still approves imports - but it rejects data
    /// that is malformed or would silently corrupt routing:
    ///  * size limits, finite positions, unique node ids,
    ///  * every edge references existing nodes and is not a self-loop,
    ///  * edge distance is within max(0.5 m, 25%) of the straight-line distance between its nodes
    ///    (a "shortcut" edge claiming 1 m between rooms 40 m apart is rejected).
    public func validate() throws {
        guard (1...MapSchema.current).contains(map.schemaVersion), (map.meshAssets ?? []).count <= 100 else {
            throw MapStoreError.rejected("Unsupported map schema or too many mesh assets.")
        }
        var assetIDs = Set<UUID>()
        var declaredMeshBytes = 0
        for asset in (map.meshAssets ?? []) {
            try asset.validate()
            declaredMeshBytes += asset.byteCount
            guard declaredMeshBytes <= 80_000_000 else { throw MapStoreError.rejected("Mesh assets exceed 80 MB.") }
            guard assetIDs.insert(asset.id).inserted, map.segmentIds.contains(asset.segmentId) else {
                throw MapStoreError.rejected("Duplicate mesh asset or unknown segment.")
            }
        }
        var meshBytes = 0
        for (key, bytes) in meshFiles ?? [:] {
            guard let id = UUID(uuidString: key), let asset = (map.meshAssets ?? []).first(where: { $0.id == id }) else {
                throw MapStoreError.rejected("Mesh file has no manifest entry.")
            }
            meshBytes += bytes.count
            guard meshBytes <= 80_000_000 else { throw MapStoreError.rejected("Mesh bundle exceeds 80 MB.") }
            try asset.validate(data: bytes)
        }
        for node in map.nodes {
            if let e = node.extent {
                let area = 4 * Double(e.halfExtents.x) * Double(e.halfExtents.y)
                guard node.kind == .room,
                      e.center.x.isFinite, e.center.y.isFinite, e.center.z.isFinite,
                      e.halfExtents.x.isFinite, e.halfExtents.y.isFinite,
                      e.halfExtents.x > 0, e.halfExtents.y > 0, e.yaw.isFinite,
                      e.areaSquareMeters.isFinite, e.areaSquareMeters > 0,
                      Double(e.areaSquareMeters) <= area + 0.01,
                      e.heightMeters.map({ $0.isFinite && $0 > 0 }) ?? true else {
                    throw MapStoreError.rejected("Invalid room extent.")
                }
            }
        }
        guard map.nodes.count <= Self.maxNodes, map.edges.count <= Self.maxEdges else {
            throw MapStoreError.rejected("Map is too large (\(map.nodes.count) nodes, \(map.edges.count) edges).")
        }
        if worldMaps.values.contains(where: { $0.count > Self.maxWorldMapBytes }) {
            throw MapStoreError.rejected("A world map in this bundle is too large.")
        }
        // Keyframes were not checked at all until 2026-10-17. They come from other people like the
        // rest of the map, they inflate the JSON, and a non-finite pose would flow straight into
        // `mapToWorld` and put the user somewhere impossible.
        if map.keyframes.count > Self.maxKeyframes {
            throw MapStoreError.rejected("Map has too many visual fingerprints (\(map.keyframes.count)).")
        }
        for k in map.keyframes {
            guard k.position.x.isFinite, k.position.y.isFinite, k.position.z.isFinite, k.yaw.isFinite else {
                throw MapStoreError.rejected("A visual fingerprint has an invalid position.")
            }
            guard k.descriptor.count <= Self.maxKeyframeDescriptorBytes else {
                throw MapStoreError.rejected("A visual fingerprint is too large.")
            }
        }
        for node in map.nodes {
            if let stairs = node.stairs {
                guard node.kind == .stairs || node.kind == .elevator, stairs.stepCount.map({ $0 > 0 && $0 <= 10_000 }) ?? true else { throw MapStoreError.rejected("Invalid stair metadata.") }
            }
        }
        // Segment ids become file names and storage paths: reject anything outside the safe alphabet.
        for n in map.nodes where !SegmentID.isValid(n.segmentId) {
            throw MapStoreError.rejected("A node has an unsafe segment id.")
        }
        for key in worldMaps.keys where !SegmentID.isValid(key) {
            throw MapStoreError.rejected("A world map has an unsafe segment id.")
        }
        var positions: [UUID: SIMD3<Float>] = [:]
        for n in map.nodes {
            guard n.position.x.isFinite, n.position.y.isFinite, n.position.z.isFinite else {
                throw MapStoreError.rejected("A node has an invalid position.")
            }
            guard positions.updateValue(n.position, forKey: n.id) == nil else {
                throw MapStoreError.rejected("Duplicate node id in map.")
            }
        }
        for e in map.edges {
            guard let a = positions[e.from], let b = positions[e.to], e.from != e.to else {
                throw MapStoreError.rejected("An edge refers to a missing node.")
            }
            let straight = simd_distance(a, b)
            let tolerance = max(0.5, straight * 0.25)
            guard e.distance.isFinite, abs(e.distance - straight) <= tolerance else {
                throw MapStoreError.rejected("An edge's distance does not match its node positions.")
            }
        }
        try validateExtras() // optional format-3 fields: room floor areas and 3D surface files
    }
}

public final class MapStore {

    public let rootURL: URL
    private let fm = FileManager.default

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// `<app Documents>/Maps`. Documents is visible in the iOS Files app (UIFileSharingEnabled),
    /// which makes it easy to inspect map.json on a phone while debugging.
    public static func defaultStore() throws -> MapStore {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return MapStore(rootURL: docs.appendingPathComponent("Maps", isDirectory: true))
    }

    // MARK: Paths

    public func directory(for mapId: UUID) -> URL {
        rootURL.appendingPathComponent(mapId.uuidString, isDirectory: true)
    }

    private func mapJSONURL(_ mapId: UUID) -> URL {
        directory(for: mapId).appendingPathComponent("map.json")
    }

    public func worldMapURL(mapId: UUID, segmentId: String) -> URL {
        directory(for: mapId).appendingPathComponent("worldmap-\(segmentId).arworldmap")
    }

    // MARK: Map JSON

    /// Saves (creates or overwrites) the map JSON.
    public func save(_ map: BuildingMap) throws {
        try fm.createDirectory(at: directory(for: map.id), withIntermediateDirectories: true)
        try map.jsonData().write(to: mapJSONURL(map.id), options: .atomic)
    }

    public func load(id: UUID) throws -> BuildingMap {
        let url = mapJSONURL(id)
        guard fm.fileExists(atPath: url.path) else { throw MapStoreError.notFound(id) }
        return try BuildingMap.from(jsonData: Data(contentsOf: url))
    }

    /// All maps on disk, sorted by name. Unreadable folders are skipped (and not deleted).
    public func listMaps() throws -> [BuildingMap] {
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        return entries.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            return try? load(id: id)
        }.sorted { $0.name < $1.name }
    }

    public func delete(id: UUID) throws {
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    // MARK: ARWorldMap bytes

    public func saveWorldMap(_ data: Data, mapId: UUID, segmentId: String) throws {
        guard SegmentID.isValid(segmentId) else { throw MapStoreError.rejected("Unsafe segment id.") }
        try fm.createDirectory(at: directory(for: mapId), withIntermediateDirectories: true)
        try data.write(to: worldMapURL(mapId: mapId, segmentId: segmentId), options: .atomic)
    }

    /// Returns nil (not an error) if this segment has no saved world map, e.g. the sample map.
    public func loadWorldMap(mapId: UUID, segmentId: String) throws -> Data? {
        guard SegmentID.isValid(segmentId) else { throw MapStoreError.rejected("Unsafe segment id.") }
        let url = worldMapURL(mapId: mapId, segmentId: segmentId)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    // MARK: 3D model (derived from the scan mesh)

    /// The exported 3D model of a scan (USDZ), written next to the map when a scan is saved. Not part of bundles or sync yet.
    /// One model file PER SEGMENT. It used to be one per map, so extending a building overwrote the
    /// whole thing with just the new part - the viewer showed a lone stairwell instead of the floor
    /// (device report 2026-10-18). The original scan keeps the unsuffixed name so existing files on
    /// phones still load.
    public func modelURL(mapId: UUID, segmentId: String) -> URL {
        directory(for: mapId).appendingPathComponent("model-\(segmentId).usdz")
    }

    /// Every model file this map has, oldest segment first. Empty when none has been exported.
    public func modelURLs(mapId: UUID, segmentIds: [String]) -> [URL] {
        var urls: [URL] = []
        let legacy = modelURL(mapId: mapId)
        if fm.fileExists(atPath: legacy.path) { urls.append(legacy) }
        for segment in segmentIds where SegmentID.isValid(segment) {
            let url = modelURL(mapId: mapId, segmentId: segment)
            if fm.fileExists(atPath: url.path) { urls.append(url) }
        }
        return urls
    }

    public func modelURL(mapId: UUID) -> URL {
        directory(for: mapId).appendingPathComponent("model.usdz")
    }

    public func hasModel(mapId: UUID) -> Bool {
        fm.fileExists(atPath: modelURL(mapId: mapId).path)
    }

    /// Any model file at all, including per-segment ones from an extension.
    public func hasModel(mapId: UUID, segmentIds: [String]) -> Bool {
        !modelURLs(mapId: mapId, segmentIds: segmentIds).isEmpty
    }

    // MARK: Route memory (derived cache, never shared)

    private func routeMemoryURL(_ mapId: UUID) -> URL {
        directory(for: mapId).appendingPathComponent("route-memory.json")
    }

    /// Remembered shortest routes for this map (see `RoutePlanner`). It is a CACHE: not part of bundles/sync, safe to delete, and a
    /// missing or corrupt file just yields an empty memory (routes are recomputed). Entries also self-invalidate when the map changes.
    public func loadRouteMemory(mapId: UUID) -> RouteMemory {
        guard let data = try? Data(contentsOf: routeMemoryURL(mapId)),
              let memory = try? JSONDecoder().decode(RouteMemory.self, from: data) else { return RouteMemory() }
        return memory
    }

    public func saveRouteMemory(_ memory: RouteMemory, mapId: UUID) throws {
        guard fm.fileExists(atPath: directory(for: mapId).path) else { throw MapStoreError.notFound(mapId) }
        try JSONEncoder().encode(memory).write(to: routeMemoryURL(mapId), options: .atomic)
    }

    // MARK: Bundles (sync / export / import)

    public func makeBundle(id: UUID) throws -> MapBundle {
        let map = try load(id: id)
        var worldMaps: [String: Data] = [:]
        for seg in map.segmentIds {
            if let d = try loadWorldMap(mapId: id, segmentId: seg) { worldMaps[seg] = d }
        }
        var meshes: [String: Data] = [:]
        for asset in (map.meshAssets ?? []) {
            if let bytes = try loadMesh(mapId: id, asset: asset) { meshes[asset.id.uuidString] = bytes }
        }
        return MapBundle(map: map, worldMaps: worldMaps, meshFiles: meshes.isEmpty ? nil : meshes)
    }

    public func loadMesh(mapId: UUID, asset: MeshAsset) throws -> Data? {
        guard let data = loadMesh(mapId: mapId, assetId: asset.id) else { return nil }
        try asset.validate(data: data)
        return data
    }

    /// Writes a bundle file into the temp directory and returns its URL, for ShareLink / AirDrop
    /// / MultipeerConnectivity `sendResource`. File extension `.waypointmap` (JSON inside).
    public func writeBundleFile(id: UUID) throws -> URL {
        let bundle = try makeBundle(id: id)
        let url = fm.temporaryDirectory.appendingPathComponent("\(bundle.map.name).waypointmap")
        try JSONEncoder().encode(bundle).write(to: url, options: .atomic)
        return url
    }

    /// Imports a bundle. If we already have that map id, the two are merged
    /// (`BuildingMap.merged`); otherwise it is stored as new. Returns the stored map.
    /// Validates first (throws `MapStoreError.rejected`). When merging into an existing map it also
    /// rejects NEW edges that join two nodes we already have: that is how someone could splice a
    /// shortcut through walls into a trusted map. Genuine extensions attach new nodes instead.
    /// (Limitation: this also blocks closing a loop between two existing nodes; do that by scanning
    /// a new node in between.)
    @discardableResult
    public func importBundle(_ bundle: MapBundle) throws -> BuildingMap {
        try bundle.validate()
        var result = bundle.map
        if fm.fileExists(atPath: mapJSONURL(bundle.map.id).path) {
            // An unreadable/future stored map is not a missing map: never overwrite it.
            let existing = try load(id: bundle.map.id)
            for asset in (bundle.map.meshAssets ?? []) {
                if let old = (existing.meshAssets ?? []).first(where: { $0.id == asset.id }) {
                    var a = old, b = asset
                    a.storageOwner = nil; b.storageOwner = nil
                    guard a == b, old.storageOwner == nil || asset.storageOwner == nil || old.storageOwner == asset.storageOwner else {
                        throw MapStoreError.rejected("Existing mesh metadata cannot be replaced.")
                    }
                }
            }
            let known = Set(existing.nodes.map(\.id))
            for e in bundle.map.edges
            where known.contains(e.from) && known.contains(e.to)
                && !existing.edges.contains(where: { $0.connects(e.from, e.to) }) {
                throw MapStoreError.rejected("Incoming map adds a new connection between existing places; refusing to merge.")
            }
            // Keep our copy's data on conflicts, add anything new from the incoming copy.
            result = existing.merged(with: bundle.map)
            // The union of two individually valid maps can still break a limit (node count, 100 mesh files, 80 MB of them): check the RESULT
            // before anything is saved (security review 2026-10-18).
            try MapBundle(map: result).validate()
        }
        // Write payloads first. A failed write may leave an orphan file, never a new
        // map manifest claiming that its mesh bytes were saved when they were not.
        try fm.createDirectory(at: directory(for: result.id), withIntermediateDirectories: true)
        for (seg, data) in bundle.worldMaps {
            // Only fill world maps we do not have; never silently replace a good local scan.
            if try loadWorldMap(mapId: result.id, segmentId: seg) == nil {
                try saveWorldMap(data, mapId: result.id, segmentId: seg)
            }
        }
        for (key, bytes) in bundle.meshFiles ?? [:] {
            guard let id = UUID(uuidString: key), let asset = (result.meshAssets ?? []).first(where: { $0.id == id }) else { continue }
            try asset.validate(data: bytes)
            let url = meshURL(mapId: result.id, assetId: id)
            if !fm.fileExists(atPath: url.path) { try bytes.write(to: url, options: .atomic) }
        }
        try save(result)
        return result
    }

    public func importBundle(data: Data) throws -> BuildingMap {
        try importBundle(JSONDecoder().decode(MapBundle.self, from: data))
    }
}
