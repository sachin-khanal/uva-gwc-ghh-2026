//
// File:     Scan/CoverageTracker.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps)
// Purpose:  Measures how much of a scan has been seen from BOTH directions, so the volunteer can be
//           told to walk back the way they came before saving.
//
// Why:      ARKit's world-map relocalization matches what the camera sees now against what it saw
//           while scanning, and that is viewpoint-dependent. A corridor walked once contains almost
//           no reverse-facing views, so a user returning the other way gives ARKit very little to
//           match and relocalization struggles - reported on device 2026-10-17. Walking the route
//           both ways fixes it at the source, and costs the volunteer a minute.
//
// Method:   the floor plane is divided into `bucketMetres` cells. For each cell we remember which
//           heading octants the camera has faced there. A cell counts as covered once two of its
//           headings are roughly opposite; `returnCoverage` is the fraction of visited cells that
//           are. Heading only - pitch and roll do not matter for "did we look back down the corridor".
//
// Note:     this measures COVERAGE, not map quality. A high score means ARKit was shown the space
//           from both directions; whether it mapped it well is `worldMappingStatus`, separately.
//
// Status:   DONE (pure logic, unit-tested).
//
import Foundation
import simd

public struct CoverageTracker: Equatable {

    /// Floor-plane cell size. Roughly a stride or two: fine enough that a corridor is several cells,
    /// coarse enough that normal weaving stays in one.
    public var bucketMetres: Float
    /// Heading buckets around the circle. 8 gives 45-degree resolution, which is plenty to tell
    /// "down the corridor" from "back up it".
    public var octantCount: Int
    /// How far from a true 180 degrees still counts as "the other way". Generous, because nobody
    /// retraces a corridor on exactly the reciprocal heading.
    public var oppositeToleranceDegrees: Float
    /// Below this many visited cells the walk is too short to judge, and prompting would be noise.
    public var minimumCellsToJudge: Int
    /// Prompt the volunteer to walk back while coverage is under this.
    public var promptBelowCoverage: Float

    private struct Cell: Hashable { var x: Int; var z: Int }
    private var seen: [Cell: Set<Int>] = [:]

    public init(
        bucketMetres: Float = 2,
        octantCount: Int = 8,
        oppositeToleranceDegrees: Float = 60,
        minimumCellsToJudge: Int = 4,
        promptBelowCoverage: Float = 0.6
    ) {
        self.bucketMetres = max(0.1, bucketMetres)
        self.octantCount = max(2, octantCount)
        self.oppositeToleranceDegrees = oppositeToleranceDegrees
        self.minimumCellsToJudge = minimumCellsToJudge
        self.promptBelowCoverage = promptBelowCoverage
    }

    /// Feed the camera pose. `yaw` is radians about the vertical axis (0 = -z, positive toward +x),
    /// the same convention `CaptureController` already computes for keyframes.
    public mutating func observe(position: SIMD3<Float>, yaw: Float) {
        guard position.x.isFinite, position.z.isFinite, yaw.isFinite else { return }
        let cell = Cell(x: Int((position.x / bucketMetres).rounded(.down)),
                        z: Int((position.z / bucketMetres).rounded(.down)))
        seen[cell, default: []].insert(octant(of: yaw))
    }

    /// How many distinct places the volunteer has stood.
    public var visitedCellCount: Int { seen.count }

    /// Fraction of visited places that have been seen from roughly opposite directions, 0...1.
    /// 0 when nothing has been visited, so an empty tracker never claims coverage.
    public var returnCoverage: Float {
        guard !seen.isEmpty else { return 0 }
        let covered = seen.values.count(where: hasOppositePair)
        return Float(covered) / Float(seen.count)
    }

    /// Ask the volunteer to walk back. False for a walk too short to judge, so a quick scan of one
    /// room is not nagged at.
    public var shouldPromptReturnWalk: Bool {
        visitedCellCount >= minimumCellsToJudge && returnCoverage < promptBelowCoverage
    }

    public mutating func reset() { seen.removeAll() }

    // MARK: Private

    private func octant(of yaw: Float) -> Int {
        let full = 2 * Float.pi
        let step = full / Float(octantCount)
        // `truncatingRemainder` keeps negatives negative, so add a turn before taking it.
        let normalised = (yaw.truncatingRemainder(dividingBy: full) + full)
            .truncatingRemainder(dividingBy: full)
        return min(octantCount - 1, Int(normalised / step))
    }

    /// True when any two recorded headings for a cell are roughly reciprocal.
    private func hasOppositePair(_ octants: Set<Int>) -> Bool {
        guard octants.count > 1 else { return false }
        let step = 360 / Float(octantCount)
        let sorted = octants.sorted()
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] {
                var difference = abs(Float(a) - Float(b)) * step
                if difference > 180 { difference = 360 - difference }
                if abs(difference - 180) <= oppositeToleranceDegrees { return true }
            }
        }
        return false
    }
}
