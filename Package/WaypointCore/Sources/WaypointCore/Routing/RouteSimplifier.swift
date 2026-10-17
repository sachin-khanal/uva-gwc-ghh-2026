//
// File:     Routing/RouteSimplifier.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Turns the A* result into a path a PERSON would walk.
//
// Why:      A* is optimal over the graph, but the graph is a trail of where the volunteer walked -
//           every detour, every time they stepped back to tag something, every wander. Walking that
//           trail literally produced "straight, turn right, turn around, straight" where the real
//           route was "straight, then left" (device report 2026-10-17). The pathfinder was never
//           wrong; it was being asked to follow footsteps.
//
// Two passes:
//   1. DETOUR REMOVAL - if the path comes back within `shortcutRadius` of somewhere it has already
//      been, everything in between was a loop or a there-and-back, and is dropped.
//   2. THINNING - drop a node when leaving it out moves the path less than `tolerance`, so a gentle
//      curve of breadcrumbs becomes one straight leg and the user hears one instruction, not six.
//
// SAFETY: both passes stay INSIDE the walked path. Thinning never moves the route more than
//         `tolerance` (well under a corridor's width) from the line the volunteer actually walked,
//         and detour removal only collapses a return to a place they already stood. We never cut a
//         corner we have no evidence is walkable - that is how you route someone into a wall.
//         A node that MEANS something is never removed: anything tagged (a door, a room, stairs),
//         anything with a label, and anything the caller protects (e.g. both ends of a stairs edge).
//         Only plain unlabelled breadcrumbs are collapsed. Caught by a test: an early version thinned
//         a stairs node away and the hazard warning disappeared with it.
//
// Status:   DONE (pure logic, unit-tested).
//
import Foundation
import simd

public enum RouteSimplifier {

    /// Coming back within this distance of an earlier point means the path doubled back.
    public static let defaultShortcutRadius: Float = 1.2
    /// How far the simplified path may sit from the original. Must stay well under a corridor width.
    public static let defaultTolerance: Float = 0.6

    /// - Parameter protected: extra node ids that must survive, whatever their shape contributes.
    ///   `Router` passes the endpoints of every hazard edge so a stairs warning can never be thinned away.
    public static func simplify(
        _ route: [MapNode],
        protecting protected: Set<UUID> = [],
        shortcutRadius: Float = defaultShortcutRadius,
        tolerance: Float = defaultTolerance
    ) -> [MapNode] {
        guard route.count > 2 else { return route }
        let keep: (MapNode) -> Bool = { node in
            node.kind != .corridor || node.label != nil || protected.contains(node.id)
        }
        return thin(removeDetours(route, shortcutRadius: shortcutRadius, keep: keep),
                    tolerance: tolerance, keep: keep)
    }

    /// Pass 1: collapse any stretch that returns to where it has already been.
    static func removeDetours(_ route: [MapNode], shortcutRadius: Float,
                              keep: (MapNode) -> Bool = { _ in false }) -> [MapNode] {
        var result: [MapNode] = []
        var i = 0
        while i < route.count {
            result.append(route[i])
            // The LAST later point that is still near this one: everything up to it was a round trip.
            // A detour that passes something worth keeping (stairs, a door) is NOT collapsed.
            var jump = i
            for j in stride(from: route.count - 1, to: i, by: -1) {
                guard Geometry.horizontalDistance(route[i].position, route[j].position) <= shortcutRadius else { continue }
                if route[(i + 1)...j].contains(where: keep) { break }
                jump = j
                break
            }
            i = (jump > i) ? jump + 1 : i + 1
        }
        // The destination is never optional, even if it sat inside a collapsed stretch.
        if let last = route.last, result.last?.id != last.id { result.append(last) }
        return result
    }

    /// Pass 2: drop nodes that add nothing to the shape of the path.
    static func thin(_ route: [MapNode], tolerance: Float,
                     keep: (MapNode) -> Bool = { _ in false }) -> [MapNode] {
        guard route.count > 2 else { return route }
        var result: [MapNode] = [route[0]]
        for k in 1..<(route.count - 1) {
            if keep(route[k]) { result.append(route[k]); continue }
            let anchor = result[result.count - 1]
            let next = route[k + 1]
            if perpendicularDistance(route[k].position, from: anchor.position, to: next.position) >= tolerance {
                result.append(route[k])
            }
        }
        result.append(route[route.count - 1])
        return result
    }

    /// Floor-plane distance from `point` to the segment `a`-`b`.
    static func perpendicularDistance(_ point: SIMD3<Float>, from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        let p = SIMD2<Float>(point.x, point.z)
        let a2 = SIMD2<Float>(a.x, a.z)
        let b2 = SIMD2<Float>(b.x, b.z)
        let ab = b2 - a2
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-6 else { return simd_distance(p, a2) }
        // Clamped projection, so a point beyond either end measures to that end, not to the infinite line.
        let t = max(0, min(1, simd_dot(p - a2, ab) / lengthSquared))
        return simd_distance(p, a2 + t * ab)
    }
}
