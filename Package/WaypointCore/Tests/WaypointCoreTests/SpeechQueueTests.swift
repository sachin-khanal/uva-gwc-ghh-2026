//
// File:     SpeechQueueTests.swift
// Module:   WaypointCoreTests
// Purpose:  What waits its turn while the app is talking. This logic has caused three separate device
//           bugs - a turn destroyed by an obstacle warning, a line dropped because waiting itself made
//           it stale, and a direction spoken after arrival - so every rule here has a test.
//
import XCTest
@testable import WaypointCore

final class SpeechQueueTests: XCTestCase {

    private func line(_ text: String, _ priority: SpeechPriority, at: TimeInterval = 0,
                      maxAge: TimeInterval = 4.5) -> SpeechQueue.Line {
        SpeechQueue.Line(text: text, priority: priority, queuedAt: at, maxAge: maxAge)
    }

    /// THE BUG THIS EXISTS FOR. A caution arriving after a turn used to displace it, because a single
    /// slot kept the newer line and cautions share `.high` with turns. Both must be said.
    func testACautionDoesNotDestroyAQueuedTurn() {
        var q = SpeechQueue()
        q.push(line("Right, toward Room 542.", .high, at: 0))
        q.push(line("Careful. A wall ahead.", .high, at: 0.2))
        XCTAssertEqual(q.texts, ["Right, toward Room 542.", "Careful. A wall ahead."],
                       "equal priority keeps arrival order")
        XCTAssertEqual(q.popFresh(now: 0.5).line?.text, "Right, toward Room 542.")
        XCTAssertEqual(q.popFresh(now: 0.5).line?.text, "Careful. A wall ahead.")
    }

    /// A safety line jumps the queue, whatever arrived before it.
    func testSafetyIsSpokenFirst() {
        var q = SpeechQueue()
        q.push(line("Continue straight.", .high, at: 0))
        q.push(line("Landmark.", .normal, at: 0))
        q.push(line("Stop. A wall ahead.", .critical, at: 0.1))
        XCTAssertEqual(q.popFresh(now: 0.2).line?.text, "Stop. A wall ahead.")
        XCTAssertEqual(q.popFresh(now: 0.2).line?.text, "Continue straight.")
        XCTAssertEqual(q.popFresh(now: 0.2).line?.text, "Landmark.")
    }

    /// A line that waited longer than its own budget is discarded, not spoken late - a stale direction
    /// contradicts what the user can feel.
    func testAStaleLineIsDroppedAndReported() {
        var q = SpeechQueue()
        q.push(line("In 3 meters, turn right.", .high, at: 0, maxAge: 4.5))
        let result = q.popFresh(now: 10)
        XCTAssertNil(result.line)
        XCTAssertEqual(result.dropped, ["In 3 meters, turn right."])
    }

    /// ...and a stale line does not block a fresh one behind it.
    func testAStaleLineDoesNotBlockAFreshOne() {
        var q = SpeechQueue()
        q.push(line("Old turn.", .high, at: 0, maxAge: 1))
        q.push(line("New turn.", .high, at: 9))
        let result = q.popFresh(now: 10)
        XCTAssertEqual(result.line?.text, "New turn.")
        XCTAssertEqual(result.dropped, ["Old turn."])
    }

    /// The opening briefing carries a long budget of its own and must survive a normal wait.
    func testALineWithItsOwnLongBudgetSurvives() {
        var q = SpeechQueue()
        q.push(line("You are near Room 206...", .high, at: 0, maxAge: 15))
        XCTAssertEqual(q.popFresh(now: 9).line?.text, "You are near Room 206...")
    }

    /// Three cues is already more than a walking person can act on. Beyond that the least important,
    /// oldest line goes - never the newest arrival, which is the one describing the world now.
    func testTheQueueIsBounded() {
        var q = SpeechQueue()
        q.push(line("Landmark.", .normal, at: 0))
        q.push(line("Turn one.", .high, at: 1))
        q.push(line("Turn two.", .high, at: 2))
        q.push(line("Stop. A wall ahead.", .critical, at: 3))
        XCTAssertEqual(q.count, SpeechQueue.maxDepth)
        XCTAssertEqual(q.texts, ["Stop. A wall ahead.", "Turn one.", "Turn two."],
                       "the ambient landmark is what goes")
    }

    /// Arrival ends the walk: nothing queued before it is still true.
    func testClearEmptiesEverything() {
        var q = SpeechQueue()
        q.push(line("Left 45 degrees.", .high, at: 0))
        q.clear()
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.popFresh(now: 0.1).line)
    }

    func testAnEmptyQueueReturnsNothing() {
        var q = SpeechQueue()
        let result = q.popFresh(now: 1)
        XCTAssertNil(result.line)
        XCTAssertTrue(result.dropped.isEmpty)
    }
}
