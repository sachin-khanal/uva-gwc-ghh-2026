//
// File:     Routing/RouteFollower.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Walks a computed route as the user moves. Each call to `update` takes the user's
//           position and facing direction in the MAP frame and returns the current instruction,
//           advancing to the next waypoint once the user is within `arrivalRadius` of it.
// Not here: converting ARKit's world frame to the map frame (Relocalizer.mapToWorld does that)
//           and speaking/vibrating (FeedbackPlanner + app-side guides).
//
import Foundation
import simd

public final class RouteFollower {

    public let route: [MapNode]
    /// A waypoint counts as reached inside this horizontal radius (meters).
    public let arrivalRadius: Float
    /// Angles inside this are "straight ahead"; beyond ~135 degrees is "turn around".
    @available(*, deprecated, message: "Cue classification moved to HeadingCue (hysteresis + debounce).")
    public static let straightThreshold: Float = 25 * .pi / 180
    @available(*, deprecated, message: "Cue classification moved to HeadingCue.")
    public static let turnAroundThreshold: Float = 135 * .pi / 180

    /// Standing in the doorway counts as being in the room.
    public static let doorwayMargin: Float = 0.5

    /// How far ahead along the route we aim. Steering at a point this far away instead of at the next
    /// breadcrumb (~1.5 m) is what stops the cues reacting to every half-step sideways: it follows the
    /// CORRIDOR rather than the exact line the volunteer walked.
    public static let steeringLookaheadMeters: Float = 3.0

    /// Stable cue classification (hysteresis + debounce).
    private var cue = HeadingCue()

    /// Index into `route` of the node we are currently walking toward.
    public private(set) var targetIndex: Int = 0
    private let graph: WaypointGraph

    /// Radius used to step THROUGH intermediate breadcrumbs. Arrival at the destination uses
    /// `ArrivalRadius.meters(for:)` instead, so a room counts as reached from further away than a door.
    public init(route: [MapNode], graph: WaypointGraph, arrivalRadius: Float = 1.0) {
        precondition(!route.isEmpty, "RouteFollower needs a non-empty route")
        self.route = route
        self.graph = graph
        self.arrivalRadius = arrivalRadius
    }

    /// - Parameters:
    ///   - position: user position, MAP frame, meters.
    ///   - forward: direction the user (camera) faces, MAP frame; only x/z are used.
    public func update(position: SIMD3<Float>, forward: SIMD3<Float>) -> GuidanceInstruction {
        // Inside the destination room? Then we are there, however we got in and whatever the follower
        // thinks it is still heading toward. Without this, a target index that has not caught up means
        // standing in the middle of the room never counts as arriving (device report 2026-10-17).
        if let destination = route.last, let extent = destination.extent,
           extent.contains(position, margin: Self.doorwayMargin) {
            targetIndex = route.count - 1
            return GuidanceInstruction(
                kind: .arrived, bearingRadians: 0,
                distanceMeters: Geometry.horizontalDistance(position, destination.position),
                targetNodeId: destination.id, targetLabel: destination.label,
                targetPosition: destination.position, hazard: nil, targetKind: destination.kind)
        }

        // Progress is measured by how far ALONG the route we are, not by touching each waypoint.
        // Proximity alone was the bug behind "turn around... turn around... turn around": walk past a
        // waypoint 1.5 m to one side and the index never advanced, so the follower kept aiming at a
        // point behind the user. Simplified routes made it worse by spacing waypoints further apart.
        targetIndex = max(targetIndex, projectedIndex(for: position))

        // Still skip a waypoint we are literally standing on.
        while targetIndex < route.count - 1,
              Geometry.horizontalDistance(position, route[targetIndex].position) < arrivalRadius {
            targetIndex += 1
        }

        let target = route[targetIndex]
        let distance = Geometry.horizontalDistance(position, target.position)
        let isLast = targetIndex == route.count - 1

        // "Arrived" depends on WHAT the destination is. If the scan worked out the room's floor area
        // we use it literally - you have arrived when you are INSIDE the room, not when you are near
        // the pin the volunteer dropped. Without an extent (older maps, or an open space) we fall
        // back to a radius that depends on the kind of place.
        let reached: Bool = {
            let withinRadius = distance < ArrivalRadius.meters(for: target.kind)
            guard let extent = target.extent else { return withinRadius }
            // EITHER inside the room OR near the pin. Extent-only meant that when the scan measured a
            // room too small - a corner of a big room, say - arrival happened LATER than it used to,
            // which is the "it makes me walk all the way to where I labelled it" report (2026-10-17).
            return extent.contains(position, margin: Self.doorwayMargin) || withinRadius
        }()
        if isLast && reached {
            return GuidanceInstruction(
                kind: .arrived, bearingRadians: 0, distanceMeters: distance,
                targetNodeId: target.id, targetLabel: target.label,
                targetPosition: target.position, hazard: nil, targetKind: target.kind)
        }
        let upcoming = lookahead(from: position, distanceToTarget: distance)

        // Steer at a point further along the route, not at the next breadcrumb, then stabilise the
        // result. Both changes exist because the old code demanded the volunteer's exact line.
        let aim = steeringPoint(from: position, distanceToTarget: distance)
        let bearing = Geometry.signedBearing(forward: forward, toTarget: aim - position)
        let kind = cue.update(bearing: bearing)

        var hazard: Hazard? = nil
        if targetIndex > 0 {
            hazard = graph.edge(between: route[targetIndex - 1].id, target.id)?.hazard
        }

        return GuidanceInstruction(
            kind: kind, bearingRadians: bearing, distanceMeters: distance,
            targetNodeId: target.id, targetLabel: target.label,
            // The beacon is placed at the steering point too, so the sound leads along the corridor
            // instead of jumping between breadcrumbs.
            targetPosition: aim, hazard: hazard,
            upcoming: upcoming, landmark: landmark(at: position, forward: forward, excluding: target.id),
            targetKind: target.kind)
    }

