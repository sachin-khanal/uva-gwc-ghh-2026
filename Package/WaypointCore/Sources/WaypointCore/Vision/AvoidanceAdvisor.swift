//
// File:     Vision/AvoidanceAdvisor.swift
// Module:   WaypointCore
// Owner:    C (Vision) with B (guidance)
// Purpose:  Given how far away things are straight ahead, to the left and to the right, decide
//           whether to suggest stepping to one side - so a cue can say WHY it is asking for a turn:
//           "Slightly left, there is a wall ahead."
//
// Safety:   a clearer depth reading is NOT a promise that the floor is safe. Descending stairs, a
//           drop-off or a down ramp all read as "far away". So this suggests, it never commands, and
//           it is deliberately conservative:
//             * it only speaks when the way ahead is actually blocked;
//             * the chosen side must be clearly better than the other, by `decisiveMargin`, not
//               marginally better - a coin-flip between two bad options helps nobody;
//             * the chosen side must itself have real room (`minimumUsable`), so we never send
//               someone toward a second wall;
//             * once a side is chosen it is kept until the way is clear again, so the cue cannot
//               flutter left/right while the user walks.
//           The obstacle STOP behaviour is untouched: this adds a suggestion, it does not replace
//           "Stop."
//
// Status:   DONE (pure logic, unit-tested). Thresholds UNVERIFIED ON DEVICE.
//
import Foundation

public struct AvoidanceAdvisor {

    /// Ahead must be closer than this before we suggest anything at all.
    public var blockedAheadMetres: Float
    /// The side we choose must be at least this much further away than the other side.
    public var decisiveMargin: Float
    /// ...and must have at least this much room itself.
    public var minimumUsable: Float

    private var current: Side?

    public init(blockedAheadMetres: Float = 1.5, decisiveMargin: Float = 0.6, minimumUsable: Float = 1.2) {
        self.blockedAheadMetres = blockedAheadMetres
        self.decisiveMargin = decisiveMargin
        self.minimumUsable = minimumUsable
    }

    /// Distances to the nearest thing in each direction. nil means "nothing seen", which for depth
    /// means open space, not an error.
    public struct Clearance: Equatable, Sendable {
        public var ahead: Float?
        public var left: Float?
        public var right: Float?

        public init(ahead: Float? = nil, left: Float? = nil, right: Float? = nil) {
            self.ahead = ahead
            self.left = left
            self.right = right
        }
    }

    /// `.left` or `.right` to suggest stepping that way, nil to say nothing.
    /// Call once per obstacle update; the result is sticky until the way ahead clears.
    public mutating func advise(_ clearance: Clearance) -> Side? {
        guard let ahead = clearance.ahead, ahead < blockedAheadMetres else {
            current = nil // the way is open again: forget the suggestion so the next one is fresh
            return nil
        }
        // Hold the existing suggestion while still blocked, so it cannot flutter side to side.
        if let current { return current }
        current = Self.bestSide(clearance, blockedAheadMetres: blockedAheadMetres,
                                decisiveMargin: decisiveMargin, minimumUsable: minimumUsable)
        return current
    }

    /// The way ahead is blocked and NEITHER side is a usable way round. Nothing we can see is safe to
    /// walk toward, so the only honest advice is to stop going forward and back off a little.
    ///
    /// Without this the user heard "Stop." and nothing else, with no way out of the situation at all
    /// (device report 2026-10-18, finding F-5). Call it AFTER `advise`, which is the thing that knows
    /// whether a side was found: while a suggestion stands, the user is not boxed in.
    ///
    /// The same safety note applies as to the rest of this type - backing up is suggested because it
    /// retraces ground the user has just walked, which is the only direction we have any evidence
    /// about. It is still a suggestion, not a command.
    public func isBoxedIn(_ clearance: Clearance) -> Bool {
        guard let ahead = clearance.ahead, ahead < blockedAheadMetres else { return false }
        if current != nil { return false } // a way round already stands
        return Self.bestSide(clearance, blockedAheadMetres: blockedAheadMetres,
                             decisiveMargin: decisiveMargin, minimumUsable: minimumUsable) == nil
    }

    public mutating func reset() { current = nil }

    // MARK: Private

    /// The side worth suggesting, or nil when neither is decisively better AND roomy enough. Pure, so
    /// `advise` and `isBoxedIn` can never disagree about what counts as a way round.
    private static func bestSide(_ clearance: Clearance, blockedAheadMetres: Float,
                                 decisiveMargin: Float, minimumUsable: Float) -> Side? {
        // nil = nothing detected that way = open. Treat as comfortably far.
        let openEnough = max(blockedAheadMetres, minimumUsable) * 4
        let left = clearance.left ?? openEnough
        let right = clearance.right ?? openEnough

        let (better, betterDistance, otherDistance): (Side, Float, Float) =
            left > right ? (.left, left, right) : (.right, right, left)

        guard betterDistance >= minimumUsable,
              betterDistance - otherDistance >= decisiveMargin else { return nil }
        return better
    }
}
