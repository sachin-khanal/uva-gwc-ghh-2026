//
// File:     Routing/WaypointGraph.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Read-only graph view over a `BuildingMap` with the lookups routing needs:
//           neighbours, edge between two nodes, nearest node to a position, and fuzzy label search
//           ("room204", "Room 204" and "204" all find the node labelled "Room 204").
//
import Foundation
import simd

public struct WaypointGraph {

    public let map: BuildingMap
    private let nodesById: [UUID: MapNode]
    /// node id -> [(neighbour id, the edge)]. Edges are undirected so each appears under both ends.
    private let adjacency: [UUID: [(UUID, MapEdge)]]

    public init(map: BuildingMap) {
        self.map = map
        var nodes: [UUID: MapNode] = [:]
        for n in map.nodes { nodes[n.id] = n }
        var adj: [UUID: [(UUID, MapEdge)]] = [:]
        for e in map.edges {
            // Ignore edges that reference missing nodes (a hand-edited JSON typo must not crash).
            guard nodes[e.from] != nil, nodes[e.to] != nil else { continue }
            adj[e.from, default: []].append((e.to, e))
            adj[e.to, default: []].append((e.from, e))
        }
        self.nodesById = nodes
        self.adjacency = adj
    }

    public func node(id: UUID) -> MapNode? { nodesById[id] }

    public func neighbours(of id: UUID) -> [(node: MapNode, edge: MapEdge)] {
        (adjacency[id] ?? []).compactMap { (nid, edge) in
            nodesById[nid].map { ($0, edge) }
        }
    }

    public func edge(between a: UUID, _ b: UUID) -> MapEdge? {
        adjacency[a]?.first { $0.0 == b }?.1
    }

    /// Node closest to `position` in 3D, optionally restricted to a set of kinds.
    public func nearestNode(to position: SIMD3<Float>) -> MapNode? {
        map.nodes.min { simd_distance($0.position, position) < simd_distance($1.position, position) }
    }

    /// The `limit` nodes closest to `position`, nearest first.
    /// Routing uses this rather than the single nearest node: on a loop corridor the closest node can
    /// sit on the wrong branch, and starting there sends the user the long way round (device report
    /// 2026-10-17).
    public func nearestNodes(to position: SIMD3<Float>, limit: Int) -> [MapNode] {
        map.nodes
            .sorted { simd_distance($0.position, position) < simd_distance($1.position, position) }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// Case/space/punctuation-insensitive substring search over node labels.
    public func nodes(matchingLabel query: String) -> [MapNode] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        return map.nodes.filter { n in
            guard let label = n.label else { return false }
            return Self.normalize(label).contains(q)
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
