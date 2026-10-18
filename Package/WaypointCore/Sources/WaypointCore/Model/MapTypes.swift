//
// File:     Model/MapTypes.swift
// Module:   WaypointCore
// Owner:    SHARED CONTRACT. Changing anything here affects all four people. Announce it in
//           docs/WORKLOG.md and bump `BuildingMap.schemaVersion` if the JSON shape changes.
// Purpose:  The small value types that make up a building map: node kinds, hazards, nodes,
//           edges and the optional QR/image marker used as a relocalization fallback.
// Coordinates: every `position` is in METERS in the MAP coordinate frame, using ARKit's
//           convention: +x = right, +y = up, +z = toward the viewer (so a camera looks down -z).
//           Walking "forward" from the start of a scan therefore usually decreases z.
// JSON:     `SIMD3<Float>` encodes as a 3-element array, e.g. "position": [1.2, 0, -9].
//
import Foundation
import simd

/// Segment ids end up inside FILE NAMES (`worldmap-<id>.arworldmap`) and cloud STORAGE PATHS
/// (`<owner>/<map>/<id>.arworldmap`), and they arrive inside maps from other people. So they are
/// restricted to a safe alphabet: no `/`, `..`, `%`, spaces or empty strings. Enforced in
/// `MapBundle.validate()`, `MapStore` and `SyncEngine` (defense in depth).
public enum SegmentID {
    public static func isValid(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        } // 0-9 A-Z a-z - _
    }
}

/// What a node represents in the real world.
public enum NodeKind: String, Codable, CaseIterable, Sendable {
    /// A breadcrumb dropped automatically while the volunteer walks (no label).
    case corridor
    /// A door the volunteer tagged (may carry a label such as "Door to stairwell").
    case door
    /// A staircase. Edges leading to it are tagged with `Hazard.stairs`.
    case stairs
    /// An elevator.
    case elevator
    /// A destination room, usually with a label like "Room 204".
    case room
    /// A hallway intersection.
    case junction
}

/// A property of an edge that guidance should warn about or route around.
public enum Hazard: String, Codable, Sendable {
    /// The edge goes up or down stairs. The router avoids these unless `allowStairs` is true.
    case stairs
    /// A narrow passage (user should slow down).
    case narrow
    /// A raised door threshold (trip hazard).
    case doorThreshold
}

/// The floor area a room occupies, as a gravity-aligned rectangle (yaw only).
///
/// Why it exists: a `MapNode` is a single POINT, so "arrive at Room 204" could only ever mean "get
/// within N metres of the spot the volunteer was standing when they tagged it". A blind user walking
/// into a room needs the app to know they are INSIDE it, not near a pin (device report 2026-10-17).
/// Derived from the LiDAR mesh's wall faces by `RoomExtractor`; nil for rooms scanned before this
/// existed, or when the space is open and no enclosure was found, in which case guidance falls back
/// to `ArrivalRadius`.
///
/// A rectangle, not a polygon: it is what the volunteer sees as the scan box, it survives JSON
/// readably, and "is this point inside" stays trivial. Rooms that are not rectangles are covered by
/// their bounding rectangle, which may include a little space outside - `areaSquareMeters` records
/// the ACTUAL enclosed floor area so the difference is visible.
public struct RoomExtent: Codable, Hashable, Sendable {
    /// Centre of the rectangle in the map frame. `y` is floor level.
    public var center: SIMD3<Float>
    /// Half width along the rectangle's own x and z axes, metres.
    public var halfExtents: SIMD2<Float>
    /// Rotation about the vertical axis, radians.
    public var yaw: Float
    /// Floor area actually enclosed by walls, which is <= the rectangle's area.
    public var areaSquareMeters: Float
    /// Ceiling height, metres, when it was measured (format 3, optional; written by the web viewer's pipeline, ignored by guidance).
    public var heightMeters: Float?

    /// The same rectangle expressed in another frame. `m` must be a yaw-only rigid motion (no scale),
    /// which is what `ManualAlignment` produces, so the half extents and the area are unchanged and
    /// only the centre and the rotation move. Used when a room is measured in a live ARKit session
    /// that has been aligned onto a saved map by hand.
    public func transformed(by m: simd_float4x4) -> RoomExtent {
        RoomExtent(center: Geometry.transformPoint(m, center),
                   halfExtents: halfExtents,
                   yaw: yaw + Geometry.yawAboutY(of: m),
                   areaSquareMeters: areaSquareMeters,
                   heightMeters: heightMeters)
    }

    public init(center: SIMD3<Float>, halfExtents: SIMD2<Float>, yaw: Float, areaSquareMeters: Float, heightMeters: Float? = nil) {
        self.center = center
        self.halfExtents = halfExtents
        self.yaw = yaw
        self.areaSquareMeters = areaSquareMeters
        self.heightMeters = heightMeters
    }

