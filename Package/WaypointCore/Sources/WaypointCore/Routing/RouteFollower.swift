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
    public static let straightThreshold: Float = 25 * .pi / 180
    public static let turnAroundThreshold: Float = 135 * .pi / 180

    /// Index into `route` of the node we are currently walking toward.
    public private(set) var targetIndex: Int = 0
    private let graph: WaypointGraph

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
        // Skip every waypoint the user is already standing on.
        while targetIndex < route.count - 1,
              Geometry.horizontalDistance(position, route[targetIndex].position) < arrivalRadius {
            targetIndex += 1
        }

        let target = route[targetIndex]
        let distance = Geometry.horizontalDistance(position, target.position)
        let isLast = targetIndex == route.count - 1

        if isLast && distance < arrivalRadius {
            return GuidanceInstruction(
                kind: .arrived, bearingRadians: 0, distanceMeters: distance,
                targetNodeId: target.id, targetLabel: target.label,
                targetPosition: target.position, hazard: nil)
        }
        let upcoming = lookahead(from: position, distanceToTarget: distance)

        let bearing = Geometry.signedBearing(forward: forward, toTarget: target.position - position)
        let kind: GuidanceInstruction.Kind
        switch abs(bearing) {
        case ..<Self.straightThreshold: kind = .continueStraight
        case Self.turnAroundThreshold...: kind = .turnAround
        default: kind = bearing > 0 ? .turnRight : .turnLeft
        }

        var hazard: Hazard? = nil
        if targetIndex > 0 {
            hazard = graph.edge(between: route[targetIndex - 1].id, target.id)?.hazard
        }

        return GuidanceInstruction(
            kind: kind, bearingRadians: bearing, distanceMeters: distance,
            targetNodeId: target.id, targetLabel: target.label,
            targetPosition: target.position, hazard: hazard,
            upcoming: upcoming, landmark: landmark(at: position, forward: forward, excluding: target.id))
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
                return Maneuver(kind: angle > 0 ? .turnRight : .turnLeft, distanceMeters: along, nodeId: node.id, label: node.label)
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
