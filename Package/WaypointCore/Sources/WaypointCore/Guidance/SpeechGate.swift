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
        /// Say it, interrupting anything in progress first. Safety only.
        case interrupt
        /// Add it to the queue; it is spoken when the current line finishes.
        case enqueue
        /// Say it; nothing is in progress.
        case speak
        /// Stay quiet (duplicate, or ambient while something else is being said).
        case drop
    }

    /// Identical text inside this window is dropped.
    public var repeatWindow: TimeInterval

    /// When each recent line was last spoken. A SINGLE `lastText` only caught duplicates that were
    /// immediately consecutive: any other line in between reset it, so "In 3 meters, turn right" could
    /// be said, interrupted by an obstacle warning, and said again moments later - which is exactly
    /// what the Rice Hall transcript shows at 1:11 (2026-10-18). Pruned to `repeatWindow`, so it stays
    /// small however long the walk.
    private var spokenAt: [String: TimeInterval] = [:]

    public init(repeatWindow: TimeInterval = 3) {
        self.repeatWindow = repeatWindow
    }

    /// - Parameters:
    ///   - isSpeaking: is the speaker mid-utterance right now?
    ///   - now: monotonic seconds; the caller supplies it so tests are deterministic.
    /// - Parameter speakingPriority: the priority of the line currently being spoken, if any. Lets a
    ///   safety cue avoid cutting off ANOTHER safety cue (see `.critical` below).
    public mutating func decide(text: String, priority: SpeechPriority,
                                isSpeaking: Bool, now: TimeInterval,
                                speakingPriority: SpeechPriority? = nil) -> Decision {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .drop }
        spokenAt = spokenAt.filter { now - $0.value < repeatWindow }
        if let last = spokenAt[text], now - last < repeatWindow { return .drop }

        switch priority {
        case .critical:
            spokenAt[text] = now
            guard isSpeaking else { return .speak }
            // Safety interrupts GUIDANCE, never another safety line. Two warnings about the same
            // hazard arriving a moment apart used to cut each other off, so the user heard "Stop.
            // Stop. Stop. Stop." and only the last one ever reached the part that says what the
            // hazard is (device report 2026-10-18). A half-spoken warning helps nobody; the one in
            // progress finishes and this one follows.
            return speakingPriority == .critical ? .enqueue : .interrupt
        case .high:
            // Queue rather than interrupt: a walking user generates several of these in a row and
            // cutting each off with the next produced half sentences.
            spokenAt[text] = now
            return isSpeaking ? .enqueue : .speak
        case .normal:
            if isSpeaking { return .drop }
            spokenAt[text] = now
            return .speak
        }
    }

    /// Forget what was last said (new navigation, or the user stopped guidance).
    public mutating func reset() { spokenAt.removeAll() }
}
