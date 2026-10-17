//
// File:     Geometry/Geometry.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps) - used by B (navigation) as well.
// Purpose:  Tiny, well-tested math helpers shared by capture, relocalization and guidance:
//           transforming points/directions by 4x4 matrices, flattening to the floor plane,
//           signed bearing, and the map->world transform derived from a marker sighting.
// Why here: This math is easy to get subtly wrong (sign of the bearing, yaw direction), and we
//           cannot debug it by walking around. Having it in the package means `make test`
//           proves it. If you change a convention, update GeometryTests.
//
import Foundation
import simd

public enum Geometry {

    /// Applies a 4x4 transform to a point (w = 1, so translation applies).
    public static func transformPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Applies a 4x4 transform to a direction (w = 0, so translation is ignored).
    public static func transformDirection(_ m: simd_float4x4, _ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(d.x, d.y, d.z, 0)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// The translation column of a transform (for a camera transform: the camera position).
    public static func translation(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// The direction an ARKit camera is looking: the negative z axis of its transform.
    public static func cameraForward(of m: simd_float4x4) -> SIMD3<Float> {
        let f = transformDirection(m, SIMD3<Float>(0, 0, -1))
        return f
    }

    /// Distance between two points ignoring height (we navigate on a floor plane).
    public static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = b - a
        return (d.x * d.x + d.z * d.z).squareRoot()
    }

    /// Signed angle in radians from the user's forward direction to the target, on the floor plane.
    /// Positive = target is to the user's RIGHT, negative = LEFT, +-pi = directly behind.
    /// Returns 0 if either vector has no horizontal component (looking straight up/down).
    public static func signedBearing(forward: SIMD3<Float>, toTarget d: SIMD3<Float>) -> Float {
        let fx = forward.x, fz = forward.z
        let dx = d.x, dz = d.z
        if (fx * fx + fz * fz) < 1e-6 || (dx * dx + dz * dz) < 1e-6 { return 0 }
        let cross = fx * dz - fz * dx
        let dot = fx * dx + fz * dz
        return atan2(cross, dot)
    }

    /// Builds an ARKit-style camera transform at `position` looking along `forward` (horizontal part
    /// only, so the camera stays level). The camera looks down its local -z, local +y is up and
    /// local +x is to the right. Used by the simulated walker so the audio code can be exercised
    /// without an AR session. Falls back to facing -z if `forward` has no horizontal component.
    public static func cameraTransform(position: SIMD3<Float>, forward: SIMD3<Float>) -> simd_float4x4 {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        f = simd_length(f) > 1e-5 ? simd_normalize(f) : SIMD3<Float>(0, 0, -1)
        let up = SIMD3<Float>(0, 1, 0)
        let zAxis = -f                       // camera local +z points backwards
        let xAxis = simd_normalize(simd_cross(up, zAxis)) // right
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(xAxis.x, xAxis.y, xAxis.z, 0)
        m.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        m.columns.2 = SIMD4<Float>(zAxis.x, zAxis.y, zAxis.z, 0)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// Rotation about the +y (up) axis as a 4x4 matrix.
    public static func rotationY(_ radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(0, 1, 0)))
    }

    /// A pure translation matrix.
    public static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }
}

extension MarkerRef {
    /// Pose of the marker expressed in the MAP frame (what the volunteer surveyed).
    public var poseInMap: simd_float4x4 {
        Geometry.translationMatrix(position) * Geometry.rotationY(yaw)
    }

    /// Given where ARKit sees the marker in WORLD coordinates (an `ARImageAnchor.transform`),
    /// returns the transform that converts MAP-frame points into WORLD-frame points:
    ///     worldPoint = mapToWorld * mapPoint
    /// Derivation: markerWorld = mapToWorld * markerMap  =>  mapToWorld = markerWorld * markerMap^-1.
    /// NOTE: ARImageAnchor's axes are x right, y OUT of the image, z down the image. When we
    /// wire the real marker (owner A), verify the yaw convention on a device and adjust here +
    /// in GeometryTests so it stays proven.
    public func mapToWorldTransform(markerWorld: simd_float4x4) -> simd_float4x4 {
        markerWorld * poseInMap.inverse
    }
}
