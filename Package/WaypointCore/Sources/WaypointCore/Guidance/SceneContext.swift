//
// File:     Guidance/SceneContext.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback) with C (Vision) as the producer
// Purpose:  What the sensors say about the SURROUNDINGS right now, boiled down to the few facts that change what we should SAY:
//           how much room there is on the left and right (from the LiDAR depth map), and whether the space is narrow. `ObstacleReport`
//           says WHAT is ahead; this says what is AROUND it, so a warning can include a way out ("Open space on your left.").
// Producer: `ObstacleDetector.sideClearances` (Waypoint/Vision) fills a `LateralScan` per frame; the controller turns it into a context.
// Units:    metres, measured SIDEWAYS from the phone (not along the viewing direction), within the next few metres ahead.
//           nil = nothing seen on that side within range = open.
// Status:   DONE (logic, unit tested). UNVERIFIED ON DEVICE for the depth producer.
//
import Foundation

public struct SceneContext: Equatable, Sendable {
    /// Sideways distance to the nearest obstacle on each side, nil = nothing within the scan range (open).
    public var leftClearance: Float?
    public var rightClearance: Float?
    /// Distance to the nearest obstacle straight ahead (same number the obstacle classifier uses), nil = none.
    public var aheadClearance: Float?

    public init(leftClearance: Float? = nil, rightClearance: Float? = nil, aheadClearance: Float? = nil) {
        self.leftClearance = leftClearance
        self.rightClearance = rightClearance
        self.aheadClearance = aheadClearance
    }

    /// Enough room to step aside / walk past (about a body width plus margin).
    public static let passableMeters: Float = 1.0
    /// If the walls on both sides are closer together than this, the space is narrow.
    public static let narrowTotalMeters: Float = 1.4

    public func isOpen(_ side: Side) -> Bool {
        switch side {
        case .left: return (leftClearance ?? .infinity) >= Self.passableMeters
        case .right: return (rightClearance ?? .infinity) >= Self.passableMeters
        case .ahead: return (aheadClearance ?? .infinity) >= 3
        }
    }

    /// Both sides are known and close together (a tight passage). Needs a reading on both sides: "nothing seen" is open, not narrow.
    public var isNarrow: Bool {
        guard let l = leftClearance, let r = rightClearance else { return false }
        return l + r < Self.narrowTotalMeters
    }
}

/// Accumulates the per-pixel samples of one depth frame into left/right clearances. Pure so it can be tested without ARKit.
public struct LateralScan: Sendable {
    /// Only obstacles within this distance ahead count (we care about the next few steps, not the far end of the hall).
    public static let lookaheadMeters: Float = 3
    /// Anything closer to the centre line than this is "ahead", not "beside".
    public static let centreBandMeters: Float = 0.15

    private var left: Float?
    private var right: Float?
    public init() {}

    /// - Parameters:
    ///   - lateral: sideways offset of the sample from the phone, + = user's right, − = left.
    ///   - depth: distance ahead of the phone along the viewing axis.
    public mutating func add(lateral: Float, depth: Float) {
        guard lateral.isFinite, depth.isFinite, depth > 0, depth <= Self.lookaheadMeters else { return }
        if lateral > Self.centreBandMeters { right = min(right ?? .infinity, lateral) }
        else if lateral < -Self.centreBandMeters { left = min(left ?? .infinity, -lateral) }
    }

    public func context(ahead: Float?) -> SceneContext {
        SceneContext(leftClearance: left, rightClearance: right, aheadClearance: ahead)
    }
}

/// Turns the surroundings into a short way-out hint to append to an obstacle warning.
public enum SceneAdvice {

    /// - Returns: e.g. "Open space on your left." / "No room to pass on either side." / nil when there is nothing useful to add.
    public static func hint(for report: ObstacleReport?, context: SceneContext?) -> String? {
        guard let context else { return nil }
        let side = report?.side ?? .ahead
        switch side {
        case .ahead:
            let l = context.isOpen(.left), r = context.isOpen(.right)
            switch (l, r) {
            case (true, true):
                // Prefer the roomier side when we can tell; otherwise just say both are clear.
                let ll = context.leftClearance ?? .infinity, rr = context.rightClearance ?? .infinity
                if abs(ll - rr) < 0.4 || (ll.isInfinite && rr.isInfinite) { return "Clear on both sides." }
                return ll > rr ? "More room on your left." : "More room on your right."
            case (true, false): return "Open space on your left."
            case (false, true): return "Open space on your right."
            case (false, false): return "No room to pass on either side."
            }
        case .left:
            return context.isOpen(.right) ? "Keep to the right." : nil
        case .right:
            return context.isOpen(.left) ? "Keep to the left." : nil
        }
    }
}
