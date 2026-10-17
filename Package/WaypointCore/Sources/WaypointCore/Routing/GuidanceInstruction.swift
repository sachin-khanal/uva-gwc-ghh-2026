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

/// The next thing that will need the user's attention along the route, and how far along the ROUTE it is (not straight-line).
public struct Maneuver: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case turnLeft, turnRight, stairs, arrive }
    public var kind: Kind
    public var distanceMeters: Float
    public var nodeId: UUID
    public var label: String?

    public init(kind: Kind, distanceMeters: Float, nodeId: UUID, label: String? = nil) {
        self.kind = kind
        self.distanceMeters = distanceMeters
        self.nodeId = nodeId
        self.label = label
    }
}

/// A labelled place the user is passing right now (e.g. "Room 206" on the right).
public struct Landmark: Equatable, Sendable {
    public var label: String
    public var side: Side
    public var nodeId: UUID

    public init(label: String, side: Side, nodeId: UUID) {
        self.label = label
        self.side = side
        self.nodeId = nodeId
    }
}

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
    /// The next turn / stairs / arrival ahead along the route (look-ahead), for "In 5 meters, turn right".
    public var upcoming: Maneuver?
    /// A labelled place abeam of the user right now, for "Room 206 on your right".
    public var landmark: Landmark?

    public init(
        kind: Kind, bearingRadians: Float, distanceMeters: Float,
        targetNodeId: UUID, targetLabel: String?, targetPosition: SIMD3<Float>, hazard: Hazard?,
        upcoming: Maneuver? = nil, landmark: Landmark? = nil
    ) {
        self.kind = kind
        self.bearingRadians = bearingRadians
        self.distanceMeters = distanceMeters
        self.targetNodeId = targetNodeId
        self.targetLabel = targetLabel
        self.targetPosition = targetPosition
        self.hazard = hazard
        self.upcoming = upcoming
        self.landmark = landmark
    }
}
