//
// File:     Waypoint/Scan/MeshSampler.swift
// Owner:    A (AR/Maps) with C (export)
// Purpose:  Measures the LiDAR mesh ARKit builds (`ARMeshAnchor`s) for the scan HUD: vertex/triangle totals and the data the bounding box
//           needs. EXACT (every vertex is read - the old version read every 6th) and cheap:
//             * each anchor is reduced to the 2-D convex hull of its vertices on the floor plane plus its min/max height, and the hulls
//               are merged. The extremes of a point cloud along any direction are hull vertices, so the box fitted to the hull equals
//               the box fitted to all points (proved by FastBoxFitTests in WaypointCore).
//             * it is meant to run on a BACKGROUND queue (CaptureController does that); it only reads immutable anchor snapshots.
// Layout:   ARMeshGeometry.vertices is an ARGeometrySource: a Metal buffer of packed float3 (12 bytes per vertex; do NOT assume SIMD3's
//           16-byte stride). `offset`/`stride` come from the source itself. Vertices are in the anchor's local space; we apply
//           `anchor.transform` by hand (only the x, y, z rows we need) to get world space.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE with a real mesh. TODO(C): classification-aware filtering (ignore ceiling/window outliers).
//
import ARKit
import WaypointCore

enum MeshSampler {

    struct Measurement {
        /// Merged floor-plane (x, z) hull points of all anchors, world space. Feed to `OrientedBox.fitBest(hull:minY:maxY:)`.
        var hull: [SIMD2<Float>] = []
        var minY: Float = .infinity
        var maxY: Float = -.infinity
        var vertexCount = 0
        var triangleCount = 0
        var anchorCount = 0
        var isEmpty: Bool { hull.isEmpty }
    }

    static func measure(anchors: [ARMeshAnchor]) -> Measurement {
        var result = Measurement()
        var merged: [SIMD2<Float>] = []

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            result.anchorCount += 1
            result.vertexCount += vertices.count
            result.triangleCount += geometry.faces.count
            guard vertices.count > 0 else { continue }

            let m = anchor.transform
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            var floorPoints: [SIMD2<Float>] = []
            floorPoints.reserveCapacity(vertices.count)

            for i in 0..<vertices.count {
                let f = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let x = f[0], y = f[1], z = f[2]
                // world = m * (x, y, z, 1); only the world x, y, z components are needed.
                let wx = m.columns.0.x * x + m.columns.1.x * y + m.columns.2.x * z + m.columns.3.x
                let wy = m.columns.0.y * x + m.columns.1.y * y + m.columns.2.y * z + m.columns.3.y
                let wz = m.columns.0.z * x + m.columns.1.z * y + m.columns.2.z * z + m.columns.3.z
                floorPoints.append(SIMD2<Float>(wx, wz))
                if wy < result.minY { result.minY = wy }
                if wy > result.maxY { result.maxY = wy }
            }
            merged += ConvexHull2D.hull(floorPoints) // keep only this anchor's hull vertices
        }
        result.hull = ConvexHull2D.hull(merged)
        return result
    }
}

extension MeshSampler {

    /// Points lying on WALL (and door) surfaces near `seed`, projected to the floor plane.
    /// Feeds `RoomExtractor`, which turns them into the room's floor area.
    ///
    /// Only faces ARKit classified as wall or door are used: a floor or ceiling face would block every
    /// cell of the occupancy grid and no room would ever be found. Faces are sampled at `faceStride`
    /// because a room's walls run to tens of thousands of triangles and the grid only needs enough
    /// points to leave no gap wider than a grid cell.
    ///
    /// `heightBand` keeps points between knee and head height above the floor, where a wall is a wall;
    /// near the floor the classifier confuses skirting with floor, and near the ceiling with ceiling.
    ///
    /// Returns an empty array when the scan has no classification (classification off, or a device
    /// that cannot do it), which `RoomExtractor` then correctly reports as "no room found".
    static func wallPoints(
        anchors: [ARMeshAnchor],
        seed: SIMD3<Float>,
        radius: Float,
        heightBand: ClosedRange<Float> = 0.4...1.8,
        faceStride: Int = 3
    ) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        let radiusSquared = radius * radius

        for anchor in anchors {
            let geometry = anchor.geometry
            guard let classification = geometry.classification else { continue }

            let faces = geometry.faces
            let vertices = geometry.vertices
            guard faces.indexCountPerPrimitive == 3, vertices.count > 0 else { continue }

            let classBase = classification.buffer.contents().advanced(by: classification.offset)
            let faceBase = faces.buffer.contents()
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let m = anchor.transform

            for face in stride(from: 0, to: faces.count, by: max(1, faceStride)) {
                let raw = classBase.advanced(by: face * classification.stride)
                    .assumingMemoryBound(to: UInt8.self).pointee
                let kind = ARMeshClassification(rawValue: Int(raw))
                guard kind == .wall || kind == .door else { continue }

                for corner in 0..<3 {
                    let indexOffset = (face * 3 + corner) * faces.bytesPerIndex
                    // ARKit uses 32-bit indices for scene reconstruction; anything else we skip.
                    guard faces.bytesPerIndex == 4 else { continue }
                    let vertexIndex = Int(faceBase.advanced(by: indexOffset)
                        .assumingMemoryBound(to: UInt32.self).pointee)
                    guard vertexIndex < vertices.count else { continue }

                    let f = vertexBase.advanced(by: vertexIndex * vertices.stride)
                        .assumingMemoryBound(to: Float.self)
                    let x = f[0], y = f[1], z = f[2]
                    let wx = m.columns.0.x * x + m.columns.1.x * y + m.columns.2.x * z + m.columns.3.x
                    let wy = m.columns.0.y * x + m.columns.1.y * y + m.columns.2.y * z + m.columns.3.y
                    let wz = m.columns.0.z * x + m.columns.1.z * y + m.columns.2.z * z + m.columns.3.z

                    let height = wy - seed.y
                    guard heightBand.contains(height) else { continue }
                    let dx = wx - seed.x, dz = wz - seed.z
                    guard dx * dx + dz * dz <= radiusSquared else { continue }
                    points.append(SIMD2<Float>(wx, wz))
                }
            }
        }
        return points
    }
}

extension MeshSampler {

    /// World-space mesh vertices, every `stride`-th one, for the coverage ("unscanned areas") grid. Runs on a background queue; reads
    /// immutable anchor snapshots only. `limit` caps the total so a huge scan cannot make this slow.
    static func samplePoints(anchors: [ARMeshAnchor], stride step: Int = 3, limit: Int = 120_000) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            guard vertices.count > 0 else { continue }
            let m = anchor.transform
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in Swift.stride(from: 0, to: vertices.count, by: max(1, step)) {
                let f = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let x = f[0], y = f[1], z = f[2]
                points.append(SIMD3<Float>(m.columns.0.x * x + m.columns.1.x * y + m.columns.2.x * z + m.columns.3.x,
                                           m.columns.0.y * x + m.columns.1.y * y + m.columns.2.y * z + m.columns.3.y,
                                           m.columns.0.z * x + m.columns.1.z * y + m.columns.2.z * z + m.columns.3.z))
                if points.count >= limit { return points }
            }
        }
        return points
    }
}
