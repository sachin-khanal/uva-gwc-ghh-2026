//
// File:     Waypoint/Vision/ObstacleIdentifier.swift
// Owner:    C (Vision) - requirement from U1: say WHAT is in the way ("trash can", "wall", "chair"), not just "obstacle".
// Purpose:  Given the nearest obstacle (`DepthHit`) works out what kind of thing it is, in two steps, cheapest and most reliable first:
//             1. ARKit MESH CLASSIFICATION at the hit point: the labelled LiDAR mesh knows wall / door / window / table / seat (needs the session
//                to run with `.meshWithClassification`, see Relocalizer). Anything else it calls "none" - which includes a trash can.
//             2. Apple VISION image classification (`VNClassifyImageRequest`) on a crop of the camera image around where the obstacle is.
//                On-device, no download. Its labels ("trash can", "chair", "person", ...) are mapped by `ObstacleLabelMapper`; confidence is kept so
//                the spoken sentence can say "possibly a ..." when unsure.
//           If neither is confident the kind is `.unknown` and the user hears "obstacle" - never a wrong name stated as fact.
// Cost:     runs on a background queue, at most 2 times per second, and only when something is near (the caller decides). The caller speaks a plain
//           "Stop. Obstacle directly ahead." immediately and upgrades it when this finishes (`FeedbackPlanner` re-announces on a kind change).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE with real obstacles. The Vision label vocabulary is printed by `make selftest-e2e`
//           (`vision.classify.vocabulary`): tune `ObstacleLabelMapper` keywords from it. TODO(C): temporal smoothing (vote over a few frames).
//
import ARKit
import CoreImage
import Vision
import WaypointCore

final class ObstacleIdentifier {

    private let queue = DispatchQueue(label: "waypoint.obstacle.identify", qos: .userInitiated)
    private var inFlight = false
    private var lastRequest: TimeInterval = -10

    /// Latest answer and when it was asked for (frame timestamp). Read on the main thread only.
    private(set) var latest: (report: ObstacleReport, at: TimeInterval)?

    func reset() {
        latest = nil
        inFlight = false
        lastRequest = -10
    }

    /// Main thread. Returns immediately; the answer appears in `latest`.
    func request(frame: ARFrame, hit: DepthHit) {
        let now = frame.timestamp
        guard !inFlight, now - lastRequest >= 0.5 else { return }
        inFlight = true
        lastRequest = now
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor } // immutable snapshots
        queue.async { [weak self] in
            let report = Self.identify(pixelBuffer: pixelBuffer, camera: camera, hit: hit, anchors: anchors)
            DispatchQueue.main.async {
                self?.latest = (report, now)
                self?.inFlight = false
                Log.vision.info("obstacle identified: \(report.kind.rawValue) conf=\(String(format: "%.2f", report.confidence)) at \(String(format: "%.1f", report.distanceMeters)) m")
            }
        }
    }

    static func identify(pixelBuffer: CVPixelBuffer, camera: ARCamera, hit: DepthHit, anchors: [ARMeshAnchor]) -> ObstacleReport {
        if let kind = MeshClassLookup.kind(near: hit.worldPoint, anchors: anchors) {
            return ObstacleReport(kind: kind, side: hit.side, distanceMeters: hit.depth, confidence: 0.9)
        }
        if let (kind, confidence) = classifyWithVision(pixelBuffer: pixelBuffer, camera: camera, worldPoint: hit.worldPoint) {
            return ObstacleReport(kind: kind, side: hit.side, distanceMeters: hit.depth, confidence: confidence)
        }
        return ObstacleReport(kind: .unknown, side: hit.side, distanceMeters: hit.depth, confidence: 0)
    }

    /// Crops the camera image around the obstacle and classifies it.
    static func classifyWithVision(pixelBuffer: CVPixelBuffer, camera: ARCamera, worldPoint: SIMD3<Float>) -> (kind: ObstacleKind, confidence: Float)? {
        // The captured image is landscape; `.right` makes it upright for a portrait phone. Its extent is then (height x width) of the buffer.
        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let size = upright.extent.size
        // Where the obstacle is in that upright image (ARKit gives top-left-origin points; Core Image uses bottom-left).
        let p = camera.projectPoint(worldPoint, orientation: .portrait, viewportSize: size)
        let side = size.width * 0.45
        let rect = CGRect(x: p.x - side / 2, y: size.height - p.y - side / 2, width: side, height: side).intersection(upright.extent)
        guard !rect.isNull, rect.width > 48, rect.height > 48 else { return nil }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: upright.cropped(to: rect), options: [:])
        do { try handler.perform([request]) } catch {
            Log.vision.error("obstacle classification failed: \(error.localizedDescription)")
            return nil
        }
        let labels = (request.results ?? []).prefix(15).map { (label: $0.identifier, confidence: $0.confidence) }
        return ObstacleLabelMapper.kind(fromImageLabels: labels)
    }
}

/// Looks up ARKit's surface classification of the mesh triangle nearest to a world point.
enum MeshClassLookup {

    static func kind(near point: SIMD3<Float>, anchors: [ARMeshAnchor], maxDistance: Float = 0.4) -> ObstacleKind? {
        var best: (distance: Float, rawClass: Int)?
        for anchor in anchors {
            let origin = SIMD3<Float>(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            if simd_distance(origin, point) > 8 { continue } // mesh anchors are local patches; skip the ones far away
            let geometry = anchor.geometry
            guard let classes = geometry.classification else { continue } // not recording surface labels
            let faces = geometry.faces, vertices = geometry.vertices
            guard faces.indexCountPerPrimitive == 3, faces.bytesPerIndex == 4 else { continue }
            let m = anchor.transform
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let faceBase = faces.buffer.contents()
            let classBase = classes.buffer.contents().advanced(by: classes.offset)

            func world(_ index: Int) -> SIMD3<Float> {
                let f = vertexBase.advanced(by: index * vertices.stride).assumingMemoryBound(to: Float.self)
                let w = m * SIMD4<Float>(f[0], f[1], f[2], 1)
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            for i in 0..<faces.count {
                let idx = faceBase.advanced(by: i * 3 * 4).assumingMemoryBound(to: UInt32.self)
                let centroid = (world(Int(idx[0])) + world(Int(idx[1])) + world(Int(idx[2]))) / 3
                let d = simd_distance(centroid, point)
                if d < maxDistance, best == nil || d < best!.distance {
                    best = (d, Int(classBase.advanced(by: i * classes.stride).assumingMemoryBound(to: UInt8.self).pointee))
                }
            }
        }
        guard let best, let classification = ARMeshClassification(rawValue: best.rawClass) else { return nil }
        return ObstacleLabelMapper.kind(fromMeshClass: name(of: classification))
    }

    private static func name(of c: ARMeshClassification) -> String {
        switch c {
        case .none: return "none"
        case .wall: return "wall"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .table: return "table"
        case .seat: return "seat"
        case .window: return "window"
        case .door: return "door"
        @unknown default: return "none"
        }
    }
}
