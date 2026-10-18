// File: Scan/OBJEncoder.swift
// Owner: C / U3
// Purpose: Dependency-free triangular OBJ encoding; actual map-frame vertices, no inferred walls.
// Frames: Input is map-frame meters. Produces untextured geometry with 1-based OBJ indices.
// Status: Implemented; unit tests pending Mac. No Apple UI/AR imports.
import Foundation
import simd

public enum OBJEncoder {
    public static func encode(vertices: [SIMD3<Float>], triangles: [SIMD3<Int>], segmentId: String) throws -> (MeshAsset, Data) {
        guard !vertices.isEmpty, !triangles.isEmpty, vertices.count <= 500_000,
              triangles.count <= 1_000_000, SegmentID.isValid(segmentId),
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MapStoreError.rejected("Empty, nonfinite or oversized mesh.")
        }
        var data = Data("# Waypoint schema 3 OBJ; map-frame meters; untextured\n".utf8)
        var low = vertices[0], high = vertices[0]
        func append(_ line: String) throws {
            let bytes = Data(line.utf8)
            guard data.count + bytes.count <= MeshAsset.maxBytes else { throw MapStoreError.rejected("Mesh exceeds 40 MB.") }
            data.append(bytes)
        }
        for v in vertices {
            low = simd_min(low, v); high = simd_max(high, v)
            try append("v \(v.x) \(v.y) \(v.z)\n")
        }
        for t in triangles {
            guard (0..<3).allSatisfy({ (0..<vertices.count).contains(t[$0]) }),
                  t.x != t.y, t.y != t.z, t.x != t.z else { throw MapStoreError.rejected("Invalid mesh triangle.") }
            try append("f \(t.x + 1) \(t.y + 1) \(t.z + 1)\n")
        }
        return (MeshAsset(segmentId: segmentId, byteCount: data.count,
                          sha256: MeshAsset.digest(data), boundsMin: low, boundsMax: high), data)
    }
}