    /// Is `point` inside the room? `margin` widens the rectangle, e.g. to count a doorway as "in".
    public func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        let d = point - center
        // Rotate into the rectangle's own frame (yaw about +y).
        let c = cos(-yaw), s = sin(-yaw)
        let x = d.x * c + d.z * s
        let z = -d.x * s + d.z * c
        return abs(x) <= halfExtents.x + margin && abs(z) <= halfExtents.y + margin
    }

    /// Longest straight line you could walk inside, used to sanity-check a suspicious extraction.
    public var diagonalMeters: Float { simd_length(halfExtents) * 2 }
}

/// One point of interest or breadcrumb on the map.
public struct MapNode: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: NodeKind
    /// Human-readable name, e.g. "Room 204". `nil` for plain breadcrumbs.
    public var label: String?
    /// Meters, in the map frame (see file header).
    public var position: SIMD3<Float>
    /// Which ARWorldMap segment this node was recorded in (see Architecture.md section 4.2).
    public var segmentId: String
    /// Which device created it ("iPhone-ab12"). Used when several people extend one map.
    public var createdBy: String
    /// For a `.room`, the floor area it occupies, when the scan could work it out. See `RoomExtent`.
    /// Optional and defaulted, so maps written before schema 2 decode unchanged.
    public var extent: RoomExtent?

    public init(
        id: UUID = UUID(),
        kind: NodeKind,
        label: String? = nil,
        position: SIMD3<Float>,
        segmentId: String = "seg1",
        createdBy: String = "unknown",
        extent: RoomExtent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.position = position
        self.segmentId = segmentId
        self.createdBy = createdBy
        self.extent = extent
    }
}

/// One 3D surface file of a map that other tools (the web viewer) can draw: an OBJ whose bytes are pinned by a SHA-256, stored in the
/// `meshes` bucket under `<storageOwner or the map owner>/<map id>/...`. Format 3, OPTIONAL. The app does not create these yet (its own
/// 3D model is `model.usdz` next to the map), but it CARRIES them: loading and saving a map keeps them, merging unions them, and
/// `MapBundle.validate()` rejects malformed ones. Field names and rules match web/router.js (U3). See docs/MAP_FORMAT.md.
public struct MeshAsset: Codable, Hashable, Sendable {
    public var id: UUID
    /// The scan segment this surface was captured in; must exist in the map.
    public var segmentId: String
    /// Only "obj" for now.
    public var format: String
    /// Only "map" (the map frame).
    public var coordinateFrame: String
    public var byteCount: Int
    /// Lowercase hex SHA-256 of the file bytes (64 characters).
    public var sha256: String
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    /// Contributor whose storage folder holds the file; nil = the map's owner.
    public var storageOwner: UUID?

    public init(id: UUID = UUID(), segmentId: String, format: String = "obj", coordinateFrame: String = "map",
                byteCount: Int, sha256: String, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, storageOwner: UUID? = nil) {
        self.id = id
        self.segmentId = segmentId
        self.format = format
        self.coordinateFrame = coordinateFrame
        self.byteCount = byteCount
        self.sha256 = sha256
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.storageOwner = storageOwner
    }
}

/// An undirected walkable connection between two nodes.
public struct MapEdge: Codable, Hashable, Sendable {
    public var from: UUID
    public var to: UUID
    /// Walking distance in meters. For builder-made edges this equals the straight-line distance.
    public var distance: Float
    public var hazard: Hazard?

    public init(from: UUID, to: UUID, distance: Float, hazard: Hazard? = nil) {
        self.from = from
        self.to = to
        self.distance = distance
        self.hazard = hazard
    }

    /// True if this edge joins `a` and `b` in either direction.
    public func connects(_ a: UUID, _ b: UUID) -> Bool {
        (from == a && to == b) || (from == b && to == a)
    }
}

/// A printed QR code / reference image taped to a wall at a surveyed spot.
/// Used when ARWorldMap relocalization fails: seeing the marker tells us exactly where we are.
public struct MarkerRef: Codable, Hashable, Sendable {
    /// Must match the ARReferenceImage name in the app's asset catalog group "WaypointMarkers".
    public var name: String
    /// Printed width in meters (ARKit needs the true size to estimate pose).
    public var widthMeters: Float
    /// Where the marker's center is, in the map frame.
    public var position: SIMD3<Float>
    /// Rotation of the marker about the vertical (y) axis in the map frame, radians.
    public var yaw: Float

    public init(name: String, widthMeters: Float, position: SIMD3<Float>, yaw: Float = 0) {
        self.name = name
        self.widthMeters = widthMeters
        self.position = position
        self.yaw = yaw
    }
}
