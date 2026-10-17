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
            targetPosition: target.position, hazard: hazard)
    }
}
