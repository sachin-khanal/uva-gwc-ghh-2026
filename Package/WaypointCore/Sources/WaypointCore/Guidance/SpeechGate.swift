//
// File:     Guidance/SpeechGate.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  The RULES for what gets spoken, separated from the thing that does the speaking so they
//           can be unit-tested (AVSpeechSynthesizer cannot be, and never runs in `make test`).
//
// Why:      Two independent AVSpeechSynthesizers existed - `SpeechGuide` (guidance) and `Announcer`
//           (the new UI) - and neither could see the other, so at arrival the user heard both at once
//           in two voices (reported on device 2026-10-17). The fix is one speaker; this is its brain.
//
// Rules:    * identical text within `repeatWindow` is dropped (stops a stuck state from nagging)
//           * `.high` interrupts whatever is being said (obstacle, lost position, arrival)
//           * `.normal` is dropped while something is still being said, rather than queued, because a
//             stale direction spoken five seconds late is worse than silence
//
// Status:   DONE (pure logic, unit-tested).
//
import Foundation

public struct SpeechGate {

    public enum Decision: Equatable {
        /// Say it, interrupting anything in progress first.
        case interrupt
        /// Say it; nothing is in progress.
        case speak
        /// Stay quiet (duplicate, or lower priority than what is already being said).
        case drop
    }

    /// Identical text inside this window is dropped.
    public var repeatWindow: TimeInterval

    private var lastText: String?
    private var lastTime: TimeInterval = -.greatestFiniteMagnitude

    public init(repeatWindow: TimeInterval = 3) {
        self.repeatWindow = repeatWindow
    }

    /// - Parameters:
    ///   - isSpeaking: is the speaker mid-utterance right now?
    ///   - now: monotonic seconds; the caller supplies it so tests are deterministic.
    public mutating func decide(text: String, priority: SpeechPriority,
                                isSpeaking: Bool, now: TimeInterval) -> Decision {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .drop }
        if text == lastText, now - lastTime < repeatWindow { return .drop }

        switch priority {
        case .high:
            lastText = text
            lastTime = now
            return isSpeaking ? .interrupt : .speak
        case .normal:
            if isSpeaking { return .drop }
            lastText = text
            lastTime = now
            return .speak
        }
    }

    /// Forget what was last said (new navigation, or the user stopped guidance).
    public mutating func reset() {
        lastText = nil
        lastTime = -.greatestFiniteMagnitude
    }
}
