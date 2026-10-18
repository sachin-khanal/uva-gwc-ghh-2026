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
import Foundation
import simd

/// Everything needed to recreate one building map on another device.
public struct MapBundle: Codable, Sendable {
    public var map: BuildingMap
    /// segmentId -> archived ARWorldMap bytes. May be empty (e.g. a hand-written sample map).
    public var worldMaps: [String: Data]

    public init(map: BuildingMap, worldMaps: [String: Data] = [:]) {
        self.map = map
        self.worldMaps = worldMaps
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

    // MARK: Bundles (sync / export / import)

    public func makeBundle(id: UUID) throws -> MapBundle {
        let map = try load(id: id)
        var worldMaps: [String: Data] = [:]
        for seg in map.segmentIds {
            if let d = try loadWorldMap(mapId: id, segmentId: seg) { worldMaps[seg] = d }
        }
        return MapBundle(map: map, worldMaps: worldMaps)
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
        if let existing = try? load(id: bundle.map.id) {
            let known = Set(existing.nodes.map(\.id))
            for e in bundle.map.edges
            where known.contains(e.from) && known.contains(e.to)
                && !existing.edges.contains(where: { $0.connects(e.from, e.to) }) {
                throw MapStoreError.rejected("Incoming map adds a new connection between existing places; refusing to merge.")
            }
            // Keep our copy's data on conflicts, add anything new from the incoming copy.
            result = existing.merged(with: bundle.map)
        }
        try save(result)
        for (seg, data) in bundle.worldMaps {
            // Only fill world maps we do not have; never silently replace a good local scan.
            if try loadWorldMap(mapId: result.id, segmentId: seg) == nil {
                try saveWorldMap(data, mapId: result.id, segmentId: seg)
            }
        }
        return result
    }

    public func importBundle(data: Data) throws -> BuildingMap {
        try importBundle(JSONDecoder().decode(MapBundle.self, from: data))
    }
}
