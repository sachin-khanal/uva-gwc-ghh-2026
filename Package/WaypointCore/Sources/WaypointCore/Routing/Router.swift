//
// File:     Routing/Router.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  A* shortest path over a `WaypointGraph`.
//           Cost of an edge = its `distance`, plus `stairsPenalty` if it is a stairs edge and the
//           caller did not allow stairs. Stairs are penalised rather than forbidden so a route
//           still exists when stairs are the only way (the planner will warn about them).
//           `avoiding` removes edges entirely (live blockages, see RoutePlanner).
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

    /// How many nearby nodes `bestRoute` will try as a starting point.
    public static let startCandidates = 8

    /// Walking length of a route, floor plane.
    public static func length(of route: [MapNode]) -> Float {
        guard route.count > 1 else { return 0 }
        return (0..<(route.count - 1)).reduce(Float(0)) {
            $0 + Geometry.horizontalDistance(route[$1].position, route[$1 + 1].position)
        }
    }

    /// The best route from where the user actually STANDS, rather than from whichever node happens to
    /// be nearest.
    ///
    /// Why: on a loop corridor the nearest node can be on the wrong branch - a metre away but facing
    /// the long way round - and routing from it sent the user all the way around the core when the
    /// other direction was far shorter (device report 2026-10-17). We try several nearby nodes and
    /// keep the one with the smallest total of "walk to that node" plus "route from it".
    public static func bestRoute(
        in graph: WaypointGraph,
        from position: SIMD3<Float>,
        to goal: UUID,
        allowStairs: Bool = false,
        candidates: Int = startCandidates
    ) -> [MapNode]? {
        var best: [MapNode]?
        var bestCost = Float.greatestFiniteMagnitude
        for start in graph.nearestNodes(to: position, limit: candidates) {
            guard let route = route(in: graph, from: start.id, to: goal, allowStairs: allowStairs) else { continue }
            let cost = Geometry.horizontalDistance(position, start.position) + length(of: route)
            if cost < bestCost {
                bestCost = cost
                best = route
            }
        }
        return best
    }

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
        avoiding blocked: Set<EdgeKey> = [],
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
                return simplify ? Self.simplified(path, in: graph) : path
            }
            open.remove(current)
            closed.insert(current)

            for (neighbour, edge) in graph.neighbours(of: current) {
                if closed.contains(neighbour.id) { continue }
                // Live-reported blockage (obstacle, closed door...): the edge does not exist for now.
                if !blocked.isEmpty, blocked.contains(EdgeKey(current, neighbour.id)) { continue }
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

    /// `RouteSimplifier` over a raw graph path, keeping both ends of every hazard edge so a stairs warning is not thinned away with its node.
    public static func simplified(_ path: [MapNode], in graph: WaypointGraph) -> [MapNode] {
        var protected: Set<UUID> = []
        for i in 0..<max(0, path.count - 1) where graph.edge(between: path[i].id, path[i + 1].id)?.hazard != nil {
            protected.insert(path[i].id)
            protected.insert(path[i + 1].id)
        }
        return RouteSimplifier.simplify(path, protecting: protected)
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
