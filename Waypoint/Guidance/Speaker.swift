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
    ///
    /// The budget must be LONGER THAN ONE SPOKEN LINE, and at 2.0 s it was not. A line only ever waits
    /// because the speaker is busy, so it starts its life already ageing: queued behind "Stop. You are
    /// heading toward a wall." (~2.4 s at the default rate, plus `postUtteranceDelay`) it was always
    /// past 2.0 s by the time `didFinish` offered it a turn, and was dropped every single time
    /// ("dropped stale line after 2.4s"). That is why an obstacle announced the stop but never the way
    /// round it, and why a direction sometimes went unsaid while other announcements were happening
    /// (device report 2026-10-18, findings F-5 and F-7). The wait is structural, not lateness.
    /// 4.5 s clears any single cue we speak while still dropping a line that genuinely sat too long.
    private static let maxQueuedAge: TimeInterval = 4.5
    /// The OPENING briefing (where you are, what is around, how to go) is the one line that must not be thrown away as stale, and a newer
    /// cue must not displace it: it is spoken once, before the user has started walking, so its age does not make it wrong (2026-10-18).
    private static let openingMaxQueuedAge: TimeInterval = 15

    private let synthesizer = AVSpeechSynthesizer()
    private var gate = SpeechGate()
    /// What waits its turn. The RULES live in `SpeechQueue` (WaypointCore) so they can be unit-tested;
    /// this file is only the AVFoundation plumbing.
    private var pending = SpeechQueue()
    /// Priority of the line being spoken right now, so `SpeechGate` can keep one safety cue from
    /// cutting off another. nil when nothing is being said.
    private var speakingPriority: SpeechPriority?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

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

    /// - Parameter clearsPending: this line ENDS the walk, so anything still waiting is no longer true.
    ///   Arrival is the case: "You have arrived at Room 542." followed two seconds later by
    ///   "Left 45 degrees." was heard on the phone (2026-10-18) because a turn queued moments earlier
    ///   survived the arrival. Safety interrupts deliberately KEEP what is waiting - that fix is what
    ///   lets a turn follow an obstacle warning - so a terminal line has to say so explicitly.
    func say(_ text: String, priority: SpeechPriority, staysFresh: Bool = false, clearsPending: Bool = false) {
        if clearsPending { pending.clear() }
        switch gate.decide(text: text, priority: priority, isSpeaking: synthesizer.isSpeaking, now: now,
                           speakingPriority: speakingPriority) {
        case .drop:
            return
        case .interrupt:
            // Safety only - and what is waiting is KEPT. It used to be discarded here, on the reasoning
            // that a safety cue makes everything else stale. In a cluttered room that silenced route
            // guidance completely: obstacle cues fired every second or two, each one wiped the queued
            // turn, and the planner had already recorded that turn as announced, so it was never
            // emitted again. A 45 s recorded walk (2026-10-18) shows the screen giving "Turn around",
            // then "Turn right 140 degrees", while the voice said nothing about any turn for the whole
            // route - findings F-1 and F-7. The obstacle is spoken first, then the turn follows, and
            // `maxQueuedAge` still throws the turn away if the warning ran long.
            synthesizer.stopSpeaking(at: .immediate)
        case .enqueue:
            // Hold it ourselves rather than handing it to AVSpeechSynthesizer, whose own queue cannot
            // be revised: by the time it would speak, the user has moved and the line may be wrong.
            pending.push(SpeechQueue.Line(text: text, priority: priority, queuedAt: now,
                                          maxAge: staysFresh ? Self.openingMaxQueuedAge : Self.maxQueuedAge))
            return
        case .speak:
            break
        }

        speakNow(text, priority: priority)
    }

    private func speakNow(_ text: String, priority: SpeechPriority) {
        speakingPriority = priority
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice // nil = the system's default voice for the phone's language
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A short pause after each line so two queued cues do not run together as one sentence.
        utterance.postUtteranceDelay = 0.25
        synthesizer.speak(utterance)
        Log.guidance.info("say: \(text)")
    }

    /// Speaks the most important thing still worth saying, discarding anything that waited too long.
    private func speakPendingIfFresh() {
        let result = pending.popFresh(now: now)
        for text in result.dropped { Log.guidance.info("dropped stale line: \(text)") }
        guard let next = result.line else { return }
        speakNow(next.text, priority: next.priority)
    }

    func stop() {
        pending.clear()
        speakingPriority = nil
        synthesizer.stopSpeaking(at: .immediate)
        gate.reset()
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakingPriority = nil
        speakPendingIfFresh()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Deliberately does NOT clear `pending`. The only two things that cancel an utterance are a
        // safety interrupt, which now keeps what is waiting (see `say`), and `stop()`, which clears
        // `pending` itself before cancelling. Clearing it here would undo the interrupt fix.
        // Staleness is still enforced, by `maxQueuedAge` in `speakPendingIfFresh`.
        speakingPriority = nil
    }
}
