//
// File:     Routing/StartGate.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Decides WHEN the first route may be computed after relocalization.
//
// Why:      `NavigationController` builds its `RouteFollower` once, on the first tick where tracking
//           is OK, and never rebuilds it. Right after relocalization the pose is still converging, so
//           that first position can be metres away from where the user actually stands - typically
//           near the session origin, i.e. where the VOLUNTEER started scanning. The nearest node is
//           then the mapping start, the route is computed from there, and the user is walked back to
//           the beginning of the scan before heading to their destination. Reported on device
//           2026-10-17; it is a race, so it does not happen every time.
//
// Rule:     require `requiredStableTicks` consecutive ticks that are all tracking-OK AND within
//           `maxJumpMeters` of the previous tick's position. A converging pose jumps; a settled one
//           does not. Any bad tick starts the count again.
//
// Status:   DONE (pure logic, unit-tested in RoutingTests).
//
import Foundation
import simd

public struct StartGate {

    /// Consecutive good ticks needed before the position is trusted. At ~60 Hz (ARKit) 10 ticks is
    /// about 0.17 s; the simulator runs at 10 Hz, where it is 1 s.
    public var requiredStableTicks: Int
    /// A bigger move than this between two ticks means the pose is still converging, not that the
    /// user sprinted. 0.35 m per tick is far faster than a person walks at either tick rate.
    public var maxJumpMeters: Float

    private var stableTicks = 0
    private var lastPosition: SIMD3<Float>?

    public init(requiredStableTicks: Int = 10, maxJumpMeters: Float = 0.35) {
        self.requiredStableTicks = requiredStableTicks
        self.maxJumpMeters = maxJumpMeters
    }

    /// True once the pose has been stable long enough to compute a route from it.
    /// Call once per tick, in order.
    public mutating func update(position: SIMD3<Float>, trackingOK: Bool) -> Bool {
        guard trackingOK, position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            reset()
            return false
        }
        if let last = lastPosition, Geometry.horizontalDistance(last, position) <= maxJumpMeters {
            stableTicks += 1
        } else {
            stableTicks = 1 // first sample, or it jumped: this tick starts a new run
        }
        lastPosition = position
        return stableTicks >= requiredStableTicks
    }

    /// Forget the run (new navigation, or tracking was lost).
    public mutating func reset() {
        stableTicks = 0
        lastPosition = nil
    }
}
