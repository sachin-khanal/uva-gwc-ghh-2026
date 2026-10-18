//
// File:     Scan/ObjExport.swift
// Module:   WaypointCore
// Owner:    C (export) with U3 (web viewer)
// Purpose:  Turns a scan mesh into the OBJ file the WEB viewer draws, plus the `MeshAsset` manifest entry (size, SHA-256, bounds) that
//           pins its bytes. The phone's own 3D model stays USDZ (`MeshExporter`); this is the portable copy for sharing.
// Format:   Plain text, `v x y z` then `f a b c` (1-based triangles), map frame, no normals/colours/textures. This is exactly what
//           web/geometry3d.js `parseOBJ` accepts (only triangles, finite numbers, <= 500k vertices / 1M triangles).
// Budget:   OBJ is text, about 1.7x the size of the binary estimate in `ExportBudget`, so `make` re-fits the mesh to `maxBytes`
//           (default 30 MB, under the 40 MB per-file validator limit and the 50 MB storage limit).
// Status:   DONE (logic, unit tested). Real LiDAR meshes through the web viewer: UNVERIFIED ON DEVICE.
//
import Foundation
import simd
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ObjExport {

    public static let defaultMaxBytes = 30_000_000
    /// Matches the web viewer's parser limits (web/geometry3d.js) so an exported file is never refused there.
    public static let maxVertices = 500_000
    public static let maxTriangles = 1_000_000

    public struct Output: Equatable, Sendable {
        public var asset: MeshAsset
        public var data: Data
        public var vertices: Int
        public var triangles: Int
    }

    public enum ExportError: Error, Equatable, LocalizedError {
        case emptyMesh
        case nonFinite
        case tooLarge
        case unsafeSegment

        public var errorDescription: String? {
            switch self {
            case .emptyMesh: return "There was no mesh to export."
            case .nonFinite: return "The mesh has invalid coordinates."
            case .tooLarge: return "The mesh is too large even after simplifying."
            case .unsafeSegment: return "Unsafe segment id."
            }
        }
    }

    /// OBJ text for `mesh`. Triangles with an out-of-range index are skipped; vertices are written as-is (so indices stay valid).
    public static func encode(_ mesh: IndexedMesh) -> Data {
        var text = ""
        text.reserveCapacity(mesh.vertices.count * 36 + mesh.indices.count * 8)
        text += "# Waypoint scan surface (map frame, metres)\n"
        for v in mesh.vertices { text += "v \(v.x) \(v.y) \(v.z)\n" }
        let n = mesh.vertices.count
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            t += 3
            guard a < n, b < n, c < n, a != b, b != c, a != c else { continue }
            text += "f \(a + 1) \(b + 1) \(c + 1)\n"
        }
        return Data(text.utf8)
    }

    /// Lowercase hex SHA-256, the form `MeshAsset.sha256` and the web viewer expect.
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    /// Fits `mesh` to the viewer's limits and `maxBytes`, encodes it, and builds the manifest entry. `storageOwner` stays nil here: the
    /// uploader fills in the signed-in user when the file is published.
    public static func make(_ mesh: IndexedMesh, segmentId: String, assetId: UUID = UUID(), maxBytes: Int = defaultMaxBytes) throws -> Output {
        guard SegmentID.isValid(segmentId) else { throw ExportError.unsafeSegment }
        guard !mesh.isEmpty else { throw ExportError.emptyMesh }
        // Binary-size estimate for the first fit: ~55% of the text budget.
        var fitted = MeshDecimator.fit(mesh, budgetBytes: maxBytes * 55 / 100).mesh
        var cell: Float = 0.03
        for _ in 0..<24 {
            let tooMany = fitted.vertices.count > maxVertices || fitted.triangleCount > maxTriangles
            if !tooMany {
                guard let bounds = bounds(of: fitted) else { throw ExportError.nonFinite }
                let data = encode(fitted)
                if data.count <= maxBytes, !fitted.isEmpty {
                    let asset = MeshAsset(id: assetId, segmentId: segmentId, byteCount: data.count, sha256: sha256Hex(data),
                                          boundsMin: bounds.min, boundsMax: bounds.max)
                    return Output(asset: asset, data: data, vertices: fitted.vertices.count, triangles: fitted.triangleCount)
                }
            }
            cell *= 1.4
            fitted = MeshDecimator.cluster(fitted, cellSize: cell)
            if fitted.isEmpty { break }
        }
        throw ExportError.tooLarge
    }

    /// Min/max over the vertices that triangles use; nil if any is not finite.
    static func bounds(of mesh: IndexedMesh) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = mesh.vertices.first else { return nil }
        var hi = lo
        for v in mesh.vertices {
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        return (lo, hi)
    }
}
