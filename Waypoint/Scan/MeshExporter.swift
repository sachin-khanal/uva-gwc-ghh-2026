// File: Waypoint/Scan/MeshExporter.swift
// Owner: C / U3 (requested richer-data pipeline)
// Purpose: Copy actual LiDAR mesh into map-frame vertices/triangles for OBJEncoder.
// Threading: Snapshot ARKit buffers synchronously on the session's main delegate queue.
// Frames: ARMeshAnchor local -> session world == restored MAP frame. No invented surfaces.
// Status: SCAFFOLD, UNVERIFIED ON DEVICE. No textures or classification export in v1 OBJ.
import ARKit
import WaypointCore

enum MeshExporter {
    struct Snapshot {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int>] = []
    }

    static func snapshot(_ anchors: [ARMeshAnchor]) throws -> Snapshot {
        var result = Snapshot()
        for anchor in anchors {
            let g = anchor.geometry, offset = result.vertices.count
            guard g.faces.indexCountPerPrimitive == 3,
                  g.faces.bytesPerIndex == 4 || g.faces.bytesPerIndex == 2 else {
                throw MapStoreError.rejected("Unsupported mesh index layout.")
            }
            guard offset + g.vertices.count <= 500_000,
                  result.triangles.count + g.faces.count <= 1_000_000 else {
                throw MapStoreError.rejected("Scan is too large to export. Save a shorter scan.")
            }
            for i in 0..<g.vertices.count {
                let p = g.vertices.buffer.contents().advanced(by: g.vertices.offset + i * g.vertices.stride)
                    .assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                result.vertices.append(SIMD3(world.x, world.y, world.z))
            }
            for face in 0..<g.faces.count {
                var indices = SIMD3<Int>()
                for corner in 0..<3 {
                    let p = g.faces.buffer.contents().advanced(by: (face * 3 + corner) * g.faces.bytesPerIndex)
                    let index = g.faces.bytesPerIndex == 4 ? Int(p.load(as: UInt32.self)) : Int(p.load(as: UInt16.self))
                    guard index < g.vertices.count else { throw MapStoreError.rejected("Invalid mesh index.") }
                    indices[corner] = offset + index
                }
                result.triangles.append(indices)
            }
        }
        return result
    }

    /// Median height of classified floor vertices near the volunteer; no guessed eye height.
    static func floorHeight(_ anchors: [ARMeshAnchor], near seed: SIMD3<Float>) -> Float? {
        var heights: [Float] = []
        for anchor in anchors {
            let g = anchor.geometry
            guard let c = g.classification, g.faces.bytesPerIndex == 4,
                  g.faces.indexCountPerPrimitive == 3 else { continue }
            for face in stride(from: 0, to: g.faces.count, by: 3) {
                let raw = c.buffer.contents().advanced(by: c.offset + face * c.stride).load(as: UInt8.self)
                guard ARMeshClassification(rawValue: Int(raw)) == .floor else { continue }
                let index = Int(g.faces.buffer.contents().advanced(by: face * 3 * 4).load(as: UInt32.self))
                guard index < g.vertices.count else { continue }
                let p = g.vertices.buffer.contents().advanced(by: g.vertices.offset + index * g.vertices.stride)
                    .assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                if abs(w.x - seed.x) <= 3, abs(w.z - seed.z) <= 3, w.y < seed.y,
                   seed.y - w.y < 3, w.y.isFinite { heights.append(w.y) }
            }
        }
        guard !heights.isEmpty else { return nil }
        heights.sort()
        return heights[heights.count / 2]
    }
}
