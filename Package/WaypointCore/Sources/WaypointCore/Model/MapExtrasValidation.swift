//
// File:     Model/MapExtrasValidation.swift
// Module:   WaypointCore
// Owner:    SHARED CONTRACT (with MapTypes.swift) / D (validation)
// Purpose:  Import-time checks for the OPTIONAL format-3 additions: a room's floor area (`MapNode.extent`) and the 3D surface list
//           (`BuildingMap.meshAssets`). Both arrive inside maps from OTHER people, and both change what the app does:
//             * `RouteFollower` announces "You have arrived" as soon as the user is inside the destination's `extent`, so a hostile or
//               corrupt extent (huge, non-finite, far from its node) could make the app say it at the wrong place;
//             * `meshAssets` name files that other tools download, so their size, hash and owner must be well-formed.
//           The rules mirror web/router.js (U3's web viewer) and are stricter on room size and position; keep both in step.
//           The same checks run in tools/validate_map.py and (server side) in supabase/migrations/0005.
// Status:   DONE (logic, unit tested).
//
import Foundation
import simd

extension MapBundle {

    /// Largest believable half-width of a single room (metres): a 60 m x 60 m room.
    public static let maxRoomHalfExtent: Float = 30
    public static let maxRoomHeight: Float = 20
    public static let maxMeshAssets = 100
    public static let maxMeshAssetBytes = 40_000_000
    public static let maxMeshTotalBytes = 80_000_000

    func validateExtras() throws {
        try validateExtents()
        try validateMeshAssets()
    }

    private func validateExtents() throws {
        func ok(_ v: Float) -> Bool { v.isFinite }
        for node in map.nodes {
            guard let e = node.extent else { continue }
            let h = e.halfExtents
            guard node.kind == .room else { throw MapStoreError.rejected("A place that is not a room has a floor area.") }
            guard ok(e.center.x), ok(e.center.y), ok(e.center.z), ok(h.x), ok(h.y), ok(e.yaw), ok(e.areaSquareMeters),
                  h.x > 0.05, h.y > 0.05, h.x <= Self.maxRoomHalfExtent, h.y <= Self.maxRoomHalfExtent else {
                throw MapStoreError.rejected("A room has an invalid size.")
            }
            // The area enclosed by walls cannot exceed its bounding rectangle (small float slack).
            guard e.areaSquareMeters > 0, e.areaSquareMeters <= 4 * h.x * h.y + 0.01 else {
                throw MapStoreError.rejected("A room's floor area does not match its size.")
            }
            if let height = e.heightMeters {
                guard ok(height), height > 0, height <= Self.maxRoomHeight else { throw MapStoreError.rejected("A room has an invalid height.") }
            }
            // The room must be where its place is: its node lies in or next to the rectangle (a doorway counts).
            let reach = simd_length(h) + 1
            guard Geometry.horizontalDistance(e.center, node.position) <= reach else {
                throw MapStoreError.rejected("A room's floor area is far from the room itself.")
            }
        }
    }

    private func validateMeshAssets() throws {
        guard let assets = map.meshAssets, !assets.isEmpty else { return }
        guard assets.count <= Self.maxMeshAssets else { throw MapStoreError.rejected("Too many 3D surface files.") }
        let segments = Set(map.nodes.map(\.segmentId))
        var seen = Set<UUID>()
        var total = 0
        for a in assets {
            guard seen.insert(a.id).inserted else { throw MapStoreError.rejected("Duplicate 3D surface file.") }
            guard SegmentID.isValid(a.segmentId), segments.contains(a.segmentId) else {
                throw MapStoreError.rejected("A 3D surface file refers to an unknown scan.")
            }
            guard a.format == "obj", a.coordinateFrame == "map" else { throw MapStoreError.rejected("A 3D surface file has an unsupported format.") }
            guard (1...Self.maxMeshAssetBytes).contains(a.byteCount) else { throw MapStoreError.rejected("A 3D surface file has an invalid size.") }
            guard a.sha256.utf8.count == 64, a.sha256.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
                throw MapStoreError.rejected("A 3D surface file has an invalid checksum.")
            }
            let lo = a.boundsMin, hi = a.boundsMax
            guard lo.x.isFinite, lo.y.isFinite, lo.z.isFinite, hi.x.isFinite, hi.y.isFinite, hi.z.isFinite,
                  lo.x <= hi.x, lo.y <= hi.y, lo.z <= hi.z else { throw MapStoreError.rejected("A 3D surface file has invalid bounds.") }
            total += a.byteCount
        }
        guard total <= Self.maxMeshTotalBytes else { throw MapStoreError.rejected("The 3D surface files are too large in total.") }
    }
}
