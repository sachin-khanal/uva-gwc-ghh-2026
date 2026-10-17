//
// File:     Waypoint/Guidance/SpeechGuide.swift
// Owner:    B (Navigation/Feedback)
// Purpose:  Speaks FeedbackPlanner's `.speak` actions with AVSpeechSynthesizer.
//           * `.high` priority interrupts whatever is being said (obstacle, lost position).
//           * `.normal` is skipped if the synthesizer is busy, so speech never piles up.
//           * Identical text within 3 s is dropped (belt and braces on top of the planner's dedupe).
// Note:     This is separate from VoiceOver. Navigator mode keeps working with VoiceOver off.
// Status:   SCAFFOLD. TODO(B): speech rate setting; optionally duck the beacon while speaking.
//
import AVFoundation
import WaypointCore

final class SpeechGuide {

    private let synthesizer = AVSpeechSynthesizer()
    private var lastText: String?
    private var lastTime: Date = .distantPast

    func say(_ text: String, priority: SpeechPriority) {
        let now = Date()
        if text == lastText, now.timeIntervalSince(lastTime) < 3 { return }

        switch priority {
        case .high:
            synthesizer.stopSpeaking(at: .immediate)
        case .normal:
            if synthesizer.isSpeaking { return }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        lastText = text
        lastTime = now
        Log.guidance.info("say: \(text)")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
