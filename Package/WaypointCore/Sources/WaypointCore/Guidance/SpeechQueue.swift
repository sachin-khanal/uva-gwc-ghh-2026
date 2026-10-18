//
// File:     Guidance/SpeechQueue.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  What waits its turn while the app is speaking, and what is thrown away. Separated from
//           `Speaker` for the same reason as `SpeechGate`: AVSpeechSynthesizer cannot be unit-tested
//           and never runs in `make test`, and this logic has now caused three device bugs.
//
// History, because each rule here is a scar:
//   * A SINGLE slot holding the NEWEST line. Cautions became `.high`, the same priority as turns, so
//     an obstacle warning arriving a moment after a turn silently destroyed it: the user saw the
//     arrow point left and heard only "something ahead" (2026-10-18).
//   * Before that, a line was dropped if it had waited 2 s - but a line only ever waits because the
//     speaker is busy, and a warning takes ~2.4 s to say, so it was ALWAYS already stale when its
//     turn came. Hence `maxAge` per line, set by the caller, not a single global rule.
//   * A safety cue KEEPS what is waiting rather than clearing it, which is what lets a turn follow an
//     obstacle warning. Only a terminal line (arrival) clears the queue.
//
// Why a queue and not a backlog: everything still carries its own `maxAge`, so a line that waited too
// long is discarded rather than spoken late. A stale direction contradicts what the user can feel.
//
// Status:   DONE (pure logic, unit-tested).
//
import Foundation

public struct SpeechQueue: Equatable, Sendable {

    public struct Line: Equatable, Sendable {
        public var text: String
        public var priority: SpeechPriority
        public var queuedAt: TimeInterval
        /// How long this line may wait before it is no longer worth saying.
        public var maxAge: TimeInterval

        public init(text: String, priority: SpeechPriority, queuedAt: TimeInterval, maxAge: TimeInterval) {
            self.text = text
            self.priority = priority
            self.queuedAt = queuedAt
            self.maxAge = maxAge
        }
    }

    /// Never hold more than this. Three cues is already more than a walking person can act on, and
    /// beyond it the least important, oldest line is dropped rather than the newest arrival.
    public static let maxDepth = 3

    private var lines: [Line] = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }
    /// The texts in the order they would be spoken. For tests and logging.
    public var texts: [String] { lines.map(\.text) }

    /// Add a line. Most important first; equal priorities keep the order they arrived in, so a turn
    /// offered before a caution is still spoken before it.
    @discardableResult
    public mutating func push(_ line: Line) -> Line? {
        lines.append(line)
        // Stable by construction: `sort` is not guaranteed stable in Swift, so sort on (priority, seq).
        lines = lines.enumerated()
            .sorted { a, b in
                a.element.priority == b.element.priority
                    ? a.offset < b.offset
                    : a.element.priority > b.element.priority
            }
            .map(\.element)
        if lines.count > Self.maxDepth { return lines.removeLast() }
        return nil
    }

    /// The next line still worth saying, discarding any that waited too long.
    /// - Returns: the line to speak, and the texts dropped as stale (so the caller can log them).
    public mutating func popFresh(now: TimeInterval) -> (line: Line?, dropped: [String]) {
        var dropped: [String] = []
        while !lines.isEmpty {
            let next = lines.removeFirst()
            if now - next.queuedAt <= next.maxAge { return (next, dropped) }
            dropped.append(next.text)
        }
        return (nil, dropped)
    }

    /// Nothing waiting is still true (arrival, or guidance stopped).
    public mutating func clear() { lines.removeAll() }
}

/// Decides whether a lost line is worth saying again NOW. Found on the phone (simulated walk, Floor 4 map, 2026-10-18): with the voice busy,
/// "Continue straight." and "In 5 meters, turn right." displaced each other, each loss re-armed the cue, and the pair ping-ponged every tick
/// (58 lost lines in one 12 s walk) while the turn itself was never said. A line may come back at most once per `minimumGap`. (Even
/// "Continue straight." may come back: losing it after a turn was a reported bug, 2026-10-17.)
public struct LossThrottle: Sendable {
    public static let minimumGap: TimeInterval = 3

    private var lastRearmed: [String: TimeInterval] = [:]

    public init() {}

    public mutating func shouldRearm(_ text: String, now: TimeInterval) -> Bool {
        if let last = lastRearmed[text], now - last < Self.minimumGap { return false }
        lastRearmed[text] = now
        if lastRearmed.count > 24 { lastRearmed = [text: now] }
        return true
    }

    public mutating func reset() { lastRearmed = [:] }
}
