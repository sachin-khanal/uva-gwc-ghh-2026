//
// File:     Waypoint/Guidance/Speaker.swift
// Owner:    B (Navigation/Feedback), used by U3's UI layer
// Purpose:  THE one voice of the app. Owns the only `AVSpeechSynthesizer` there is, so two parts of
//           the app can never talk over each other.
//
// Why:      `SpeechGuide` (guidance) and `Announcer` (the new UI) each owned a synthesizer. Neither
//           could see the other: SpeechGuide's "don't pile up" check (`synthesizer.isSpeaking`) and
//           Announcer's `stopSpeaking` only ever applied to their own. At arrival both fired and the
//           user heard two voices at once (reported on device 2026-10-17). Both now call this.
//
// Rules:    live in `SpeechGate` (WaypointCore) so they are unit-tested; this file is just the
//           AVFoundation plumbing.
//
// VoiceOver: everything audible goes through here, including when VoiceOver is running, so there is
//           exactly one voice coming from the app. VoiceOver will still read focused elements in its
//           own voice - we do not control that - but the app no longer adds a second stream of its
//           own. Screen-reader-only chatter (the sighted scanner screens) still goes to VoiceOver via
//           `Announcer.voiceOverOnly` and never reaches this class.
//
// Threading: main thread only (both callers are already on it).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import AVFoundation
import WaypointCore

final class Speaker {

    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var gate = SpeechGate()

    private init() {}

    /// Monotonic clock: unaffected by the wall clock changing mid-demo.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func say(_ text: String, priority: SpeechPriority) {
        switch gate.decide(text: text, priority: priority, isSpeaking: synthesizer.isSpeaking, now: now) {
        case .drop:
            return
        case .interrupt:
            synthesizer.stopSpeaking(at: .immediate)
        case .speak:
            break
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        Log.guidance.info("say: \(text)")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        gate.reset()
    }
}
