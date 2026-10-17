//
// File:     Tests/WaypointCoreTests/FeedbackAndVisionTests.swift
// Purpose:  Proves the feedback priority rules (lost tracking / obstacle beat navigation, no
//           repeated announcements), obstacle hysteresis, and room-number parsing + consensus.
//
import XCTest
import simd
@testable import WaypointCore

final class FeedbackAndVisionTests: XCTestCase {

    private func instruction(_ kind: GuidanceInstruction.Kind, hazard: Hazard? = nil,
                             target: UUID = UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000A1")!,
                             label: String? = nil) -> GuidanceInstruction {
        GuidanceInstruction(kind: kind, bearingRadians: 0, distanceMeters: 3, targetNodeId: target,
                            targetLabel: label, targetPosition: [0, 0, -3], hazard: hazard)
    }

    // MARK: FeedbackPlanner

    func testTurnAnnouncedOnceThenOnlyBeacon() {
        var p = FeedbackPlanner()
        let first = p.plan(instruction: instruction(.turnLeft), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(first.contains(.haptic(.turnLeft)))
        // The angle itself is TurnSpeech's job (TurnSpeechTests); here we only care that the turn
        // was announced once.
        XCTAssertTrue(first.contains { if case .speak(let t, _) = $0 { return t.hasPrefix("Turn left") } else { return false } })
        XCTAssertTrue(first.contains(.beacon([0, 0, -3])))
        let second = p.plan(instruction: instruction(.turnLeft), obstacle: .clear, trackingOK: true)
        XCTAssertEqual(second, [.beacon([0, 0, -3])]) // no repeated speech or haptic
    }

    func testObstacleStopOverridesNavigationAndMutesBeacon() {
        var p = FeedbackPlanner()
        let a = p.plan(instruction: instruction(.continueStraight), obstacle: .stop, trackingOK: true)
        XCTAssertEqual(a.first, .speak("Stop. Obstacle ahead.", priority: .high))
        XCTAssertTrue(a.contains(.haptic(.obstacleStop)))
        XCTAssertEqual(a.last, .beacon(nil))
        XCTAssertFalse(a.contains(.speak("Continue straight.", priority: .normal)))
    }

    func testLostTrackingSilencesAndRecovers() {
        var p = FeedbackPlanner()
        let lost = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: false)
        XCTAssertEqual(lost, [.speak("Lost my position. Hold still.", priority: .high), .beacon(nil)])
        let still = p.plan(instruction: nil, obstacle: .clear, trackingOK: false)
        XCTAssertEqual(still, [.beacon(nil)]) // does not nag
        let back = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(back.contains(.speak("Position found.", priority: .normal)))
        XCTAssertTrue(back.contains(.speak("Continue straight.", priority: .normal))) // re-announced
    }

