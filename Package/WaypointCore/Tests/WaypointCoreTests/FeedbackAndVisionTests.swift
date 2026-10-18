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
        XCTAssertTrue(first.contains { if case .speak(let t, _) = $0 { return t.lowercased().contains("left") } else { return false } })
        XCTAssertTrue(first.contains(.beacon([0, 0, -3])))
        let second = p.plan(instruction: instruction(.turnLeft), obstacle: .clear, trackingOK: true)
        XCTAssertEqual(second, [.beacon([0, 0, -3])]) // no repeated speech or haptic
    }

    func testObstacleStopOverridesNavigationAndMutesBeacon() {
        var p = FeedbackPlanner()
        let a = p.plan(instruction: instruction(.continueStraight), obstacle: .stop, trackingOK: true)
        XCTAssertEqual(a.first, .speak("Stop. Obstacle ahead.", priority: .critical))
        XCTAssertTrue(a.contains(.haptic(.obstacleStop)))
        XCTAssertEqual(a.last, .beacon(nil))
        XCTAssertFalse(a.contains(.speak("Continue straight.", priority: .normal)))
    }

    /// Before a position has ever been found there is nothing to have lost: the first untracked tick
    /// says it is still looking, and queues rather than interrupting (2026-10-18 recorded walk).
    func testFirstFixIsNotReportedAsALoss() {
        var p = FeedbackPlanner()
        let looking = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: false)
        XCTAssertEqual(looking, [.speak("Finding your position. Stand still, then turn slowly.", priority: .high),
                                 .beacon(nil)])
    }

    /// ...but once we HAVE had a position, losing it is a real safety event and interrupts.
    func testLosingAPositionWeHadIsCritical() {
        var p = FeedbackPlanner()
        _ = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: true)
        let lost = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: false)
        XCTAssertEqual(lost, [.speak("Lost my position. Hold still.", priority: .critical), .beacon(nil)])
    }

    func testLostTrackingSilencesAndRecovers() {
        var p = FeedbackPlanner()
        _ = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: true) // had a fix first
        let lost = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: false)
        XCTAssertEqual(lost, [.speak("Lost my position. Hold still.", priority: .critical), .beacon(nil)])
        let still = p.plan(instruction: nil, obstacle: .clear, trackingOK: false)
        XCTAssertEqual(still, [.beacon(nil)]) // does not nag
        let back = p.plan(instruction: instruction(.continueStraight), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(back.contains(.speak("Position found.", priority: .normal)))
        // `.high` since 2026-10-17: `.normal` was dropped whenever the speaker was busy, which lost
        // the resume cue after every turn.
        XCTAssertTrue(back.contains(.speak("Continue straight.", priority: .high))) // re-announced
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
            straightSpeech += actions.filter { $0 == .speak("Continue straight.", priority: .high) }.count
        }
        XCTAssertEqual(straightSpeech, 1, "found by the on-phone E2E test: it used to be spoken at every waypoint")
    }

    func testTurnsAreAnnouncedAgainAfterAStraightStretch() {
        var p = FeedbackPlanner()
        var turns = 0
        for kind in [GuidanceInstruction.Kind.turnRight, .continueStraight, .continueStraight, .turnRight, .turnRight, .continueStraight, .turnLeft] {
            let actions = p.plan(instruction: instruction(kind, target: UUID()), obstacle: .clear, trackingOK: true)
            // Turn wording is "Right.", "Slightly left 20 degrees." or "Turn around." now, so count
            // anything that names a side.
            turns += actions.filter {
                if case .speak(let t, _) = $0 {
                    return t != "Continue straight." && (t.lowercased().contains("left") || t.lowercased().contains("right") || t.hasPrefix("Turn around"))
                }
                return false
            }.count
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

    /// Only safety cuts somebody off mid-word.
    func testCriticalInterruptsWhatIsBeingSaid() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Stop. Wall ahead.", priority: .critical, isSpeaking: true, now: 1), .interrupt)
    }

    /// Turns and arrival QUEUE instead. Interrupting each with the next is what chopped guidance into
    /// fragments while walking (device report 2026-10-17).
    func testHighPriorityQueuesBehindWhatIsBeingSaid() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Turn right 45 degrees.", priority: .high, isSpeaking: true, now: 1), .enqueue)
        XCTAssertEqual(gate.decide(text: "You have arrived.", priority: .high, isSpeaking: false, now: 2), .speak)
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
        XCTAssertEqual(gate.decide(text: "Stop. Stairs directly ahead.", priority: .critical, isSpeaking: true, now: 10.1), .interrupt)
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

// MARK: - Not talking over yourself, and not nagging at a closed door (device report, 2026-10-17)

final class SpeechPacingTests: XCTestCase {

    private func spoken(_ actions: [FeedbackAction]) -> [String] {
        actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
    }

    private func instruction(targetKind: NodeKind, label: String?, distance: Float) -> GuidanceInstruction {
        GuidanceInstruction(kind: .continueStraight, bearingRadians: 0, distanceMeters: distance,
                            targetNodeId: UUID(), targetLabel: label,
                            targetPosition: SIMD3(0, 0, -distance), hazard: nil, targetKind: targetKind)
    }

    private func door(_ metres: Float) -> ObstacleReport {
        ObstacleReport(kind: .door, side: .ahead, distanceMeters: metres, confidence: 0.9)
    }

    /// The report: standing at a closed door, it repeated "stop, a door ahead" every few seconds
    /// instead of leaving the one useful line - that the door has to be opened - to stand.
    func testADoorIsExplainedOnceAndNotRepeated() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .room, label: "Room 442", distance: 1.4)

        let first = spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                        report: door(0.5), time: 1, isMoving: true))
        XCTAssertEqual(first.filter { $0.contains("open it") }.count, 1, "said once: \(first)")
        XCTAssertFalse(first.contains { $0.hasPrefix("Stop.") },
                       "the door you were routed to is not an obstacle: \(first)")
        // Guidance deliberately carries on toward the door, so another cue here is fine.

        // Several seconds standing in front of it: the stop-repeat timer must not fire.
        for t in stride(from: 4.0, through: 20.0, by: 4.0) {
            let later = spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                            report: door(0.5), time: t, isMoving: false))
            XCTAssertTrue(later.isEmpty, "nothing more to say at t=\(t): \(later)")
        }
    }

    /// Standing still in front of a real obstacle is not a reason to keep warning either - the user
    /// has already stopped, which is what the warning was for.
    func testStopIsNotRepeatedAtSomeoneWhoHasStopped() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .corridor, label: nil, distance: 6)
        let wall = ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.5, confidence: 0.9)

        XCTAssertEqual(spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                           report: wall, time: 1, isMoving: true)).count, 1)
        XCTAssertTrue(spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                          report: wall, time: 10, isMoving: false)).isEmpty,
                      "they have stopped; repeating adds nothing")
    }

    /// ...but if they are still walking toward it, keep warning. This is the safety case.
    func testStopIsStillRepeatedWhileWalkingIntoSomething() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .corridor, label: nil, distance: 6)
        let wall = ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.5, confidence: 0.9)

        _ = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, report: wall, time: 1, isMoving: true)
        let again = spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                        report: wall, time: 10, isMoving: true))
        XCTAssertEqual(again.count, 1, "still moving toward a wall: say it again")
    }

    /// Unknown movement (no data yet) must behave as it always did, not go quiet.
    func testUnknownMovementKeepsTheOldRepeatingBehaviour() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .corridor, label: nil, distance: 6)
        let wall = ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.5, confidence: 0.9)
        _ = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, report: wall, time: 1)
        XCTAssertFalse(spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                           report: wall, time: 10)).isEmpty)
    }

    /// Walking through the door arms the explanation again for the next one.
    func testTheNextDoorIsExplainedAgain() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .room, label: "Room 442", distance: 1.4)
        XCTAssertFalse(spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                           report: door(0.5), time: 1, isMoving: true)).isEmpty)
        _ = planner.plan(instruction: i, obstacle: .clear, trackingOK: true, time: 5, isMoving: true)
        let next = spoken(planner.plan(instruction: i, obstacle: .stop, trackingOK: true,
                                       report: door(0.5), time: 9, isMoving: true))
        XCTAssertTrue(next.contains { $0.contains("open it") }, "a second door is explained too: \(next)")
    }

    /// Safety interrupts; guidance queues. This is the split that stopped lines being chopped up.
    func testSafetyInterruptsButGuidanceQueues() {
        var planner = FeedbackPlanner()
        let i = instruction(targetKind: .corridor, label: nil, distance: 6)
        let wall = ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.5, confidence: 0.9)
        let actions = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, report: wall,
                                   time: 1, isMoving: true)
        for action in actions {
            if case .speak(let text, let priority) = action, text.hasPrefix("Stop.") {
                XCTAssertEqual(priority, .critical)
            }
        }
    }
}

