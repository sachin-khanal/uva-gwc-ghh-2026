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

    /// The voice to speak with: the Siri voice for the phone's language when one is installed (Settings > Accessibility > Spoken Content >
    /// Voices > Siri), else the best installed voice, else the system default. Rule in `VoicePicker` (unit-tested); chosen once.
    static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceCandidate(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
        let id = VoicePicker.choose(from: candidates, language: language)
        Log.guidance.info("voice: \(id ?? "system default") for \(language)")
        return id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }()

    /// Monotonic clock: unaffected by the wall clock changing mid-demo.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func say(_ text: String, priority: SpeechPriority) {
        switch gate.decide(text: text, priority: priority, isSpeaking: synthesizer.isSpeaking, now: now) {
        case .drop:
            return
        case .interrupt:
            // Safety only. Everything queued behind the current line is now stale, so it goes too.
            synthesizer.stopSpeaking(at: .immediate)
        case .enqueue, .speak:
            // AVSpeechSynthesizer queues utterances natively and speaks them in order, which is
            // exactly what we want: no fragment, no overlap, and a natural gap between lines.
            break
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice // nil = the system's default voice for the phone's language
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A short pause after each line so two queued cues do not run together as one sentence.
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
        Log.guidance.info("say: \(text)")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        gate.reset()
    }
}
