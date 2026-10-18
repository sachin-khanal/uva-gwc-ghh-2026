//
// File:     Model/BuildingMap.swift
// Module:   WaypointCore
// Owner:    SHARED CONTRACT (see MapTypes.swift). Merge logic: D (sync) + A (maps).
// Purpose:  The top-level map document: nodes + edges + optional marker, plus JSON helpers and
//           the merge rule used when several people extend the same building.
// On disk:  <Documents>/Maps/<map-uuid>/map.json   (this struct)
//           <Documents>/Maps/<map-uuid>/worldmap-<segmentId>.arworldmap  (binary ARWorldMap)
//           See MapStore.swift.
//
import Foundation

/// Versions of the map JSON FORMAT. One spec per version lives in docs/MAP_FORMAT.md.
///  * 1 - original shape; has no `schemaVersion` key (so "missing" means 1).
///  * 2 - identical shape, plus `schemaVersion` written explicitly (CONTRACT CHANGE 2026-10-17).
///  * 3 - adds the OPTIONAL `MapNode.extent` (room floor area), `extent.heightMeters`, `meshAssets` (3D surface files, shared with the web viewer) and
///        `keyframes` (visual fingerprints for faster relocalization, from navigation-overhaul). All optional: older maps simply have none.
///  * 4 - adds the OPTIONAL `MapNode.stairs` (direction up/down/both, railing side, step count) for `.stairs` and `.elevator` nodes
///        (CONTRACT CHANGE 2026-10-18). Optional, so every older map decodes unchanged with none; nothing else moved.
/// To add version N+1: bump `current`, add a spec + fixture (docs/map-format/), extend `migrate`, add a test in MapSchemaTests,
/// update tools/validate_map.py (`CURRENT_SCHEMA`), and announce CONTRACT CHANGE in the WORKLOG.
public enum MapSchema {
    public static let current = 4
    public static let oldestReadable = 1

    /// Upgrades a decoded map's format number step by step. Shapes 1 and 2 are identical, so this only advances the number;
    /// later versions put real field conversions in the matching `case`.
    public static func migrate(from version: Int) -> Int {
        var v = version
        while v < current {
            switch v {
            case 1: v = 2 // 1 -> 2: nothing to convert; `schemaVersion` is now written explicitly
            case 2: v = 3 // 2 -> 3: `extent` is optional; nothing to convert
            default: v = current
            }
        }
        return v
    }
}

public struct BuildingMap: Codable, Identifiable, Equatable, Sendable {

    /// FORMAT version of the JSON (not the content revision, that is `version`). Always `MapSchema.current` after decoding:
    /// older files are migrated in memory on load. See `MapSchema` and docs/MAP_FORMAT.md.
    public var schemaVersion: Int

    public var id: UUID
    /// Display name, e.g. "Rice Hall, floor 1".
    public var name: String
    /// Increments every time the map is saved after being extended. Sync uses it to decide who is newer.
    public var version: Int
    public var nodes: [MapNode]
    public var edges: [MapEdge]
    /// Optional fallback relocalization marker (see MarkerRef).
    public var marker: MarkerRef?
    /// Optional 3D surface files (format 3). nil = none, and then the key is absent from the JSON (maps without any are byte-for-byte unchanged).
    public var meshAssets: [MeshAsset]?
    /// Visual fingerprints recorded along the walk, used to recognise WHERE the user is standing much
    /// faster than ARKit's own feature matching manages in a repetitive corridor (see `Keyframe`).
    /// Empty on maps scanned before this existed; relocalization then behaves exactly as it did.
    public var keyframes: [Keyframe] = []

    public init(
        id: UUID = UUID(),
        name: String,
        version: Int = 1,
        nodes: [MapNode] = [],
        edges: [MapEdge] = [],
        marker: MarkerRef? = nil,
        schemaVersion: Int = MapSchema.current,
        meshAssets: [MeshAsset]? = nil,
        keyframes: [Keyframe] = []
    ) {
        self.meshAssets = meshAssets
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.nodes = nodes
        self.edges = edges
        self.marker = marker
        self.keyframes = keyframes
    }

