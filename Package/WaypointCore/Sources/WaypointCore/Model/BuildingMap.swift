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

public struct BuildingMap: Codable, Identifiable, Equatable, Sendable {

    /// Bump when the JSON shape changes incompatibly, and note it in docs/WORKLOG.md.
    /// 2 (2026-10-17): `MapNode.extent` added. The field is optional, so schema-1 maps still decode;
    /// they simply have no room extents and fall back to `ArrivalRadius`.
    /// 3 (2026-10-17): `keyframes` added for faster relocalization. Also optional with a default, so
    /// every older map still decodes and simply has none.
    public static let schemaVersion = 3

    public var id: UUID
    /// Display name, e.g. "Rice Hall, floor 1".
    public var name: String
    /// Increments every time the map is saved after being extended. Sync uses it to decide who is newer.
    public var version: Int
    public var nodes: [MapNode]
    public var edges: [MapEdge]
    /// Optional fallback relocalization marker (see MarkerRef).
    public var marker: MarkerRef?
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
        keyframes: [Keyframe] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.nodes = nodes
        self.edges = edges
        self.marker = marker
        self.keyframes = keyframes
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
        result.version = max(version, other.version) + 1
        return result
    }

    // MARK: JSON

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey { case id, name, version, nodes, edges, marker, keyframes }

    /// Written by hand for ONE reason: `keyframes` must be optional on the way IN.
    /// A property with a default value is still REQUIRED by Swift's synthesized decoder, so adding it
    /// made every existing map fail to load with "Key 'keyframes' not found" - caught by the test
    /// suite, and exactly the breakage this project cannot afford (2026-10-17).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        nodes = try c.decode([MapNode].self, forKey: .nodes)
        edges = try c.decode([MapEdge].self, forKey: .edges)
        marker = try c.decodeIfPresent(MarkerRef.self, forKey: .marker)
        keyframes = try c.decodeIfPresent([Keyframe].self, forKey: .keyframes) ?? []
    }

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