// MARK: - Suggesting a way round, with the reason (team request, 2026-10-17)

final class AvoidanceAdvisorTests: XCTestCase {

    private typealias Clearance = AvoidanceAdvisor.Clearance

    func testSaysNothingWhileTheWayAheadIsOpen() {
        var advisor = AvoidanceAdvisor()
        XCTAssertNil(advisor.advise(Clearance(ahead: 5, left: 0.3, right: 4)),
                     "a wall beside you is not a reason to turn")
        XCTAssertNil(advisor.advise(Clearance(ahead: nil, left: 0.3, right: 4)))
    }

    func testSuggestsTheClearlyBetterSideWhenBlocked() {
        var advisor = AvoidanceAdvisor()
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.8, left: 3, right: 0.9)), .left)
    }

    /// A coin flip between two bad options helps nobody.
    func testSaysNothingWhenNeitherSideIsClearlyBetter() {
        var advisor = AvoidanceAdvisor()
        XCTAssertNil(advisor.advise(Clearance(ahead: 0.8, left: 2.0, right: 1.9)))
    }

    /// Never send someone toward a second wall.
    func testSaysNothingWhenTheBetterSideIsStillTooTight() {
        var advisor = AvoidanceAdvisor()
        XCTAssertNil(advisor.advise(Clearance(ahead: 0.8, left: 1.0, right: 0.2)),
                     "1 m of room is not a way through")
    }

    /// Nothing detected to one side means open space, not an error.
    func testNothingDetectedToOneSideCountsAsOpen() {
        var advisor = AvoidanceAdvisor()
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.8, left: nil, right: 0.5)), .left)
    }

    /// The cue must not flutter left/right while the user is walking toward the obstacle.
    func testTheSuggestionIsHeldWhileStillBlocked() {
        var advisor = AvoidanceAdvisor()
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.9, left: 3, right: 0.8)), .left)
        // Readings wobble and now favour the right; the advice must not swap under the user.
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.9, left: 0.8, right: 3)), .left)
    }

    func testClearingTheWayForgetsTheSuggestion() {
        var advisor = AvoidanceAdvisor()
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.9, left: 3, right: 0.8)), .left)
        XCTAssertNil(advisor.advise(Clearance(ahead: 6, left: 3, right: 0.8)), "way is open")
        XCTAssertEqual(advisor.advise(Clearance(ahead: 0.9, left: 0.8, right: 3)), .right,
                       "a fresh obstacle gets a fresh answer")
    }

    // MARK: Wording

    func testTheCueSaysWhichWayAndWhy() {
        XCTAssertEqual(TurnSpeech.avoidance(side: .left, obstacle: .wall),
                       "Slightly left, there is a wall ahead.")
        XCTAssertEqual(TurnSpeech.avoidance(side: .right, obstacle: .chair),
                       "Slightly right, there is a chair ahead.")
        XCTAssertEqual(TurnSpeech.avoidance(side: .left, obstacle: nil), "Slightly left.")
        XCTAssertNil(TurnSpeech.avoidance(side: .ahead, obstacle: .wall), "ahead is not a side")
    }
}

