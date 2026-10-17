//
// File:     Routing/Router.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  A* shortest path over a `WaypointGraph`.
//           Cost of an edge = its `distance`, plus `stairsPenalty` if it is a stairs edge and the
//           caller did not allow stairs. Stairs are penalised rather than forbidden so a route
//           still exists when stairs are the only way (the planner will warn about them).
// Heuristic: straight-line distance between nodes. Admissible as long as edge.distance >= the
//           straight-line distance, which is true for builder-made edges. Hand-written JSON that
//           violates this can produce a slightly sub-optimal (never invalid) route.
// Complexity: linear scan for the open-set minimum; fine for the < 500 nodes we will ever have.
//
import Foundation
import simd

public enum Router {

    /// Added to the cost of stairs edges when `allowStairs == false`. 1000 m ~ "only if no other way".
    public static let stairsPenalty: Float = 1000

    /// Returns the ordered nodes from `start` to `goal` inclusive, or nil if unreachable / unknown ids.
    ///
    /// The result is passed through `RouteSimplifier` by default. A* is optimal over the graph, but the
    /// graph is a trail of where the volunteer WALKED, so the optimal path on it still contains their
    /// detours and doubling-back. Pass `simplify: false` to see the raw graph path (debugging).
    public static func route(
        in graph: WaypointGraph,
        from start: UUID,
        to goal: UUID,
        allowStairs: Bool = false,
        simplify: Bool = true
    ) -> [MapNode]? {
        guard let startNode = graph.node(id: start), let goalNode = graph.node(id: goal) else { return nil }
        if start == goal { return [startNode] }

        var gScore: [UUID: Float] = [start: 0]
        var fScore: [UUID: Float] = [start: simd_distance(startNode.position, goalNode.position)]
        var cameFrom: [UUID: UUID] = [:]
        var open: Set<UUID> = [start]
        var closed: Set<UUID> = []

        while let current = open.min(by: { (fScore[$0] ?? .infinity) < (fScore[$1] ?? .infinity) }) {
            if current == goal {
                let path = reconstruct(cameFrom: cameFrom, current: current, graph: graph)
                guard simplify else { return path }
                // Both ends of a hazard edge must survive simplification, or the stairs warning is
                // thinned away with the node that carried it.
                var protected: Set<UUID> = []
                for i in 0..<max(0, path.count - 1) {
                    if graph.edge(between: path[i].id, path[i + 1].id)?.hazard != nil {
                        protected.insert(path[i].id)
                        protected.insert(path[i + 1].id)
                    }
                }
                return RouteSimplifier.simplify(path, protecting: protected)
            }
            open.remove(current)
            closed.insert(current)

            for (neighbour, edge) in graph.neighbours(of: current) {
                if closed.contains(neighbour.id) { continue }
                var cost = edge.distance
                if edge.hazard == .stairs && !allowStairs { cost += stairsPenalty }
                let tentative = (gScore[current] ?? .infinity) + cost
                if tentative < (gScore[neighbour.id] ?? .infinity) {
                    cameFrom[neighbour.id] = current
                    gScore[neighbour.id] = tentative
                    fScore[neighbour.id] = tentative + simd_distance(neighbour.position, goalNode.position)
                    open.insert(neighbour.id)
                }
            }
        }
        return nil
    }

    private static func reconstruct(
        cameFrom: [UUID: UUID], current: UUID, graph: WaypointGraph
    ) -> [MapNode] {
        var path: [UUID] = [current]
        var cursor = current
        while let prev = cameFrom[cursor] {
            path.append(prev)
            cursor = prev
        }
        return path.reversed().compactMap { graph.node(id: $0) }
    }
}
