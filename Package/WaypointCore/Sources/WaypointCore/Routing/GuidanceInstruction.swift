//
// File:     Routing/GuidanceInstruction.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  The one value passed from routing to feedback: "what should the user do right now".
//           RouteFollower produces it; FeedbackPlanner consumes it; the audio/haptic/speech
//           classes in the app target carry out the resulting actions.
//
import Foundation
import simd

public struct GuidanceInstruction: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        /// Target roughly ahead (within +-25 degrees).
        case continueStraight
        case turnLeft
        case turnRight
        /// Target behind the user (more than 135 degrees off).
        case turnAround
        /// Last node reached.
        case arrived
    }

    public var kind: Kind
    /// Signed radians from the user's facing to the target. Positive = right.
    public var bearingRadians: Float
    /// Floor-plane distance to the target node in meters.
    public var distanceMeters: Float
    public var targetNodeId: UUID
    public var targetLabel: String?
    /// Target position in the MAP frame (the spatial-audio beacon is placed here).
    public var targetPosition: SIMD3<Float>
    /// Hazard on the edge being walked toward the target (e.g. stairs), if any.
    public var hazard: Hazard?

    public init(
        kind: Kind, bearingRadians: Float, distanceMeters: Float,
        targetNodeId: UUID, targetLabel: String?, targetPosition: SIMD3<Float>, hazard: Hazard?
    ) {
        self.kind = kind
        self.bearingRadians = bearingRadians
        self.distanceMeters = distanceMeters
        self.targetNodeId = targetNodeId
        self.targetLabel = targetLabel
        self.targetPosition = targetPosition
        self.hazard = hazard
    }
}
