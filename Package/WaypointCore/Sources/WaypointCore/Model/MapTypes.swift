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

    public init(
        id: UUID = UUID(),
        kind: NodeKind,
        label: String? = nil,
        position: SIMD3<Float>,
        segmentId: String = "seg1",
        createdBy: String = "unknown"
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.position = position
        self.segmentId = segmentId
        self.createdBy = createdBy
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
