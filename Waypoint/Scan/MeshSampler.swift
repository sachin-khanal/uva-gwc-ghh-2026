//
// File:     Waypoint/Scan/MeshSampler.swift
// Owner:    A (AR/Maps) with C (export)
// Purpose:  Reads the LiDAR mesh ARKit builds (`ARMeshAnchor`s) and returns world-space sample points plus
//           totals. The scan bounding box (`OrientedBox.fitBest`) is fitted to these samples about once a
//           second, so we only read every `stride`-th vertex: the box does not need every point.
// Layout:   ARMeshGeometry.vertices is an ARGeometrySource: a Metal buffer of packed float3 (12 bytes per
//           vertex; do NOT assume SIMD3's 16-byte stride). `offset`/`stride` come from the source itself.
//           Vertices are in the anchor's local space; multiply by `anchor.transform` for world space.
// Cost:     100k vertices at stride 6 is about 17k transforms: cheap enough for the main thread at 1 Hz.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE. TODO(C): classification-aware sampling (ignore ceiling/window
//           outliers) and a background queue if frame time suffers.
//
import ARKit

enum MeshSampler {

    struct Result {
        var points: [SIMD3<Float>] = []
        var vertexCount = 0
        var triangleCount = 0
        var anchorCount = 0
    }

    static func sample(anchors: [ARMeshAnchor], stride step: Int = 6) -> Result {
        var result = Result()
        let step = max(1, step)
        for anchor in anchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            result.anchorCount += 1
            result.vertexCount += vertices.count
            result.triangleCount += geometry.faces.count

            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            var i = 0
            while i < vertices.count {
                let f = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let local = SIMD4<Float>(f[0], f[1], f[2], 1)
                let world = anchor.transform * local
                result.points.append(SIMD3<Float>(world.x, world.y, world.z))
                i += step
            }
        }
        return result
    }
}