    /// How many segments ahead we are willing to jump in one tick. A route that passes near itself
    /// (a corridor you come back along) must not teleport progress to the far pass, so we only ever
    /// look a little way ahead of where we already are.
    public static let progressWindow = 4
    /// Ignore the projection entirely if the nearest segment is further away than this: the user has
    /// wandered off the route and the right answer is to guide them back, not to skip ahead.
    public static let maxOffRouteMeters: Float = 8

    /// The waypoint we should be heading to, judged by projecting the user onto the route polyline.
    /// Never goes backwards (the caller takes `max` with the current index).
    func projectedIndex(for position: SIMD3<Float>) -> Int {
        guard route.count > 1 else { return targetIndex }
        // The segment we are ON is the one ENDING at the current target, i.e. targetIndex - 1.
        // Starting the search at targetIndex instead looks only at segments ahead, so the nearest of
        // them always wins and progress jumps straight to the destination. (Caught by the end-to-end
        // walk test, which started announcing "you will arrive" nine metres early.)
        let first = max(0, targetIndex - 1)
        let last = min(route.count - 2, targetIndex + Self.progressWindow)
        guard first <= last else { return targetIndex }

        var bestIndex = first
        var bestDistance = Float.greatestFiniteMagnitude
        for i in first...last {
            let d = RouteSimplifier.perpendicularDistance(position,
                                                          from: route[i].position,
                                                          to: route[i + 1].position)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }
        guard bestDistance <= Self.maxOffRouteMeters else { return targetIndex }
        // We are on segment bestIndex -> bestIndex+1, so the point we are walking toward is its end.
        return bestIndex + 1
    }

    /// How far the user is from the route polyline, floor plane. Used to decide when to re-route.
    public func distanceFromRoute(position: SIMD3<Float>) -> Float {
        guard route.count > 1 else {
            return route.first.map { Geometry.horizontalDistance(position, $0.position) } ?? 0
        }
        return (0..<(route.count - 1)).map {
            RouteSimplifier.perpendicularDistance(position, from: route[$0].position, to: route[$0 + 1].position)
        }.min() ?? 0
    }

    /// A point `steeringLookaheadMeters` further along the route: the "carrot" the user walks toward.
    /// Falls back to the last node when the route runs out, so the final approach aims at the destination.
    func steeringPoint(from position: SIMD3<Float>, distanceToTarget: Float) -> SIMD3<Float> {
        var along = distanceToTarget
        var k = targetIndex
        while k < route.count - 1, along < Self.steeringLookaheadMeters {
            along += Geometry.horizontalDistance(route[k].position, route[k + 1].position)
            k += 1
        }
        return route[k].position
    }

    // MARK: Look-ahead and landmarks

    /// A heading change of more than this between two route segments counts as a turn.
    public static let turnThreshold: Float = 35 * .pi / 180
    /// How far ahead (metres along the route) we look for the next maneuver.
    public static let lookaheadMeters: Float = 40
    /// A labelled node closer than this to the user is "abeam" and gets announced.
    public static let landmarkRadius: Float = 2.5

    /// The next turn, stairs, or the arrival, measured ALONG the route from the user's position.
    func lookahead(from position: SIMD3<Float>, distanceToTarget: Float) -> Maneuver? {
        var along = distanceToTarget
        var k = targetIndex
        while k < route.count, along <= Self.lookaheadMeters {
            let node = route[k]
            if k == route.count - 1 {
                return Maneuver(kind: .arrive, distanceMeters: along, nodeId: node.id, label: node.label)
            }
            let next = route[k + 1]
            // Stairs: the edge LEAVING this node is a stairs edge -> the stairs start at this node.
            if graph.edge(between: node.id, next.id)?.hazard == .stairs {
                return Maneuver(kind: .stairs, distanceMeters: along, nodeId: node.id, label: next.label)
            }
            // Turn at this node: compare the segment arriving here with the segment leaving.
            let incoming = k > 0 ? node.position - route[k - 1].position : node.position - position
            let outgoing = next.position - node.position
            let angle = Geometry.signedBearing(forward: incoming, toTarget: outgoing)
            if abs(angle) > Self.turnThreshold {
                return Maneuver(kind: angle > 0 ? .turnRight : .turnLeft, distanceMeters: along,
                                nodeId: node.id, label: node.label, angleRadians: angle)
            }
            along += Geometry.horizontalDistance(node.position, next.position)
            k += 1
        }
        return nil
    }

    /// The nearest labelled place (room, door, stairs...) that is beside the user: close, and roughly 50-130 degrees to the left or right.
    func landmark(at position: SIMD3<Float>, forward: SIMD3<Float>, excluding targetId: UUID) -> Landmark? {
        var best: (node: MapNode, side: Side, distance: Float)?
        for node in graph.map.nodes where node.kind != .corridor && node.id != targetId && node.id != route.last?.id {
            guard let label = node.label, !label.isEmpty else { continue }
            let d = Geometry.horizontalDistance(position, node.position)
            guard d < Self.landmarkRadius else { continue }
            let bearing = Geometry.signedBearing(forward: forward, toTarget: node.position - position)
            let degrees = abs(bearing) * 180 / .pi
            guard degrees >= 50, degrees <= 130 else { continue }
            if best == nil || d < best!.distance { best = (node, bearing > 0 ? .right : .left, d) }
        }
        return best.flatMap { b in b.node.label.map { Landmark(label: $0, side: b.side, nodeId: b.node.id) } }
    }
}
