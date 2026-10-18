//
// File:     Model/ManualAlignment.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps)
// Purpose:  Work out where the phone's CURRENT ARKit session sits inside a SAVED map, from two places
//           the volunteer says they are standing at. Used when extending a map: it removes ARKit's
//           relocalization from the critical path, because a sighted volunteer can simply point at a
//           door they already labelled and say "I am here".
//
// Why:      ARKit relocalization (and visual fingerprints, equally) matches what the CAMERA SEES, so
//           it is viewpoint-dependent: a corridor scanned walking one way gives it almost nothing to
//           match when you come back the other way. Extending a map needs the user located before any
//           recording can start, so that difficulty blocks the whole feature. A human looking at a
//           labelled door does not have this problem.
//
// Why TWO places, not one: one place fixes the TRANSLATION only. Without relocalization the session's
//           yaw bears no relation to the map's, so a single point would record the new corridor at an
//           arbitrary angle - a map that looks plausible and is wrong. Two places separated by a few
//           metres fix translation and yaw together.
//
// Frames:   returns WORLD -> MAP (`mapPoint = transform * worldPoint`), the direction the capture path
//           needs: breadcrumbs and tags are produced in session coordinates and must be stored in map
//           coordinates. Rotation is about the vertical axis ONLY - ARKit already aligns +y with
//           gravity in both sessions, so roll and pitch cannot differ and solving for them would only
//           fit noise.
//
// Refusing: the two map points and the two walked points describe the SAME physical walk, so their
//           lengths must agree. If they do not, the volunteer tapped the wrong place (or tracking
//           drifted badly) and the honest answer is to refuse - a bad alignment silently writes every
//           new node into the wrong part of the building, which is far worse than asking them again.
//
// Status:   DONE (pure logic, unit-tested). The capture wiring that uses it is UNVERIFIED ON DEVICE.
//
import Foundation
import simd

public enum ManualAlignment {

    /// The two places must be at least this far apart. Yaw is derived from the direction between them,
    /// so a short baseline turns a small positional error into a large angular one: at 0.5 m apart,
    /// standing 0.2 m off is already 20 degrees of rotation error, which throws a node 3.5 m sideways
    /// ten metres down the corridor.
    public static let minSeparationMeters: Float = 2

    /// How much the walked distance may disagree with the map distance before we refuse. Generous
    /// enough for normal standing-position slop (you cannot stand exactly on a node, and the node is
    /// itself only roughly where the volunteer walked), tight enough to catch tapping the wrong door.
    public static let maxLengthMismatchMeters: Float = 1.0

    /// Why an alignment was refused, so the UI can say something a person can act on.
    public enum Failure: Error, Equatable, Sendable {
        case tooClose(apartMeters: Float)
        case lengthMismatch(mapMeters: Float, walkedMeters: Float)
        case notFinite
    }

    /// - Parameters:
    ///   - mapA/mapB: positions of the two chosen nodes, in the MAP frame.
    ///   - worldA/worldB: where the phone was when the volunteer confirmed each one, in the CURRENT
    ///     session's world frame.
    /// - Returns: world -> map, or the reason it was refused.
    public static func worldToMap(mapA: SIMD3<Float>, worldA: SIMD3<Float>,
                                  mapB: SIMD3<Float>, worldB: SIMD3<Float>)
    -> Result<simd_float4x4, Failure> {
        for v in [mapA, worldA, mapB, worldB] where !(v.x.isFinite && v.y.isFinite && v.z.isFinite) {
            return .failure(.notFinite)
        }
        // Horizontal only: height differences are a nuisance here (the phone is held at slightly
        // different heights, and a node's y is where the camera was, not the floor), and the yaw we
        // are solving for lives entirely in the floor plane.
        let mapDelta = SIMD2<Float>(mapB.x - mapA.x, mapB.z - mapA.z)
        let worldDelta = SIMD2<Float>(worldB.x - worldA.x, worldB.z - worldA.z)
        let mapLength = simd_length(mapDelta)
        let worldLength = simd_length(worldDelta)

        guard mapLength >= minSeparationMeters, worldLength >= minSeparationMeters else {
            return .failure(.tooClose(apartMeters: min(mapLength, worldLength)))
        }
        guard abs(mapLength - worldLength) <= maxLengthMismatchMeters else {
            return .failure(.lengthMismatch(mapMeters: mapLength, walkedMeters: worldLength))
        }

        // Angle of each displacement measured from +z toward +x, so their difference is the rotation
        // about +y that carries the walked direction onto the mapped one.
        let theta = atan2(mapDelta.x, mapDelta.y) - atan2(worldDelta.x, worldDelta.y)
        let rotation = Geometry.rotationY(theta)
        // Anchor on A: after rotating, the walked point must land on the mapped one.
        let rotatedA = Geometry.transformPoint(rotation, worldA)
        let offset = SIMD3<Float>(mapA.x - rotatedA.x, mapA.y - rotatedA.y, mapA.z - rotatedA.z)
        return .success(Geometry.translationMatrix(offset) * rotation)
    }
}
