//
// File:     Waypoint/Vision/SignReader.swift
// Owner:    C (Vision)
// Purpose:  On-device OCR of door signs. Runs Apple Vision text recognition on a throttled subset
//           of camera frames, extracts room numbers (`RoomNumberParser`), and only reports a
//           number once it has been read several times (`ConsensusFilter`) - so a single bad
//           frame never reaches the user or the map.
// Used by:  Volunteer mode (suggest a label for the nearest node; a human confirms it) and
//           Navigator mode (announce "Room 204 on your right"). Neither is wired up yet.
// Threading: Vision work runs on a private serial queue; `onRoomNumberConfirmed` is called on MAIN.
// Cost:     ~2 Hz is plenty; text recognition at .accurate is expensive. Raise `minInterval`
//           if the phone gets hot (thermal state .serious means back off further).
// Status:   SCAFFOLD. TODO(C): wire into CaptureController/NavigationController; add Rice Hall sign
//           formats to RoomNumberParser; consider region-of-interest cropping to speed up OCR.
//
import ARKit
import Vision
import WaypointCore

final class SignReader {

    /// Called on the main queue the first time each room number reaches consensus.
    var onRoomNumberConfirmed: ((String) -> Void)?

    private let queue = DispatchQueue(label: "waypoint.signreader", qos: .userInitiated)
    private var consensus = ConsensusFilter(requiredReads: 3)
    private var lastRun: TimeInterval = 0
    private var isBusy = false
    private let minInterval: TimeInterval = 0.5

    /// Feed ARKit frames; throttling is handled here. Safe to call from the AR delegate (main queue).
    func process(_ frame: ARFrame) {
        guard !isBusy, frame.timestamp - lastRun >= minInterval else { return }
        lastRun = frame.timestamp
        isBusy = true

        let pixelBuffer = frame.capturedImage
        queue.async { [weak self] in
            guard let self else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // room numbers are not words
            // Phone held in portrait: the captured image is rotated 90 degrees.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            var confirmed: [String] = []
            do {
                try handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                confirmed = self.consensus.ingest(RoomNumberParser.extract(from: lines))
            } catch {
                Log.vision.error("OCR failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.isBusy = false
                for number in confirmed {
                    Log.vision.info("confirmed room number \(number)")
                    self.onRoomNumberConfirmed?(number)
                }
            }
        }
    }

    func reset() {
        queue.async { [weak self] in self?.consensus.reset() }
    }
}
