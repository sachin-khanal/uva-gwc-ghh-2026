//
// File:     Waypoint/Vision/ObstacleDetector.swift
// Owner:    C (Vision)
// Purpose:  Reads the LiDAR depth map ARKit attaches to each frame (`frame.sceneDepth`) and finds the NEAREST OBSTACLE in the corridor straight
//           ahead of the user: its distance, where it is in the world, and which side it is on. WaypointCore's `ObstacleClassifier` turns the
//           distance into clear/caution/stop; `ObstacleIdentifier` works out WHAT it is.
// Geometry: the depth map is in the SENSOR's orientation (landscape, 256x192). For a phone held UPRIGHT IN PORTRAIT (the posture the app coaches
//           the user into, see PhonePosture):
//             * sensor COLUMN grows toward the BOTTOM of the phone  -> columns are "height"; we scan most of them (head to knee),
//             * sensor ROW grows toward the user's LEFT              -> rows are "left-right"; the corridor straight ahead is the middle ~28 %.
//           Each sample is unprojected with the camera intrinsics to a WORLD point, and only points inside the obstacle band count
//           (`ObstacleBand`: not the floor under the user's feet, not the ceiling), so the result no longer depends on how far the phone is
//           tilted down. (Before 2026-10-17 this was a plain box in depth-map coordinates, which on a portrait phone was the wrong shape.)
// Confidence: ARKit supplies a per-pixel confidence map; we ignore .low pixels (noisy at edges, glass, dark surfaces) and non-finite or
//           implausibly-near (<0.1 m) values.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE with real obstacles. TODO(C): calibrate the band/corridor in a real hallway; stairs-down and
//           ledges (need a downward check); side hits for "chair on your left".
//
import ARKit
import WaypointCore

/// The closest obstacle straight ahead.
struct DepthHit {
    var depth: Float            // meters along the camera's viewing axis
    var worldPoint: SIMD3<Float>
    var side: Side              // v1: always `.ahead` (only the straight-ahead corridor is scanned)
}

enum ObstacleDetector {

    /// Fraction of the sensor COLUMNS scanned (the phone's vertical extent) and of the ROWS (the left-right corridor).
    static let columnFractions: ClosedRange<Float> = 0.10...0.90
    static let corridorRowFractions: ClosedRange<Float> = 0.36...0.64
    /// Look at every n-th pixel: 256x192 -> a few thousand samples is plenty and keeps this cheap at 10 Hz.
    static let sampleStride = 2

    static func centerHit(in frame: ARFrame) -> DepthHit? {
        guard let depthData = frame.sceneDepth else { return nil }
        return centerHit(depthMap: depthData.depthMap, confidenceMap: depthData.confidenceMap, camera: frame.camera)
    }

    /// How much room there is on each side of the user in the next few metres (see `SceneContext`). Scans the whole width of the depth map,
    /// keeps only points inside the obstacle band (not floor / ceiling), and records each one's SIDEWAYS offset: + = the user's right.
    /// Sensor rows grow toward the user's LEFT (see the header), so image-up (local +y) is the user's right.
    static func sideClearances(in frame: ARFrame, ahead: Float?) -> SceneContext? {
        guard let depthData = frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap, confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let K = frame.camera.intrinsics
        let sx = Float(width) / Float(frame.camera.imageResolution.width)
        let sy = Float(height) / Float(frame.camera.imageResolution.height)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, cx = K[2][0] * sx, cy = K[2][1] * sy
        let cameraY = frame.camera.transform.columns.3.y
        let transform = frame.camera.transform
        let confidenceFloor = UInt8(ARConfidenceLevel.medium.rawValue)
        let stride = 3 // coarser than the centre scan: this only needs the nearest wall per side

        var scan = LateralScan()
        let col0 = Int(Float(width) * columnFractions.lowerBound), col1 = Int(Float(width) * columnFractions.upperBound)
        var row = Int(Float(height) * 0.05)
        let row1 = Int(Float(height) * 0.95)
        while row < row1 {
            let depthRow = depthBase.advanced(by: row * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: row * confStride).assumingMemoryBound(to: UInt8.self)
            var col = col0
            while col < col1 {
                defer { col += stride }
                if let confRow, confRow[col] < confidenceFloor { continue }
                let d = depthRow[col]
                guard d.isFinite, d > 0.1, d <= LateralScan.lookaheadMeters else { continue }
                let u = Float(col) + 0.5, v = Float(row) + 0.5
                let local = SIMD4<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d, 1)
                guard ObstacleBand.contains(pointY: (transform * local).y, cameraY: cameraY) else { continue }
                scan.add(lateral: local.y, depth: d)
            }
            row += stride
        }
        return scan.context(ahead: ahead)
    }

    /// Legacy convenience: just the distance.
    static func nearestDepth(in frame: ARFrame) -> Float? { centerHit(in: frame)?.depth }

    static func centerHit(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?, camera: ARCamera) -> DepthHit? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // Camera intrinsics are in captured-image pixels; scale them to the (smaller) depth map.
        let K = camera.intrinsics
        let sx = Float(width) / Float(camera.imageResolution.width)
        let sy = Float(height) / Float(camera.imageResolution.height)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, cx = K[2][0] * sx, cy = K[2][1] * sy
        let transform = camera.transform
        let cameraY = transform.columns.3.y
        let confidenceFloor = UInt8(ARConfidenceLevel.medium.rawValue)

        let col0 = Int(Float(width) * columnFractions.lowerBound), col1 = Int(Float(width) * columnFractions.upperBound)
        let row0 = Int(Float(height) * corridorRowFractions.lowerBound), row1 = Int(Float(height) * corridorRowFractions.upperBound)

        var best: DepthHit?
        var row = row0
        while row < row1 {
            let depthRow = depthBase.advanced(by: row * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: row * confStride).assumingMemoryBound(to: UInt8.self)
            var col = col0
            while col < col1 {
                defer { col += sampleStride }
                if let confRow, confRow[col] < confidenceFloor { continue }
                let d = depthRow[col]
                guard d.isFinite, d > 0.1 else { continue }
                if let b = best, d >= b.depth { continue } // only the nearest matters; skip the unprojection for farther pixels

                // Unproject to camera space (x right in the image, y UP in the image, camera looks along -z) and then to world space.
                let u = Float(col) + 0.5, v = Float(row) + 0.5
                let local = SIMD4<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d, 1)
                let world = transform * local
                guard ObstacleBand.contains(pointY: world.y, cameraY: cameraY) else { continue }
                best = DepthHit(depth: d, worldPoint: SIMD3<Float>(world.x, world.y, world.z), side: .ahead)
            }
            row += sampleStride
        }
        return best
    }
}
