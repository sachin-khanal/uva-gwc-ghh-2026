//
// File:     Waypoint/Vision/KeyframeRecorder.swift
// Owner:    C (Vision) with A (maps)
// Purpose:  Turns camera frames into `Keyframe` descriptors during a scan, and matches a live frame
//           against a map's keyframes when relocalizing.
//
// How:      Apple Vision's `VNGenerateImageFeaturePrintRequest` produces a whole-image descriptor and
//           knows how to compare two of them. It runs on-device, needs no model file and no network,
//           and the descriptor is a few kilobytes - small enough to store a hundred of them in a map.
//
// Privacy:  only the DESCRIPTOR is kept. It cannot be turned back into the photograph, which matters
//           for a map recorded inside a building full of people and then shared between phones.
//
// Cost:     a feature print takes a few milliseconds, so this is throttled hard - by DISTANCE while
//           scanning (one per `spacing` metres) and by TIME while relocalizing. Never on the main
//           thread's critical path: callers hop to a background queue.
//
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE. The distance threshold in `KeyframeIndex` is a guess:
//           Vision's feature-print distances are not normalised and want calibrating in a real corridor.
//
import CoreImage
import Foundation
import Vision
import WaypointCore

enum KeyframeRecorder {

    /// One keyframe per this many metres walked. Closer together wastes space on near-identical views.
    static let defaultSpacing: Float = 2.5

    /// Distance between two stored descriptors, for `KeyframeIndex.best`. nil when they cannot be
    /// compared (different Vision revisions, corrupt data).
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let left = observation(from: a), let right = observation(from: b) else { return nil }
        var value = Float(0)
        do {
            try left.computeDistance(&value, to: right)
        } catch {
            return nil
        }
        return value
    }

    /// Rebuilds a `VNFeaturePrintObservation` from stored bytes. Vision has no public initializer for
    /// one, so we keep the archived observation rather than the raw `data` blob.
    private static func observation(from data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Archives an observation for storage in the map.
    static func archive(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    /// Descriptor for a frame, in the archived form `distance` expects.
    static func storableDescriptor(for pixelBuffer: CVPixelBuffer,
                                   orientation: CGImagePropertyOrientation) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return archive(observation)
    }
}
