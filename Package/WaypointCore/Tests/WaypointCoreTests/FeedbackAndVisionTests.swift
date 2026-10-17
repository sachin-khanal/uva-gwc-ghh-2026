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
        XCTAssertTrue(first.contains(.speak("Turn left.", priority: .normal)))
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
        XCTAssertTrue(arrived.contains(.speak("You have arrived at Room 204.", priority: .normal)))
        XCTAssertTrue(arrived.contains(.haptic(.arrived)))
        XCTAssertEqual(arrived.last, .beacon(nil))

        var q = FeedbackPlanner()
        let stairs = q.plan(instruction: instruction(.continueStraight, hazard: .stairs), obstacle: .clear, trackingOK: true)
        XCTAssertTrue(stairs.contains(.speak("Stairs ahead.", priority: .normal)))
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
