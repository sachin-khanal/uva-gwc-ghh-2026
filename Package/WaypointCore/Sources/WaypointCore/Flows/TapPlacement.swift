//
// File:     Flows/TapPlacement.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  "Tap to place" for the new Scanner: the volunteer taps a spot in the camera view (a door across
//           the hall, a room sign) instead of walking up to it. This decides WHERE the tag goes and whether
//           the spot is close enough to accept:
//             * height: moved to the camera's height, like a normal tag (MapBuilder keeps nodes at the height
//               they were recorded at; routing works on the floor plane);
//             * stand-off: pulled `standOff` metres back toward the volunteer, so a tap on a door or wall
//               becomes a spot you can stand at in front of it, not a point inside the wall;
//             * range: at most `maxDistance` metres away. The tag is joined to the walk with a STRAIGHT edge
//               (MapBuilder.addPOI), and guidance will lead a blind user along it, so long reaches across
//               a space the camera only glimpsed are refused.
// Status:   DONE (logic), tested in TapPlacementTests.
//
import Foundation
import simd

public enum TapPlacement {

    /// Farthest a tapped spot may be from the volunteer, measured on the floor plane (metres).
    public static let maxDistance: Float = 6
    /// How far a tapped point is pulled back toward the volunteer (metres).
    public static let standOff: Float = 0.4
    /// Closer than this, the point is used as is (pulling back would land behind the volunteer).
    public static let minPullDistance: Float = 0.8

    public enum Result: Equatable, Sendable {
        /// Place the tag here; `distance` is from the volunteer, floor plane, metres.
        case placeable(position: SIMD3<Float>, distance: Float)
        /// The tapped spot is `distance` metres away, beyond `maxDistance`.
        case tooFar(distance: Float)
    }

    /// - Parameters:
    ///   - hit: where the tap met the scanned surface, map/world frame.
    ///   - camera: the volunteer's camera position, same frame.
    public static func evaluate(hit: SIMD3<Float>, camera: SIMD3<Float>) -> Result {
        let flat = SIMD3<Float>(hit.x - camera.x, 0, hit.z - camera.z)
        let distance = simd_length(flat)
        guard distance <= maxDistance else { return .tooFar(distance: distance) }

        var position = SIMD3<Float>(hit.x, camera.y, hit.z)
        if distance >= minPullDistance {
            position -= flat / distance * standOff
        }
        return .placeable(position: position, distance: Geometry.horizontalDistance(camera, position))
    }

    /// A chosen spot is still usable when the tag is finally made (the volunteer may have walked on).
    public static func isInRange(_ position: SIMD3<Float>, camera: SIMD3<Float>) -> Bool {
        Geometry.horizontalDistance(camera, position) <= maxDistance
    }
}
