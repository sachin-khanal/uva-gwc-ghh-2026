//
// File:     Scan/ExportBudget.swift
// Module:   WaypointCore
// Owner:    C (Vision/Export)
// Purpose:  Keeps exported 3D scans under the Supabase free-tier per-file limit (50 MB; we aim for
//           40 MB to leave headroom). Given a mesh's vertex/triangle counts it estimates the file size
//           and says what fraction of triangles to keep (the exporter then decimates or drops the
//           smallest mesh anchors until it fits).
// Estimate: USDZ stores positions + normals as Float32 (24 B/vertex) and indices as UInt32 (12 B/tri),
//           plus a little container overhead. It is an ESTIMATE; the exporter must check the real
//           file size and loop if it is still over budget (TODO(C)).
//
import Foundation

public enum ExportBudget {

    public static let supabaseFreeTierFileLimit = 50_000_000
    /// Our target per file: leaves ~20% headroom under the limit.
    public static let defaultBudgetBytes = 40_000_000

    static let bytesPerVertex = 24
    static let bytesPerTriangle = 12
    static let containerOverhead = 4_096

    public static func estimatedBytes(vertices: Int, triangles: Int) -> Int {
        containerOverhead + vertices * bytesPerVertex + triangles * bytesPerTriangle
    }

    /// 1.0 if the mesh already fits, otherwise the fraction (never below 0.05) of the mesh to keep.
    public static func keepFraction(vertices: Int, triangles: Int, budgetBytes: Int = defaultBudgetBytes) -> Float {
        let estimate = estimatedBytes(vertices: vertices, triangles: triangles)
        guard estimate > budgetBytes else { return 1 }
        let usable = max(0, budgetBytes - containerOverhead)
        let fraction = Float(usable) / Float(max(1, estimate - containerOverhead))
        return min(1, max(0.05, fraction))
    }
}
