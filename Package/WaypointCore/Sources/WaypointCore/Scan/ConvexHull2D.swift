//
// File:     Scan/ConvexHull2D.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps)
// Purpose:  2-D convex hull (Andrew's monotone chain) of floor-plane points. Used to fit the scan bounding box EXACTLY and fast:
//           the extreme value of a point cloud along ANY direction is always attained at a vertex of its convex hull, so fitting
//           a (rotated) box to the hull gives precisely the same box as fitting it to every point - but touches a few hundred
//           points instead of hundreds of thousands. (Lossless: proven equal to the brute-force fit by ScanTests.)
// Union:    hull(hull(A) + hull(B)) == hull(A + B), so each mesh anchor can be reduced to its own hull independently,
//           in parallel, and the hulls merged.
//
import Foundation
import simd

public enum ConvexHull2D {

    /// Convex hull in counter-clockwise order, collinear points removed. Returns the input if it has fewer than 3 points.
    public static func hull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count > 2 else { return points }
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

        @inline(__always) func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
