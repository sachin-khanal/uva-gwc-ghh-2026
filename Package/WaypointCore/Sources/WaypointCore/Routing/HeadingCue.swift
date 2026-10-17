//
// File:     Routing/HeadingCue.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Turns a continuously wobbling bearing into a STABLE spoken cue.
//
// Why:      The follower used to classify the raw bearing to the next breadcrumb every tick with a
//           single 25-degree threshold. Breadcrumbs sit ~1.5 m apart, so half a step sideways swings
//           that bearing a long way and the user heard "go left, go right, turn around" while walking
//           normally down a corridor - the app demanding the exact line the volunteer walked instead
//           of a natural, obstacle-free path. Reported on device 2026-10-17.
//
// How:      * wide deadband with HYSTERESIS: it takes `enter` degrees off-course to start calling a
//             turn, but only `exit` degrees to go back to "straight", so a cue cannot flutter;
//           * DEBOUNCE: a new cue must persist for `requiredTicks` before it is announced at all;
//           * turn-around needs a big angle, because telling someone to reverse is disruptive.
//
// Status:   DONE (pure logic, unit-tested).
//
import Foundation

public struct HeadingCue {

    public typealias Kind = GuidanceInstruction.Kind

    /// Off-course angle needed to START calling a turn.
    public var enterRadians: Float
    /// Off-course angle at which we go back to "continue straight" (must be < enter).
    public var exitRadians: Float
    /// Angle needed to say "turn around".
    public var turnAroundRadians: Float
    /// Consecutive ticks a new cue must hold before it is used.
    public var requiredTicks: Int

    private var current: Kind = .continueStraight
    private var pending: Kind?
    private var pendingTicks = 0
    /// The FIRST cue is not debounced: a user who starts facing the wrong way must be told at once,
    /// and a first cue cannot be flutter (there is nothing for it to flutter against).
    private var started = false

    public init(
        enterDegrees: Float = 45,
        exitDegrees: Float = 22,
        turnAroundDegrees: Float = 150,
        requiredTicks: Int = 3
    ) {
        self.enterRadians = enterDegrees * .pi / 180
        self.exitRadians = exitDegrees * .pi / 180
        self.turnAroundRadians = turnAroundDegrees * .pi / 180
        self.requiredTicks = requiredTicks
    }

    /// `bearing` is signed radians from the user's facing to where they should head (positive = right).
    public mutating func update(bearing: Float) -> Kind {
        let desired = raw(bearing: bearing)
        if !started {
            started = true
            current = desired
            return current
        }
        if desired == current {
            pending = nil
            pendingTicks = 0
            return current
        }
        if desired == pending {
            pendingTicks += 1
        } else {
            pending = desired
            pendingTicks = 1
        }
        if pendingTicks >= requiredTicks {
            current = desired
            pending = nil
            pendingTicks = 0
        }
        return current
    }

    /// What the bearing says right now, before debouncing.
    private func raw(bearing: Float) -> Kind {
        let magnitude = abs(bearing)
        if magnitude >= turnAroundRadians { return .turnAround }
        let isTurning = (current == .turnLeft || current == .turnRight || current == .turnAround)
        // Hysteresis: while already turning, keep the turn until we are comfortably back on course.
        let threshold = isTurning ? exitRadians : enterRadians
        guard magnitude >= threshold else { return .continueStraight }
        return bearing > 0 ? .turnRight : .turnLeft
    }

    public mutating func reset() {
        current = .continueStraight
        pending = nil
        pendingTicks = 0
        started = false
    }
}

/// How close counts as "arrived", per kind of destination.
///
/// A door is a specific thing you stand in front of; a room is a space you are inside. The map has no
/// room EXTENT (a `MapNode` is a single point), so a room uses a generous radius as a stand-in for its
/// bounding box. If rooms ever need true extents that is a change to the shared model, not here.
public enum ArrivalRadius {

    public static func meters(for kind: NodeKind?) -> Float {
        switch kind {
        case .room: return 2.5
        case .door: return 1.2
        case .stairs, .elevator: return 1.5
        case .corridor, .junction, .none: return 1.0
        }
    }
}
