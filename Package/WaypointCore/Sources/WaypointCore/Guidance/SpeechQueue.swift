//
// File:     Guidance/SpeechQueue.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  The ONE waiting slot behind the app's voice, as a pure value type so its rules can be unit-tested
//           (AVSpeechSynthesizer and VoiceOver announcements cannot run in `make test`).
// Why:      `Speaker` used to hold this slot inline and silently THROW AWAY lines: a newer line replaced an older
//           one, a long opening briefing blocked a turn, a stale line expired. The planner had already recorded
//           each of those as announced, so a dropped turn was never said again (device findings F-1, F-5, F-7,
//           2026-10-18). This type never loses a line quietly: every method that discards one RETURNS it, so the
//           caller can tell the planner (`FeedbackPlanner.lineLost`) to say it again if it still applies.
// Rules:    * at most ONE line waits;
//           * a waiting line is only displaced by one of equal or higher priority (an incidental landmark can never
//             displace a turn), and a waiting OPENING briefing (`staysFresh`) only by another `staysFresh` line;
//           * a line older than its `maxAge` when its turn comes is lost, not spoken (a direction spoken late to
//             somebody who kept walking is worse than silence).
// Status:   DONE (logic, unit tested in GuidanceOverhaulTests).
//
import Foundation

public struct SpeechLine: Equatable, Sendable {
    public var text: String
    public var priority: SpeechPriority
    public var queuedAt: TimeInterval
    public var maxAge: TimeInterval

    public init(text: String, priority: SpeechPriority, queuedAt: TimeInterval, maxAge: TimeInterval) {
        self.text = text
        self.priority = priority
        self.queuedAt = queuedAt
        self.maxAge = maxAge
    }
}

public struct SpeechQueue: Sendable {

    /// Longer than ONE spoken line: a line only ever waits because the speaker is busy, and a stop warning takes ~2.4 s to say.
    public static let maxAge: TimeInterval = 4.5
    /// The opening briefing is spoken once, before the user walks, so its age does not make it wrong.
    public static let openingMaxAge: TimeInterval = 15

    public private(set) var pending: SpeechLine?

    public init() {}

    /// Offers a line to wait for its turn.
    /// - Returns: the line that was LOST because of this call (the offered one if it was rejected, or the one it displaced), else nil.
    @discardableResult
    public mutating func hold(text: String, priority: SpeechPriority, now: TimeInterval, staysFresh: Bool = false) -> SpeechLine? {
        let offered = SpeechLine(text: text, priority: priority, queuedAt: now,
                                 maxAge: staysFresh ? Self.openingMaxAge : Self.maxAge)
        if let current = pending {
            // Keep what is waiting when it matters more, or when it is the opening briefing and this is not.
            if !staysFresh, current.priority > priority || current.maxAge > Self.maxAge { return offered }
            pending = offered
            return current
        }
        pending = offered
        return nil
    }

    /// The speaker is free: what to say next. `lost` is a waiting line that expired.
    public mutating func next(now: TimeInterval) -> (speak: SpeechLine?, lost: SpeechLine?) {
        guard let line = pending else { return (nil, nil) }
        pending = nil
        if now - line.queuedAt <= line.maxAge { return (line, nil) }
        return (nil, line)
    }

    /// Deliberate stop (navigation ended): forget what waits. Not a loss, so nothing is returned.
    public mutating func clear() { pending = nil }
}
