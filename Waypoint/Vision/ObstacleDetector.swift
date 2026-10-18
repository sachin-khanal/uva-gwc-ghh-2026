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
    /// Nearest thing to each side as well, so guidance can suggest a way round and say why
    /// ("Slightly left, there is a wall ahead"). nil to a side means nothing was seen there, which
    /// for depth means open space. See `AvoidanceAdvisor` for how it is used, and its safety note.
    var clearance: AvoidanceAdvisor.Clearance = .init()
}

enum ObstacleDetector {

    /// Fraction of the sensor COLUMNS scanned (the phone's vertical extent) and of the ROWS (the left-right corridor).
    static let columnFractions: ClosedRange<Float> = 0.10...0.90
    static let corridorRowFractions: ClosedRange<Float> = 0.36...0.64
    /// Look at every n-th pixel: 256x192 -> a few thousand samples is plenty and keeps this cheap at 10 Hz.
    static let sampleStride = 2
    /// A sample further than this from the centre line counts as "to the side" rather than ahead.
    /// Roughly half a body width, so the ahead corridor stays the thing you would walk into.
    static let sideOffsetMetres: Float = 0.35

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

    /// Where the FLOOR is in front of the user, for `FloorAhead`. Everything else here hunts for things
    /// that stick up; this is the opposite question, and the only one that can see a staircase going
    /// DOWN - which puts nothing in the obstacle band and otherwise reads as clear corridor.
    ///
    /// Works in the USER's frame rather than the sensor's: every sample is unprojected to world, then
    /// measured along the camera's forward direction on the floor plane. Only the strip the user is
    /// about to walk down counts (`floorCorridorMetres` either side), and only points low enough to be
    /// floor rather than furniture. Per distance bucket we keep the LOWEST surface, because a drop is
    /// defined by how far down it goes.
    static func floorSamples(in frame: ARFrame) -> [FloorSample] {
        guard let depthData = frame.sceneDepth else { return [] }
        let depthMap = depthData.depthMap, confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }

        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let K = frame.camera.intrinsics
        let sx = Float(width) / Float(frame.camera.imageResolution.width)
        let sy = Float(height) / Float(frame.camera.imageResolution.height)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, cx = K[2][0] * sx, cy = K[2][1] * sy
        let transform = frame.camera.transform
        let camera = Geometry.translation(of: transform)
        var forward = Geometry.cameraForward(of: transform)
        forward.y = 0
        guard simd_length(forward) > 1e-3 else { return [] }
        forward = simd_normalize(forward)
        let right = SIMD3<Float>(-forward.z, 0, forward.x) // forward rotated -90 degrees about +y
        let confidenceFloor = UInt8(ARConfidenceLevel.medium.rawValue)

        // Lowest surface per quarter-metre of distance.
        var lowest: [Int: Float] = [:]
        var row = 0
        while row < height {
            let depthRow = depthBase.advanced(by: row * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: row * confStride).assumingMemoryBound(to: UInt8.self)
            var col = 0
            while col < width {
                defer { col += floorSampleStride }
                if let confRow, confRow[col] < confidenceFloor { continue }
                let d = depthRow[col]
                guard d.isFinite, d > 0.1, d <= FloorAhead.lookaheadMeters * 2 else { continue }
                let u = Float(col) + 0.5, v = Float(row) + 0.5
                let local = SIMD4<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d, 1)
                let world = transform * local
                let point = SIMD3<Float>(world.x, world.y, world.z)
                // Floor, not furniture or walls above knee height.
                guard point.y <= camera.y - floorMinimumBelowCamera else { continue }
                let rel = point - camera
                let ahead = simd_dot(rel, forward)
                guard ahead > 0.25, ahead <= FloorAhead.lookaheadMeters else { continue }
                guard abs(simd_dot(rel, right)) <= floorCorridorMetres else { continue }
                let bucket = Int(ahead / floorBucketMetres)
                lowest[bucket] = min(lowest[bucket] ?? .greatestFiniteMagnitude, point.y)
            }
            row += floorSampleStride
        }
        return lowest.map { FloorSample(ahead: (Float($0.key) + 0.5) * floorBucketMetres, y: $0.value) }
    }

    /// Half-width of the strip of floor the user is about to walk down. Wider than `sideOffsetMetres`
    /// because a staircase edge runs across the whole path, and missing it is the expensive mistake.
    static let floorCorridorMetres: Float = 0.45
    /// Points above this (measured down from the camera) are furniture or walls, not floor.
    static let floorMinimumBelowCamera: Float = 0.6
    /// Distance buckets for keeping the lowest surface.
    static let floorBucketMetres: Float = 0.25
    /// Coarser than the centre scan: a floor edge is a big feature and this runs every frame.
    static let floorSampleStride = 4

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
        var nearestLeft: Float?
        var nearestRight: Float?
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
                // Unproject to camera space (x right in the image, y UP in the image, camera looks along -z) and then to world space.
                let u = Float(col) + 0.5, v = Float(row) + 0.5
                let cameraLocal = SIMD3<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d)
                let world = transform * SIMD4<Float>(cameraLocal, 1)
                guard ObstacleBand.contains(pointY: world.y, cameraY: cameraY) else { continue }

                // Which side is this, from the USER's point of view? In portrait the camera's own x
                // axis points toward the bottom of the phone, so image-x is NOT the user's right;
                // `cameraLocalToUser` is the same conversion the audio beacon uses.
                let lateral = Geometry.cameraLocalToUser(cameraLocal).x
                if lateral < -Self.sideOffsetMetres {
                    if d < (nearestLeft ?? .greatestFiniteMagnitude) { nearestLeft = d }
                    continue
                }
                if lateral > Self.sideOffsetMetres {
                    if d < (nearestRight ?? .greatestFiniteMagnitude) { nearestRight = d }
                    continue
                }
                if let b = best, d >= b.depth { continue } // only the nearest straight-ahead one matters
                best = DepthHit(depth: d, worldPoint: SIMD3<Float>(world.x, world.y, world.z), side: .ahead)
            }
            row += sampleStride
        }
        guard var hit = best else {
            // Nothing ahead, but the sides may still be worth reporting to anything that asks.
            return nil
        }
        hit.clearance = AvoidanceAdvisor.Clearance(ahead: hit.depth, left: nearestLeft, right: nearestRight)
        return hit
    }
}
