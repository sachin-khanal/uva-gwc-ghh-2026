//
// File:     Scan/RoomExtractor.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps) with C (mesh)
// Purpose:  Works out the floor area of the room the volunteer is standing in, from the LiDAR mesh's
//           WALL faces. Produces the `RoomExtent` stored on a `.room` node.
//
// Why:      ARKit hands us one continuous mesh with no notion of rooms, so "arrive at Room 204" could
//           only mean "get within N metres of the pin". A blind user needs to be told they are INSIDE
//           the room (device report 2026-10-17: "it doesn't really detect whether I'm in a room, it
//           tries to get me to the exact spot I labelled something").
//
// Method:   An occupancy grid on the floor plane, then a flood fill.
//             1. every wall/door point blocks the cell it falls in (door included: a doorway you can
//                see through is still the edge of the room);
//             2. flood-fill from where the volunteer stood, over free cells only;
//             3. if the fill escapes to the edge of the grid, this is not an enclosed space - a
//                corridor or an open-plan floor - and we return nil rather than invent a room;
//             4. otherwise fit a gravity-aligned rectangle to the filled cells.
//
// Honest limits: an OPEN door leaks the fill into the corridor beyond. `maxRadius` bounds the damage,
//           and the escape test usually catches it. This finds the room you are standing in; it is not
//           a floor-plan reconstruction.
//
// Status:   DONE (pure logic, unit-tested). The quality of the input points is UNVERIFIED ON DEVICE.
//
import Foundation
import simd

public enum RoomExtractor {

    /// Grid cell size. 0.15 m is finer than any doorway we must not leak through, and a 20 m square
    /// of it is still only ~18k cells.
    public static let defaultResolution: Float = 0.15
    /// How far from the seed we are willing to look. Bigger than any room we expect to map.
    public static let defaultMaxRadius: Float = 12

    public struct Result: Equatable {
        public var extent: RoomExtent
        /// Cells filled x cell area: the real enclosed floor area.
        public var areaSquareMeters: Float
    }

    /// - Parameters:
    ///   - seed: where the volunteer stood, map frame.
    ///   - wallPoints: points on wall/door surfaces, projected to the floor plane (map x, z).
    ///   - floorY: height of the floor, copied into the extent's centre.
    /// - Returns: nil when no enclosing walls were found within `maxRadius`.
    public static func extract(
        seed: SIMD3<Float>,
        wallPoints: [SIMD2<Float>],
        floorY: Float = 0,
        resolution: Float = defaultResolution,
        maxRadius: Float = defaultMaxRadius
    ) -> Result? {
        guard resolution > 0, maxRadius > resolution else { return nil }

        let side = Int((maxRadius * 2 / resolution).rounded(.up)) + 1
        guard side > 2, side <= 4096 else { return nil }
        let origin = SIMD2<Float>(seed.x, seed.z) - SIMD2<Float>(repeating: maxRadius)

        func index(_ x: Int, _ y: Int) -> Int { y * side + x }
        func cell(of p: SIMD2<Float>) -> (Int, Int) {
            (Int(((p.x - origin.x) / resolution).rounded(.down)),
             Int(((p.y - origin.y) / resolution).rounded(.down)))
        }

        var blocked = [Bool](repeating: false, count: side * side)
        for p in wallPoints {
            let (x, y) = cell(of: p)
            guard x >= 0, y >= 0, x < side, y < side else { continue }
            blocked[index(x, y)] = true
        }

        let (sx, sy) = cell(of: SIMD2(seed.x, seed.z))
        guard sx > 0, sy > 0, sx < side - 1, sy < side - 1 else { return nil }
        // Standing inside a wall (or on one): nothing sensible to say.
        if blocked[index(sx, sy)] { return nil }

        var filled = [Bool](repeating: false, count: side * side)
        var stack = [(sx, sy)]
        filled[index(sx, sy)] = true
        var count = 0
        var cells: [SIMD2<Float>] = []

        while let (x, y) = stack.popLast() {
            count += 1
            cells.append(origin + SIMD2(Float(x) + 0.5, Float(y) + 0.5) * resolution)
            // Touching the edge of the grid means the space is not enclosed within maxRadius.
            if x == 0 || y == 0 || x == side - 1 || y == side - 1 { return nil }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                let i = index(nx, ny)
                guard !filled[i], !blocked[i] else { continue }
                filled[i] = true
                stack.append((nx, ny))
            }
        }

        let area = Float(count) * resolution * resolution
        guard let box = OrientedBox.fitBest(hull: ConvexHull2D.hull(cells), minY: floorY, maxY: floorY + 1) else {
            return nil
        }
        let extent = RoomExtent(
            center: SIMD3(box.center.x, floorY, box.center.z),
            halfExtents: SIMD2(box.halfExtents.x, box.halfExtents.z),
            yaw: box.yaw,
            areaSquareMeters: area)
        return Result(extent: extent, areaSquareMeters: area)
    }
}
