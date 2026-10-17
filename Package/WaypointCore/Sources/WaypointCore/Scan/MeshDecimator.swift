//
// File:     Scan/MeshDecimator.swift
// Module:   WaypointCore
// Owner:    C (export) with A (scan)
// Purpose:  Makes a scan mesh small enough to export and share. LiDAR meshes run to millions of triangles; the 3D model of a map must stay
//           under `ExportBudget.defaultBudgetBytes` (Supabase free tier limit). Method: VERTEX CLUSTERING. Space is cut into cubes of
//           `cellSize`; all vertices in one cube become their average; triangles that collapse to a line or point are dropped. It is fast
//           (one pass), deterministic, needs no adjacency data, and keeps the overall shape (walls stay walls); fine detail is lost,
//           which is the point.
// Budget:   `fit` grows the cube size until `ExportBudget.estimatedBytes` fits, trying at most `maxPasses` times.
// Status:   DONE (logic, unit tested). The ARKit extraction and USDZ writing are app-side (Waypoint/Scan/MeshExporter.swift).
//
import Foundation
import simd

public struct IndexedMesh: Equatable, Sendable {
    public var vertices: [SIMD3<Float>]
    /// Triangle list: 3 indices per triangle.
    public var indices: [UInt32]

    public init(vertices: [SIMD3<Float>] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }
    public var estimatedBytes: Int { ExportBudget.estimatedBytes(vertices: vertices.count, triangles: triangleCount) }
    public var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
}

public enum MeshCrop {
    /// Keeps only triangles whose centre lies inside `box` (the volunteer's scan box), so stray far-away geometry (a window onto the street,
    /// a neighbouring room seen through a door) is not exported. Unused vertices are dropped.
    public static func crop(_ mesh: IndexedMesh, to box: OrientedBox, slack: Float = 0.05) -> IndexedMesh {
        guard !mesh.isEmpty else { return mesh }
        var remap = [UInt32](repeating: .max, count: mesh.vertices.count)
        var vertices: [SIMD3<Float>] = [], indices: [UInt32] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let ids = [Int(mesh.indices[t]), Int(mesh.indices[t + 1]), Int(mesh.indices[t + 2])]
            t += 3
            guard ids.allSatisfy({ $0 < mesh.vertices.count }) else { continue }
            let centre = (mesh.vertices[ids[0]] + mesh.vertices[ids[1]] + mesh.vertices[ids[2]]) / 3
            guard box.contains(centre, slack: slack) else { continue }
            for id in ids {
                if remap[id] == .max { remap[id] = UInt32(vertices.count); vertices.append(mesh.vertices[id]) }
                indices.append(remap[id])
            }
        }
        return IndexedMesh(vertices: vertices, indices: indices)
    }
}

public enum MeshDecimator {

    /// Merge all vertices inside each cube of side `cellSize` (metres) into their average. Invalid triangles (out-of-range index, or two
    /// corners merged) are dropped; vertices no remaining triangle uses are not emitted.
    public static func cluster(_ mesh: IndexedMesh, cellSize: Float) -> IndexedMesh {
        guard cellSize > 0, !mesh.isEmpty else { return mesh }
        let inv = 1 / cellSize

        // 1. vertex -> cell -> new vertex id
        var cellToNew: [CellKey: UInt32] = [:]
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var remap = [UInt32](repeating: .max, count: mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { continue }
            let key = CellKey(Int32((v.x * inv).rounded(.down)), Int32((v.y * inv).rounded(.down)), Int32((v.z * inv).rounded(.down)))
            if let id = cellToNew[key] {
                sums[Int(id)] += v; counts[Int(id)] += 1; remap[i] = id
            } else {
                let id = UInt32(sums.count)
                cellToNew[key] = id; sums.append(v); counts.append(1); remap[i] = id
            }
        }

        // 2. triangles through the remap; drop collapsed ones
        var kept: [UInt32] = []
        kept.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            t += 3
            guard a < remap.count, b < remap.count, c < remap.count else { continue }
            let (x, y, z) = (remap[a], remap[b], remap[c])
            guard x != .max, y != .max, z != .max, x != y, y != z, x != z else { continue }
            kept += [x, y, z]
        }

        // 3. compact: only vertices that are still used, in first-use order (deterministic)
        var compact = [UInt32](repeating: .max, count: sums.count)
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        indices.reserveCapacity(kept.count)
        for old in kept {
            if compact[Int(old)] == .max {
                compact[Int(old)] = UInt32(vertices.count)
                vertices.append(sums[Int(old)] / counts[Int(old)])
            }
            indices.append(compact[Int(old)])
        }
        return IndexedMesh(vertices: vertices, indices: indices)
    }

    public struct Result: Equatable, Sendable {
        public var mesh: IndexedMesh
        /// nil when the mesh already fit and was returned untouched.
        public var cellSize: Float?
        public var fitsBudget: Bool
    }

    /// The largest-detail mesh (smallest cube) that fits `budgetBytes`.
    public static func fit(_ mesh: IndexedMesh, budgetBytes: Int = ExportBudget.defaultBudgetBytes,
                           startCellSize: Float = 0.03, growth: Float = 1.4, maxPasses: Int = 24) -> Result {
        if mesh.estimatedBytes <= budgetBytes { return Result(mesh: mesh, cellSize: nil, fitsBudget: true) }
        var cell = max(0.005, startCellSize)
        var best = mesh
        for _ in 0..<maxPasses {
            best = cluster(mesh, cellSize: cell)
            if best.estimatedBytes <= budgetBytes { return Result(mesh: best, cellSize: cell, fitsBudget: true) }
            cell *= growth
        }
        return Result(mesh: best, cellSize: cell / growth, fitsBudget: best.estimatedBytes <= budgetBytes)
    }

    private struct CellKey: Hashable {
        let x: Int32, y: Int32, z: Int32
        init(_ x: Int32, _ y: Int32, _ z: Int32) { self.x = x; self.y = y; self.z = z }
    }
}
