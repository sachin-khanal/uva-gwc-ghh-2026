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

final class Speaker: NSObject {

    static let shared = Speaker()

    /// A queued line older than this is thrown away instead of spoken. Queuing stopped guidance being
    /// chopped into fragments, but a direction spoken two seconds late to somebody who has kept
    /// walking is worse than silence - it contradicts what they can feel (device report 2026-10-17).
    private static let maxQueuedAge: TimeInterval = 2.0

    private let synthesizer = AVSpeechSynthesizer()
    private var gate = SpeechGate()
    /// At most ONE line waits its turn, and it is always the NEWEST one. A backlog is what produced
    /// contradictory directions; the latest cue is the only one that still describes the world.
    private var pending: (text: String, priority: SpeechPriority, queuedAt: TimeInterval)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Monotonic clock: unaffected by the wall clock changing mid-demo.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func say(_ text: String, priority: SpeechPriority) {
        switch gate.decide(text: text, priority: priority, isSpeaking: synthesizer.isSpeaking, now: now) {
        case .drop:
            return
        case .interrupt:
            // Safety only. Anything waiting is now stale, so it goes too.
            pending = nil
            synthesizer.stopSpeaking(at: .immediate)
        case .enqueue:
            // Hold it ourselves rather than handing it to AVSpeechSynthesizer, whose own queue cannot
            // be revised: by the time it would speak, the user has moved and the line may be wrong.
            // Only ONE line waits, and it is the most important one offered - not simply the last,
            // which would let an incidental landmark displace a turn.
            if let current = pending, current.priority > priority { return }
            pending = (text, priority, now)
            return
        case .speak:
            break
        }

        speakNow(text)
    }

    private func speakNow(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A short pause after each line so two queued cues do not run together as one sentence.
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
        Log.guidance.info("say: \(text)")
    }

    /// Speaks whatever is waiting, if it is still worth saying.
    private func speakPendingIfFresh() {
        guard let next = pending else { return }
        pending = nil
        let age = now - next.queuedAt
        guard age <= Self.maxQueuedAge else {
            Log.guidance.info("dropped stale line after \(String(format: "%.1f", age))s: \(next.text)")
            return
        }
        speakNow(next.text)
    }

    func stop() {
        pending = nil
        synthesizer.stopSpeaking(at: .immediate)
        gate.reset()
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakPendingIfFresh()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancelled means something more important is being said; whatever was waiting is stale.
        pending = nil
    }
}
