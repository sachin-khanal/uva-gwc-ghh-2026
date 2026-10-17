//
// File:     Scan/OrientedBox.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps) with C (export)
// Purpose:  The scan "bounding box" of the Polycam-style live scanner: a box that is upright
//           (aligned with gravity) but can be rotated about the vertical axis (`yaw`) to hug the
//           scanned space - e.g. a hallway that runs diagonally to the world axes.
//           * `fit(points:yaw:)`      tightest box at a given yaw
//           * `fitBest(points:)`      tries many yaws and keeps the smallest floor area
//           * `contains`, `corners`, `expanded` - used to draw the box, crop the mesh on export, and
//                                      show dimensions in the HUD.
// Frame:    ARKit world/map frame (+y up). Rotation convention: rotating a point by `yaw` about +y is
//           x' = x cos + z sin ; z' = -x sin + z cos  (same as simd_quatf(angle:axis:[0,1,0])).
// Pure math, no ARKit: tested in ScanTests. The app feeds it sampled mesh vertices once a second.
//
import Foundation
import simd

public struct OrientedBox: Equatable, Sendable {

    /// Box center in the world/map frame (meters).
    public var center: SIMD3<Float>
    /// Half the size along the box's own x (width), y (height), z (depth) axes.
    public var halfExtents: SIMD3<Float>
    /// Rotation about +y, radians, taking box axes to world axes.
    public var yaw: Float

    public init(center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float) {
        self.center = center
        self.halfExtents = halfExtents
        self.yaw = yaw
    }

    public var size: SIMD3<Float> { halfExtents * 2 }
    public var volume: Float { size.x * size.y * size.z }
    public var floorArea: Float { size.x * size.z }

    // MARK: Rotation helpers

    @inline(__always)
    static func rotateY(_ p: SIMD3<Float>, by theta: Float) -> SIMD3<Float> {
        let c = cos(theta), s = sin(theta)
        return SIMD3<Float>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
    }

    // MARK: Queries

    /// True if `p` is inside (or on the surface of) the box. `slack` grows the box slightly (meters).
    public func contains(_ p: SIMD3<Float>, slack: Float = 1e-4) -> Bool {
        let local = Self.rotateY(p - center, by: -yaw)
        return abs(local.x) <= halfExtents.x + slack
            && abs(local.y) <= halfExtents.y + slack
            && abs(local.z) <= halfExtents.z + slack
    }

    /// The 8 corners in world coordinates. Order: bottom face (y-) then top face (y+), each
    /// going (-x,-z) (+x,-z) (+x,+z) (-x,+z). The wireframe renderer relies on this order.
    public func corners() -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for sy: Float in [-1, 1] {
            for (sx, sz) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                let local = SIMD3<Float>(sx * halfExtents.x, sy * halfExtents.y, sz * halfExtents.z)
                result.append(center + Self.rotateY(local, by: yaw))
            }
        }
        return result
    }

    /// 12 edges as index pairs into `corners()`.
    public static let edgeIndices: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0), // bottom
        (4, 5), (5, 6), (6, 7), (7, 4), // top
        (0, 4), (1, 5), (2, 6), (3, 7), // verticals
    ]

    /// Same box, every side pushed out by `margin` meters (negative shrinks; never below 1 cm).
    public func expanded(by margin: Float) -> OrientedBox {
        var b = self
        b.halfExtents = simd_max(halfExtents + SIMD3<Float>(repeating: margin), SIMD3<Float>(repeating: 0.01))
        return b
    }

    // MARK: Fitting

    /// Tightest box around `points` for a fixed yaw. nil if there are no points.
    public static func fit(points: [SIMD3<Float>], yaw: Float) -> OrientedBox? {
        guard let first = points.first else { return nil }
        let r0 = rotateY(first, by: -yaw)
        var lo = r0, hi = r0
        for p in points.dropFirst() {
            let r = rotateY(p, by: -yaw)
            lo = simd_min(lo, r)
            hi = simd_max(hi, r)
        }
        let localCenter = (lo + hi) / 2
        return OrientedBox(center: rotateY(localCenter, by: yaw), halfExtents: (hi - lo) / 2, yaw: yaw)
    }

    /// Tries yaws from 0 up to (not including) 90 degrees and returns the fit with the smallest floor
    /// area (a rectangle's best orientation repeats every 90 degrees).
    /// EXACT and fast: reduces the points to their 2-D convex hull first (the extremes along any direction are hull vertices),
    /// so the result equals `fitBestBruteForce` but costs O(n log n + yaws * hull) instead of O(yaws * n).
    public static func fitBest(points: [SIMD3<Float>], yawStepDegrees: Float = 5) -> OrientedBox? {
        guard let first = points.first else { return nil }
        var minY = first.y, maxY = first.y
        var floorPoints: [SIMD2<Float>] = []
        floorPoints.reserveCapacity(points.count)
        for p in points {
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
            floorPoints.append(SIMD2<Float>(p.x, p.z))
        }
        return fitBest(hull: ConvexHull2D.hull(floorPoints), minY: minY, maxY: maxY, yawStepDegrees: yawStepDegrees)
    }

    /// Same search starting from an already-computed floor-plane hull (x, z) and the vertical extent. Callers that
    /// stream huge meshes (the app) reduce each mesh anchor to its own hull and pass the merged hull here.
    public static func fitBest(hull: [SIMD2<Float>], minY: Float, maxY: Float, yawStepDegrees: Float = 5) -> OrientedBox? {
        guard let first = hull.first else { return nil }
        var best: OrientedBox?
        var yawDeg: Float = 0
        while yawDeg < 90 {
            let yaw = yawDeg * .pi / 180
            let c = cos(yaw), s = sin(yaw)
            // Rotate by -yaw (same arithmetic as `rotateY(_, by: -yaw)`), tracking min/max of the rotated x and z.
            var lo = SIMD2<Float>(first.x * c - first.y * s, first.x * s + first.y * c)
            var hi = lo
            for p in hull.dropFirst() {
                let r = SIMD2<Float>(p.x * c - p.y * s, p.x * s + p.y * c)
                lo = simd_min(lo, r)
                hi = simd_max(hi, r)
            }
            let local = SIMD3<Float>((lo.x + hi.x) / 2, (minY + maxY) / 2, (lo.y + hi.y) / 2)
            let candidate = OrientedBox(center: rotateY(local, by: yaw),
                                        halfExtents: SIMD3<Float>((hi.x - lo.x) / 2, (maxY - minY) / 2, (hi.y - lo.y) / 2),
                                        yaw: yaw)
            if best == nil || candidate.floorArea < best!.floorArea - 1e-6 { best = candidate }
            yawDeg += max(1, yawStepDegrees)
        }
        return best
    }

    /// The original O(yaws * points) search over every point. Kept as the reference implementation that tests compare the fast one against.
    static func fitBestBruteForce(points: [SIMD3<Float>], yawStepDegrees: Float = 5) -> OrientedBox? {
        var best: OrientedBox?
        var yawDeg: Float = 0
        while yawDeg < 90 {
            if let candidate = fit(points: points, yaw: yawDeg * .pi / 180),
               best == nil || candidate.floorArea < best!.floorArea - 1e-6 {
                best = candidate
            }
            yawDeg += max(1, yawStepDegrees)
        }
        return best
    }
}