// MARK: - The planner speaks the way round (2026-10-17)

final class AvoidanceCueTests: XCTestCase {

    private func spoken(_ actions: [FeedbackAction]) -> [String] {
        actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
    }

    private func walking(targetKind: NodeKind = .corridor, label: String? = nil) -> GuidanceInstruction {
        GuidanceInstruction(kind: .continueStraight, bearingRadians: 0, distanceMeters: 6,
                            targetNodeId: UUID(), targetLabel: label, targetPosition: SIMD3(0, 0, -6),
                            hazard: nil, targetKind: targetKind, destinationLabel: label)
    }

    private let wall = ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.8, confidence: 0.9)

    func testItSaysWhichWayAndWhy() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true,
                                       report: wall, time: 1, isMoving: true, avoidTowards: .left))
        XCTAssertTrue(said.contains("Slightly left, there is a wall ahead."), "\(said)")
    }

    /// The suggestion never replaces the warning: a blocked path is still a stop.
    func testTheStopWarningIsStillGiven() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                       report: wall, time: 1, isMoving: true, avoidTowards: .right))
        XCTAssertTrue(said.contains { $0.hasPrefix("Stop.") }, "\(said)")
        XCTAssertTrue(said.contains { $0.hasPrefix("Slightly right") }, "\(said)")
    }

    func testTheWayRoundIsSaidOncePerObstacle() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true, report: wall,
                         time: 1, isMoving: true, avoidTowards: .left)
        let again = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                        report: wall, time: 4, isMoving: true, avoidTowards: .left))
        XCTAssertFalse(again.contains { $0.hasPrefix("Slightly left") }, "said once, not nagged: \(again)")
    }

    /// Past it and on to the next thing: the suggestion is armed again.
    func testTheNextObstacleIsExplainedAgain() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true, report: wall,
                         time: 1, isMoving: true, avoidTowards: .left)
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true, time: 5, isMoving: true)
        let next = spoken(planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true,
                                       report: wall, time: 9, isMoving: true, avoidTowards: .right))
        XCTAssertTrue(next.contains { $0.hasPrefix("Slightly right") }, "\(next)")
    }

    // MARK: "Stop. Stop. Stop." - repeated safety cues cutting each other off (2026-10-18)

    /// A safety cue does NOT cut off another safety cue: the warning in progress finishes and the new
    /// one follows, instead of the user hearing four half-spoken "Stop."s.
    func testASafetyCueDoesNotInterruptAnotherSafetyCue() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Stop. A wall ahead.", priority: .critical,
                                   isSpeaking: true, now: 1, speakingPriority: .critical),
                       .enqueue)
    }

    /// ...but it still cuts off ordinary guidance, which is what `.critical` is for.
    func testASafetyCueStillInterruptsGuidance() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "Stop. A wall ahead.", priority: .critical,
                                   isSpeaking: true, now: 1, speakingPriority: .high),
                       .interrupt)
    }

    /// Standing still, the classifier changing its mind about what it is looking at is NOT a new
    /// obstacle, so the warning is not re-issued.
    func testAChangedClassificationIsNotNewsWhileStandingStill() {
        var planner = FeedbackPlanner()
        let first = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                        report: wall, time: 1, isMoving: false))
        XCTAssertTrue(first.contains { $0.hasPrefix("Stop.") }, "\(first)")
        let table = ObstacleReport(kind: .table, side: .ahead, distanceMeters: 0.8, confidence: 0.9)
        let flicker = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                          report: table, time: 1.4, isMoving: false))
        XCTAssertTrue(flicker.isEmpty, "same wall, same spot, user has not moved: \(flicker)")
    }

    /// Moving, it IS news - the user really is looking at something else now.
    func testAChangedClassificationIsNewsWhileMoving() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                         report: wall, time: 1, isMoving: true)
        let table = ObstacleReport(kind: .table, side: .ahead, distanceMeters: 0.8, confidence: 0.9)
        let next = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                       report: table, time: 1.4, isMoving: true))
        XCTAssertTrue(next.contains { $0.contains("table") }, "\(next)")
    }

    /// An escalation to STOP is never suppressed, even for somebody standing perfectly still - that is
    /// the case where a person walks into their path.
    func testAnEscalationToStopIsAlwaysAnnouncedEvenWhenStationary() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true,
                         report: wall, time: 1, isMoving: false)
        let person = ObstacleReport(kind: .person, side: .ahead, distanceMeters: 0.6, confidence: 0.9)
        let stop = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                       report: person, time: 1.4, isMoving: false))
        XCTAssertTrue(stop.contains { $0.hasPrefix("Stop.") }, "\(stop)")
    }

    // MARK: Stairs going down - nothing else in the app can see them

    private let downStairs = FloorAhead.Verdict.drop(atMeters: 1.5, byMeters: 0.9)

    /// The floor falling away is announced even though the obstacle sensor says the way is CLEAR -
    /// which is exactly what a descending staircase looks like to everything else here.
    func testAStaircaseGoingDownIsAnnouncedThoughNothingBlocksTheWay() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                       time: 1, isMoving: true, floorAhead: downStairs))
        XCTAssertTrue(said.contains { $0.contains("Stairs going down") }, "\(said)")
    }

    /// ...and the beacon stops pulling the user toward it.
    func testTheBeaconIsMutedAtAFlightOfStairsWeAreNotTaking() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                   time: 1, isMoving: true, floorAhead: downStairs)
        XCTAssertEqual(actions.last, .beacon(nil), "\(actions)")
    }

    /// Said once, not chanted at somebody standing at the top of a staircase.
    func testTheDropIsAnnouncedOncePerEdge() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                         time: 1, isMoving: true, floorAhead: downStairs)
        let again = spoken(planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                        time: 1.5, isMoving: true, floorAhead: downStairs))
        XCTAssertFalse(again.contains { $0.contains("Stairs going down") }, "\(again)")
    }

    /// Walk away, come back: it is news again.
    func testTheDropIsReArmedOnceTheFloorIsGood() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                         time: 1, isMoving: true, floorAhead: downStairs)
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                         time: 2, isMoving: true, floorAhead: .continuous)
        let again = spoken(planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                        time: 3, isMoving: true, floorAhead: downStairs))
        XCTAssertTrue(again.contains { $0.contains("Stairs going down") }, "\(again)")
    }

    /// `unsure` must NOT re-arm: from the top of a staircase the treads return almost nothing, so
    /// `unsure` is frequently the same physical situation as a drop. Re-arming there would make the
    /// warning fire over and over as the sensor flickered between the two.
    func testUnsureDoesNotReArmTheWarning() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                         time: 1, isMoving: true, floorAhead: downStairs)
        _ = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                         time: 2, isMoving: true, floorAhead: .unsure)
        let again = spoken(planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                        time: 3, isMoving: true, floorAhead: downStairs))
        XCTAssertFalse(again.contains { $0.contains("Stairs going down") }, "\(again)")
    }

    /// Stairs we were ROUTED to are the way onward: still announced, but the user is not stopped and
    /// the beacon keeps guiding them.
    func testStairsOnTheRouteStillGuideYouOnward() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(instruction: walking(targetKind: .stairs, label: "Stairwell"),
                                   obstacle: .clear, trackingOK: true,
                                   time: 1, isMoving: true, floorAhead: downStairs)
        XCTAssertTrue(spoken(actions).contains { $0.contains("Stairs going down") }, "\(actions)")
        XCTAssertNotEqual(actions.last, .beacon(nil), "the stairs ARE the route: keep guiding")
    }

    /// A kerb is a caution, and does not stop the walk.
    func testASingleStepDownDoesNotStopTheWalk() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(instruction: walking(), obstacle: .clear, trackingOK: true,
                                   time: 1, isMoving: true,
                                   floorAhead: .drop(atMeters: 1.0, byMeters: 0.18))
        XCTAssertTrue(spoken(actions).contains { $0.hasPrefix("Careful.") }, "\(actions)")
        XCTAssertNotEqual(actions.last, .beacon(nil))
    }

    // MARK: Pacing - Rice Hall walk 2 (2026-10-18)

    /// A cue said, then interrupted by something else, then offered again must NOT be repeated.
    /// Remembering only the LAST line meant anything in between reset the check: the transcript has
    /// "In 3 meters, turn right. In 3 meters, turn right."
    func testADuplicateIsStillDroppedWhenAnotherLineCameInBetween() {
        var gate = SpeechGate()
        XCTAssertEqual(gate.decide(text: "In 3 meters, turn right.", priority: .high, isSpeaking: false, now: 0), .speak)
        XCTAssertEqual(gate.decide(text: "Careful. A wall ahead.", priority: .high, isSpeaking: false, now: 1), .speak)
        XCTAssertEqual(gate.decide(text: "In 3 meters, turn right.", priority: .high, isSpeaking: false, now: 1.5), .drop,
                       "same cue, well inside the repeat window")
    }

    /// ...but once the window has passed it is news again, so a genuinely persisting state can re-warn.
    func testTheSameLineIsAllowedAgainAfterTheWindow() {
        var gate = SpeechGate()
        _ = gate.decide(text: "Stop. A wall ahead.", priority: .critical, isSpeaking: false, now: 0)
        XCTAssertEqual(gate.decide(text: "Stop. A wall ahead.", priority: .critical, isSpeaking: false, now: 3.1), .speak)
    }

    /// The door of the place you are walking to is the way IN, even when the destination is a plain
    /// breadcrumb - which is what "Guide me back to the start" routes to. Before this the user stood in
    /// front of their own destination being told to stop, for twelve seconds.
    func testADoorOnTheFinalApproachIsTheWayIn() {
        XCTAssertTrue(RouteFeature.isWayThrough(obstacle: .door, target: .corridor, onFinalApproach: true))
        var planner = FeedbackPlanner()
        let arriving = GuidanceInstruction(kind: .continueStraight, bearingRadians: 0, distanceMeters: 1.5,
                                           targetNodeId: UUID(), targetLabel: nil, targetPosition: SIMD3(0, 0, -1.5),
                                           hazard: nil, targetKind: .corridor, destinationLabel: nil)
        let door = ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.6, confidence: 0.9)
        let said = spoken(planner.plan(instruction: arriving, obstacle: .stop, trackingOK: true,
                                       report: door, time: 1, isMoving: true))
        XCTAssertFalse(said.contains { $0.hasPrefix("Stop.") }, "it is the way in, not an ambush: \(said)")
        XCTAssertTrue(said.contains { $0.contains("open it") }, "\(said)")
    }

    /// A door that is NOT on the final approach is still an obstacle.
    func testADoorMidRouteIsStillAnObstacle() {
        XCTAssertFalse(RouteFeature.isWayThrough(obstacle: .door, target: .corridor, onFinalApproach: false))
        var planner = FeedbackPlanner()
        let midRoute = GuidanceInstruction(kind: .continueStraight, bearingRadians: 0, distanceMeters: 12,
                                           targetNodeId: UUID(), targetLabel: nil, targetPosition: SIMD3(0, 0, -12),
                                           hazard: nil, targetKind: .corridor, destinationLabel: nil)
        let door = ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.6, confidence: 0.9)
        let said = spoken(planner.plan(instruction: midRoute, obstacle: .stop, trackingOK: true,
                                       report: door, time: 1, isMoving: true))
        XCTAssertTrue(said.contains { $0.hasPrefix("Stop.") }, "\(said)")
    }

    // MARK: Priority contract - F-1 / F-7 (2026-10-18 recorded walk)

    /// A caution QUEUES. It used to be `.critical`, which cuts off whatever is being said - including
    /// the route instruction - so in a cluttered room no turn was ever spoken.
    func testACautionDoesNotInterrupt() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true,
                                   report: wall, time: 1, isMoving: true)
        let cautions = actions.compactMap { action -> SpeechPriority? in
            if case .speak(let text, let priority) = action, text.hasPrefix("Careful") { return priority }
            return nil
        }
        XCTAssertEqual(cautions, [.high], "a caution queues; only a STOP interrupts: \(actions)")
    }

    /// ...and a STOP still does interrupt. That is the line the contract reserves `.critical` for.
    func testAStopStillInterrupts() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                   report: wall, time: 1, isMoving: true)
        let stops = actions.compactMap { action -> SpeechPriority? in
            if case .speak(let text, let priority) = action, text.hasPrefix("Stop") { return priority }
            return nil
        }
        XCTAssertEqual(stops, [.critical], "\(actions)")
    }

    // MARK: Boxed in - F-5 (2026-10-18): "Stop." with no way out was all the user heard

    /// Blocked ahead, and neither side is a usable way round: the advisor says so.
    func testBoxedInWhenNeitherSideIsUsable() {
        var advisor = AvoidanceAdvisor()
        let walls = AvoidanceAdvisor.Clearance(ahead: 0.8, left: 0.4, right: 0.5)
        XCTAssertNil(advisor.advise(walls), "neither side is decisively better")
        XCTAssertTrue(advisor.isBoxedIn(walls))
    }

    /// Two equally roomy sides is not a way round either (the advisor refuses to flip a coin), so the
    /// user is still boxed in as far as guidance is concerned.
    func testBoxedInWhenTheSidesAreTooSimilar() {
        var advisor = AvoidanceAdvisor()
        let corridor = AvoidanceAdvisor.Clearance(ahead: 0.8, left: 2.0, right: 1.9)
        XCTAssertNil(advisor.advise(corridor))
        XCTAssertTrue(advisor.isBoxedIn(corridor))
    }

    /// A way round stands: not boxed in, and `isBoxedIn` must agree with `advise`.
    func testNotBoxedInWhenThereIsAWayRound() {
        var advisor = AvoidanceAdvisor()
        let gap = AvoidanceAdvisor.Clearance(ahead: 0.8, left: 3, right: 0.9)
        XCTAssertEqual(advisor.advise(gap), .left)
        XCTAssertFalse(advisor.isBoxedIn(gap))
    }

    /// The way ahead is open: nothing to be boxed in by.
    func testNotBoxedInWhenTheWayAheadIsOpen() {
        var advisor = AvoidanceAdvisor()
        let open = AvoidanceAdvisor.Clearance(ahead: 6, left: 0.3, right: 0.3)
        XCTAssertNil(advisor.advise(open))
        XCTAssertFalse(advisor.isBoxedIn(open))
    }

    /// The planner turns that into something to DO, alongside the stop warning it never replaces.
    func testItSaysToBackUpWhenThereIsNoWayRound() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                       report: wall, time: 1, isMoving: true,
                                       avoidTowards: nil, backUp: true))
        XCTAssertTrue(said.contains { $0.hasPrefix("Stop.") }, "the warning still comes first: \(said)")
        XCTAssertTrue(said.contains("Back up slowly."), "\(said)")
    }

    /// A way round beats backing up: we never say both.
    func testBackUpIsNotOfferedWhenThereIsAWayRound() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                       report: wall, time: 1, isMoving: true,
                                       avoidTowards: .left, backUp: true))
        XCTAssertTrue(said.contains("Slightly left, there is a wall ahead."), "\(said)")
        XCTAssertFalse(said.contains("Back up slowly."), "one instruction, not two: \(said)")
    }

    /// Same rule as the way round: once per obstacle, not nagged every tick.
    func testBackUpIsSaidOncePerObstacle() {
        var planner = FeedbackPlanner()
        _ = planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true, report: wall,
                         time: 1, isMoving: true, avoidTowards: nil, backUp: true)
        let again = spoken(planner.plan(instruction: walking(), obstacle: .stop, trackingOK: true,
                                        report: wall, time: 4, isMoving: true,
                                        avoidTowards: nil, backUp: true))
        XCTAssertFalse(again.contains("Back up slowly."), "said once: \(again)")
    }

    /// A door on the route is the way IN: never tell the user to back away from their destination.
    func testNoBackUpIsOfferedForADoorOnTheRoute() {
        var planner = FeedbackPlanner()
        let door = ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.5, confidence: 0.9)
        let said = spoken(planner.plan(instruction: walking(targetKind: .room, label: "Room 402"),
                                       obstacle: .stop, trackingOK: true, report: door,
                                       time: 1, isMoving: true, avoidTowards: nil, backUp: true))
        XCTAssertFalse(said.contains("Back up slowly."), "open the door, do not retreat: \(said)")
        XCTAssertTrue(said.contains { $0.contains("open it") }, "\(said)")
    }

    /// A door we were routed through is the way IN, not something to sidestep.
    func testNoWayRoundIsOfferedForADoorOnTheRoute() {
        var planner = FeedbackPlanner()
        let door = ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.5, confidence: 0.9)
        let said = spoken(planner.plan(instruction: walking(targetKind: .room, label: "Room 402"),
                                       obstacle: .stop, trackingOK: true, report: door,
                                       time: 1, isMoving: true, avoidTowards: .left))
        XCTAssertFalse(said.contains { $0.hasPrefix("Slightly") }, "open the door, do not walk round it: \(said)")
        XCTAssertTrue(said.contains { $0.contains("open it") }, "\(said)")
    }

    /// With no side measured, behaviour is exactly as before.
    func testNoSuggestionWhenNoSideWasMeasured() {
        var planner = FeedbackPlanner()
        let said = spoken(planner.plan(instruction: walking(), obstacle: .caution, trackingOK: true,
                                       report: wall, time: 1, isMoving: true))
        XCTAssertFalse(said.contains { $0.hasPrefix("Slightly") })
        XCTAssertTrue(said.contains { $0.hasPrefix("Careful.") }, "\(said)")
    }
}