    // MARK: Decoding (format versioning)

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, version, nodes, edges, marker, meshAssets, keyframes }

    /// Accepts every format from `MapSchema.oldestReadable` to `MapSchema.current` (a missing `schemaVersion` means format 1) and
    /// migrates it to the current one. A file written by a NEWER app is refused with a clear message instead of being half-understood.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let found = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard found >= MapSchema.oldestReadable else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                debugDescription: "Map format \(found) is not valid.")
        }
        guard found <= MapSchema.current else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                debugDescription: "This map uses format \(found), which is newer than this app understands (format \(MapSchema.current)). Update Waypoint.")
        }
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        nodes = try c.decode([MapNode].self, forKey: .nodes)
        edges = try c.decode([MapEdge].self, forKey: .edges)
        marker = try c.decodeIfPresent(MarkerRef.self, forKey: .marker)
        meshAssets = try c.decodeIfPresent([MeshAsset].self, forKey: .meshAssets)
        // `keyframes` (U2's visual fingerprints) is optional on the way IN: every older map decodes with none.
        keyframes = try c.decodeIfPresent([Keyframe].self, forKey: .keyframes) ?? []
        schemaVersion = MapSchema.migrate(from: found)
    }

    // MARK: Queries

    public func node(id: UUID) -> MapNode? {
        nodes.first { $0.id == id }
    }

    /// Distinct segment ids present in the map, sorted (each needs its own ARWorldMap file).
    public var segmentIds: [String] {
        Array(Set(nodes.map(\.segmentId))).sorted()
    }

    /// Nodes a blind user can pick as a destination: anything with a label.
    public var destinations: [MapNode] {
        nodes.filter { ($0.label?.isEmpty == false) && $0.kind != .corridor }
    }

    // MARK: Merging ("anyone can extend a building's map")

    /// Union of two copies of the same building map.
    /// Rules (kept deliberately simple for the hackathon):
    ///  * Nodes are matched by `id`. If both have the same id, `self`'s copy wins.
    ///  * Edges are matched as an unordered pair of node ids. `self`'s copy wins.
    ///  * `marker` prefers `self`'s.
    ///  * Keyframes are unioned by `id`, like nodes.
    ///  * `version` becomes max(self, other) + 1 so peers can tell the merged map is newer.
    ///  * No position reconciliation and no duplicate-label detection (documented limitation).
    public func merged(with other: BuildingMap) -> BuildingMap {
        var result = self

        // Fill absent geometry without changing an existing place or discarding keyframes.
        for incoming in other.nodes {
            if let i = result.nodes.firstIndex(where: { $0.id == incoming.id }), result.nodes[i].extent == nil {
                result.nodes[i].extent = incoming.extent
            }
        }
        let knownNodeIds = Set(nodes.map(\.id))
        for n in other.nodes where !knownNodeIds.contains(n.id) {
            result.nodes.append(n)
        }
        for e in other.edges where !result.edges.contains(where: { $0.connects(e.from, e.to) }) {
            result.edges.append(e)
        }
        // Keyframes union by id, like nodes. Without this an extension scan - or ANY import into a
        // map we already hold - silently threw the incoming ones away, because `MapStore.importBundle`
        // routes through here (found 2026-10-17).
        let knownKeyframeIds = Set(keyframes.map(\.id))
        for k in other.keyframes where !knownKeyframeIds.contains(k.id) {
            result.keyframes.append(k)
        }
        if result.marker == nil { result.marker = other.marker }
        var assets = result.meshAssets ?? []
        for asset in other.meshAssets ?? [] {
            if let i = assets.firstIndex(where: { $0.id == asset.id }) {
                var old = assets[i], incoming = asset
                old.storageOwner = nil; incoming.storageOwner = nil
                if old == incoming, assets[i].storageOwner == nil { assets[i].storageOwner = asset.storageOwner }
            } else { assets.append(asset) }
        }
        if !assets.isEmpty { result.meshAssets = assets }
        result.version = max(version, other.version) + 1
        return result
    }

    // MARK: JSON

    // (Decoding lives above in `init(from:)`: one decoder for the format version, `meshAssets` and U2's `keyframes`, which must stay optional
    //  on the way IN - a stored property with a default is still REQUIRED by Swift's synthesized decoder.)

    /// Pretty, stable-ordered JSON so diffs are readable in git and Live Share.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func from(jsonData: Data) throws -> BuildingMap {
        try JSONDecoder().decode(BuildingMap.self, from: jsonData)
    }
}
