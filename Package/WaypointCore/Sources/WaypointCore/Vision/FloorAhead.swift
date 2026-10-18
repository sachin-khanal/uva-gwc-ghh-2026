//
// File:     Vision/FloorAhead.swift
// Module:   WaypointCore
// Owner:    C (Vision) with B (guidance)
// Purpose:  Decide whether the floor in front of the user CONTINUES, or FALLS AWAY - descending stairs,
//           a kerb, a loading dock, the edge of a landing.
//
// Why:      everything else in this app looks for things that STICK UP. `ObstacleBand` keeps depth
//           samples between roughly knee height and just above the phone, and anything inside that band
//           is an obstacle. A staircase going DOWN puts nothing in that band - the floor simply stops -
//           so the most dangerous thing in a building reads as beautifully clear corridor, and a blind
//           user walking toward it is told nothing at all. `ObstacleDetector`'s own header has carried
//           "TODO(C): stairs-down and ledges (need a downward check)" since it was written.
//
// Method:   the caller samples the depth map BELOW the viewing axis and reports, for each sample, how
//           far ahead it is and how high it is. Here we compare those heights against the floor the
//           user is standing on. A surface well below that floor inside the look-ahead is a drop; floor
//           that simply vanishes (returns stop coming back) is reported separately, because that is
//           what a down staircase looks like from the top when the treads are edge-on to the sensor.
//
// Safety:   this errs toward WARNING. A false "step down ahead" costs the user a pause; a missed one
//           costs them a fall. Where the evidence is thin we say `unsure` rather than `continuous`, and
//           the caller decides how loud to be - `continuous` is only returned when floor was actually
//           seen all the way out.
//
// Units:    metres. `ahead` is distance along the floor; `y` is world height, same frame as the camera.
// Status:   DONE (pure logic, unit-tested). The depth sampler that feeds it is app-side and
//           UNVERIFIED ON DEVICE.
//
import Foundation

/// One sample of the floor in front of the user.
public struct FloorSample: Equatable, Sendable {
    /// Horizontal distance from the user, metres.
    public var ahead: Float
    /// World height of the surface found there.
    public var y: Float

    public init(ahead: Float, y: Float) {
        self.ahead = ahead
        self.y = y
    }
}

public enum FloorAhead {

    /// How far ahead we care about. Beyond this a drop is not yet the user's problem, and the depth
    /// map is too sparse to trust anyway.
    public static let lookaheadMeters: Float = 2.5
    /// A surface this far below the standing floor is a step DOWN, not floor. A single stair tread is
    /// about 0.17 m, so this catches one step while ignoring carpet, thresholds and sensor noise.
    public static let dropMeters: Float = 0.12
    /// Below this, a drop is a kerb or a single step; at or beyond it, treat it as stairs or a ledge.
    public static let stairsDropMeters: Float = 0.35
    /// Floor must be seen at least this far out before we are willing to say "continuous". Less than
    /// this and the sensor simply has not told us anything about where the user is walking.
    public static let minimumConfirmedMeters: Float = 1.2

    public enum Verdict: Equatable, Sendable {
        /// Floor seen, unbroken, out to the look-ahead.
        case continuous
        /// The floor drops away. `atMeters` is how far ahead the edge is, `byMeters` how far down.
        case drop(atMeters: Float, byMeters: Float)
        /// Not enough floor came back to say either way. Treated as "slow down", never as "clear":
        /// from the top of a staircase the treads are edge-on and return almost nothing, so this is
        /// exactly what a down staircase can look like.
        case unsure
    }

    /// - Parameters:
    ///   - samples: floor points in front of the user, any order.
    ///   - standingFloorY: world height of the floor under the user's feet.
    public static func verdict(samples: [FloorSample], standingFloorY: Float) -> Verdict {
        guard standingFloorY.isFinite else { return .unsure }
        let usable = samples.filter {
            $0.ahead.isFinite && $0.y.isFinite && $0.ahead > 0 && $0.ahead <= lookaheadMeters
        }
        guard !usable.isEmpty else { return .unsure }

        // The NEAREST drop is the one that matters: a staircase read from the top gives samples on
        // several treads at once, and the user meets the top one first.
        let drops = usable.filter { standingFloorY - $0.y >= dropMeters }
        if let nearest = drops.min(by: { $0.ahead < $1.ahead }) {
            // How far down does it actually go? The deepest sample at or beyond the edge, so one
            // step and a whole flight are told apart.
            let deepest = drops.filter { $0.ahead >= nearest.ahead - 0.05 }
                .map { standingFloorY - $0.y }
                .max() ?? (standingFloorY - nearest.y)
            return .drop(atMeters: nearest.ahead, byMeters: deepest)
        }

        // No drop seen. Only claim the floor is good if we actually saw it far enough out.
        let furthestFloor = usable.map(\.ahead).max() ?? 0
        return furthestFloor >= minimumConfirmedMeters ? .continuous : .unsure
    }

    /// What to say about a verdict, or nil when there is nothing to report. Wording matches the rest
    /// of `SpokenPhrases`: say the thing, then where it is.
    public static func speech(for verdict: Verdict) -> String? {
        switch verdict {
        case .continuous:
            return nil
        case .unsure:
            return nil // the caller decides; silence here, a slow-down elsewhere
        case .drop(let atMeters, let byMeters):
            let steps = max(1, Int((atMeters / 0.75).rounded()))
            let where_ = steps == 1 ? "right ahead" : "about \(steps) steps ahead"
            return byMeters >= stairsDropMeters
                ? "Stop. Stairs going down \(where_)."
                : "Careful. A step down \(where_)."
        }
    }
}