    func testArrivalAndHazardText() {
        var p = FeedbackPlanner()
        let arrived = p.plan(instruction: instruction(.arrived, label: "Room 204"), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(arrived.contains(.speak("You have arrived at Room 204.", priority: .high)))
        XCTAssertTrue(arrived.contains(.haptic(.arrived)))
        XCTAssertEqual(arrived.last, .beacon(nil))

        var q = FeedbackPlanner()
        let stairs = q.plan(instruction: instruction(.continueStraight, hazard: .stairs), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(stairs.contains(.speak("Stairs ahead.", priority: .high)))
    }

    func testStraightIsNotRepeatedWhenTheTargetWaypointAdvances() {
        var p = FeedbackPlanner()
        var straightSpeech = 0
        for _ in 0..<20 { // 20 consecutive breadcrumbs, all "straight ahead", each a NEW target node
            let actions = p.plan(instruction: instruction(.continueStraight, target: UUID()), obstacle: .clear, trackingOK: true)
            straightSpeech += actions.filter { $0 == .speak("Continue straight.", priority: .normal) }.count
        }
        XCTAssertEqual(straightSpeech, 1, "found by the on-phone E2E test: it used to be spoken at every waypoint")
    }

    func testTurnsAreAnnouncedAgainAfterAStraightStretch() {
        var p = FeedbackPlanner()
        var turns = 0
        for kind in [GuidanceInstruction.Kind.turnRight, .continueStraight, .continueStraight, .turnRight, .turnRight, .continueStraight, .turnLeft] {
            let actions = p.plan(instruction: instruction(kind, target: UUID()), obstacle: .clear, trackingOK: true)
            turns += actions.filter { if case .speak(let t, _) = $0 { return t.hasPrefix("Turn") }; return false }.count
        }
        XCTAssertEqual(turns, 3, "right, right (after straight), left - the repeated right at the next waypoint is not repeated")
    }

    func testHazardAnnouncedOncePerHazardousTarget() {
        var p = FeedbackPlanner()
        let stairs = UUID()
        var count = 0
        for target in [UUID(), stairs, stairs, stairs, UUID(), stairs] {
            let hazard: Hazard? = (target == stairs) ? .stairs : nil
            let actions = p.plan(instruction: instruction(.continueStraight, hazard: hazard, target: target), obstacle: .clear, trackingOK: true)
            count += actions.filter { $0 == .speak("Stairs ahead.", priority: .high) }.count
        }
        XCTAssertEqual(count, 2, "once when first approaching the stairs, once more after the hazard cleared and returned")
    }

    // MARK: ObstacleClassifier

    func testObstacleLevelsAndHysteresis() {
        var c = ObstacleClassifier() // stop <0.6, caution <1.2, hysteresis 0.15
        XCTAssertEqual(c.update(nearest: nil), .clear)
        XCTAssertEqual(c.update(nearest: 2.0), .clear)
        XCTAssertEqual(c.update(nearest: 1.1), .caution)
        XCTAssertEqual(c.update(nearest: 1.25), .caution) // inside hysteresis band: stays
        XCTAssertEqual(c.update(nearest: 1.4), .clear)    // 1.2 + 0.15 = 1.35 exceeded
        XCTAssertEqual(c.update(nearest: 0.5), .stop)
        XCTAssertEqual(c.update(nearest: 0.65), .stop)    // < 0.75: stays
        XCTAssertEqual(c.update(nearest: 0.8), .caution)  // left stop, still within caution range
    }

    // MARK: RoomNumberParser / ConsensusFilter

    func testRoomNumberExtraction() {
        XCTAssertEqual(RoomNumberParser.extract(from: ["ROOM 204", "Exit", "112b"]), ["204", "112B"])
        XCTAssertEqual(RoomNumberParser.extract(from: ["204 204"]), ["204"])           // de-duplicated
        XCTAssertTrue(RoomNumberParser.extract(from: ["12", "12345", "abc"]).isEmpty)  // wrong digit counts
    }

    func testConsensusConfirmsAfterThreeReadsOnce() {
        var f = ConsensusFilter(requiredReads: 3)
        XCTAssertTrue(f.ingest(["204"]).isEmpty)
        XCTAssertTrue(f.ingest(["204", "206"]).isEmpty)
        XCTAssertEqual(f.ingest(["204"]), ["204"])
        XCTAssertTrue(f.ingest(["204"]).isEmpty) // already confirmed: not reported again
        f.reset()
        XCTAssertTrue(f.ingest(["204"]).isEmpty)
    }
}

// MARK: - SpeechGate: the rules behind the app's single voice (D-026)

final class SpeechGateTests: XCTestCase {

    func testHighPriorityInterruptsWhatIsBeingSaid() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Stop. Wall ahead.", priority: .high, isSpeaking: true, now: 1), .interrupt)
    }

    func testHighPrioritySpeaksWhenNothingIsBeingSaid() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "You have arrived.", priority: .high, isSpeaking: false, now: 1), .speak)
    }

    /// A stale direction spoken late is worse than silence, so normal lines are dropped, not queued.
    func testNormalPriorityIsDroppedWhileSomethingIsStillBeingSaid() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Continue straight.", priority: .normal, isSpeaking: true, now: 1), .drop)
        XCTAssertEqual(gate.decide(text: "Continue straight.", priority: .normal, isSpeaking: false, now: 2), .speak)
    }

    func testIdenticalTextIsDroppedInsideTheRepeatWindow() {
        var gate = SpeechGate(repeatWindow: 3)
        XCTAssertEqual(gate.decide(text: "Turn left.", priority: .high, isSpeaking: false, now: 10), .speak)
        XCTAssertEqual(gate.decide(text: "Turn left.", priority: .high, isSpeaking: false, now: 12), .drop)
        XCTAssertEqual(gate.decide(text: "Turn left.", priority: .high, isSpeaking: false, now: 13.5), .speak)
    }

    /// Different text must never be suppressed by the repeat window - that would hide a real warning.
    func testDifferentTextIsNotSuppressed() {
        var gate = SpeechGate(repeatWindow: 3)
        XCTAssertEqual(gate.decide(text: "Turn left.", priority: .high, isSpeaking: false, now: 10), .speak)
        XCTAssertEqual(gate.decide(text: "Stop. Stairs directly ahead.", priority: .high, isSpeaking: true, now: 10.1), .interrupt)
    }

    func testEmptyTextIsNeverSpoken() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "", priority: .high, isSpeaking: false, now: 1), .drop)
        XCTAssertEqual(gate.decide(text: "   \n", priority: .high, isSpeaking: false, now: 1), .drop)
    }

    func testResetForgetsTheLastLine() {
        var gate = SpeechGate(repeatWindow: 3)
        XCTAssertEqual(gate.decide(text: "Position found.", priority: .normal, isSpeaking: false, now: 1), .speak)
        XCTAssertEqual(gate.decide(text: "Position found.", priority: .normal, isSpeaking: false, now: 2), .drop)
        gate.reset()
        XCTAssertEqual(gate.decide(text: "Position found.", priority: .normal, isSpeaking: false, now: 2), .speak,
                       "a new navigation session may say it again")
    }

    /// A dropped line must not reserve the repeat window, or the next attempt is wrongly silenced.
    func testADroppedLineDoesNotBlockTheNextAttempt() {
        var gate = SpeechGate(repeatWindow: 3)
        XCTAssertEqual(gate.decide(text: "Continue straight.", priority: .normal, isSpeaking: true, now: 1), .drop)
        XCTAssertEqual(gate.decide(text: "Continue straight.", priority: .normal, isSpeaking: false, now: 1.1), .speak)
    }
}
