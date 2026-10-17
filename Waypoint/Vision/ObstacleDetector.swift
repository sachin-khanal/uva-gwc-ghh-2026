//
// File:     Waypoint/Vision/ObstacleDetector.swift
// Owner:    C (Vision)
// Purpose:  Reads the LiDAR depth map ARKit attaches to each frame (`frame.sceneDepth`) and returns
//           the NEAREST trusted distance in the region directly in front of the user.
//           WaypointCore's `ObstacleClassifier` then turns that number into clear/caution/stop.
// Depth map: 256x192 Float32 meters, in the sensor's landscape orientation. Phone held PORTRAIT
//           => sensor-x runs along the portrait-vertical axis. The central box below is symmetric
//           enough that it works either way, but if you want a tall "body-width" corridor
//           (instead of a square) swap which axis you narrow - tune on a device.
// Confidence: ARKit supplies a per-pixel confidence map; we ignore .low pixels (noisy at edges,
//           glass, dark surfaces) and non-finite or implausibly-near (<0.1 m) values.
// Status:   SCAFFOLD. TODO(C): use a low percentile instead of the minimum to reject single-pixel
//           noise; add a downward region to catch drop-offs/descending stairs.
//
import ARKit

enum ObstacleDetector {

    /// Fraction of the depth map to sample, centered. 0.3 x 0.5 = middle 30% wide, middle 50% tall.
    static let regionWidthFraction: Float = 0.3
    static let regionHeightFraction: Float = 0.5

    /// - Returns: smallest trusted depth (meters) in the forward region, or nil if none were trusted.
    static func nearestDepth(in frame: ARFrame) -> Float? {
        guard let depthData = frame.sceneDepth else { return nil }
        return nearestDepth(depthMap: depthData.depthMap, confidenceMap: depthData.confidenceMap)
    }

    static func nearestDepth(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) -> Float? {
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

        let x0 = Int(Float(width) * (0.5 - regionWidthFraction / 2))
        let x1 = Int(Float(width) * (0.5 + regionWidthFraction / 2))
        let y0 = Int(Float(height) * (0.5 - regionHeightFraction / 2))
        let y1 = Int(Float(height) * (0.5 + regionHeightFraction / 2))

        var nearest: Float?
        for y in y0..<y1 {
            let depthRow = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            for x in x0..<x1 {
                if let confRow, confRow[x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                let d = depthRow[x]
                guard d.isFinite, d > 0.1 else { continue }
                if nearest == nil || d < nearest! { nearest = d }
            }
        }
        return nearest
    }
}
