//
// File:     Tests/WaypointCoreTests/AccessibilityGuidanceTests.swift
// Purpose:  Proves the accessibility behaviour requested by U1 (2026-10-17): the phone-posture coach, object-aware obstacle speech
//           ("Stop. You are about to walk into a trash can."), distance-aware route guidance (briefing, countdown, landmarks) and the label
//           mapping from ARKit/Vision to obstacle kinds. These are the exact sentences a blind user will hear, so they are asserted verbatim.
//
import XCTest
import simd
@testable import WaypointCore

// MARK: - Phone posture

final class PhonePostureTests: XCTestCase {

    private func reading(pitch: Float, roll: Float, forward: SIMD3<Float> = [0, 0, -1]) -> PostureReading {
        PostureMonitor.reading(cameraTransform: Geometry.cameraTransform(position: [0, 1.3, 0], forward: forward, pitchDegrees: pitch, rollDegrees: roll))
    }

    func testReadingRoundTripsPitchAndRollAtAnyHeading() {
        for forward in [SIMD3<Float>(0, 0, -1), [1, 0, 0], [-0.6, 0, 0.8]] {
            for (p, r) in [(0, 0), (20, 10), (-45, 0), (30, -20), (0, 45), (0, 90), (-10, -80), (60, 15)] as [(Float, Float)] {
                let got = reading(pitch: p, roll: r, forward: forward)
                XCTAssertEqual(got.pitchDegrees, p, accuracy: 0.5, "pitch \(p) roll \(r) heading \(forward)")
                XCTAssertEqual(got.rollDegrees, r, accuracy: 0.5, "pitch \(p) roll \(r) heading \(forward)")
            }
        }
    }

    func testIssueMessagesTellTheUserWhatToDo() {
        XCTAssertEqual(PostureIssue.tiltedDown.message, "The phone is pointing down. Hold it upright, with the camera facing forward.")
        XCTAssertEqual(PostureIssue.sideways.message, "Hold the phone upright, not sideways.")
    }

    func testBadPostureMustPersistBeforeWeSpeak_andJitterIsIgnored() {
        var m = PostureMonitor()
        _ = m.update(reading: .init(pitchDegrees: 0, rollDegrees: 0), time: 0)
        // A brief dip (hand jitter / looking at a sign) of 0.3 s never speaks.
        XCTAssertNil(m.update(reading: .init(pitchDegrees: -50, rollDegrees: 0), time: 1.0).announcement)
        XCTAssertNil(m.update(reading: .init(pitchDegrees: -50, rollDegrees: 0), time: 1.3).announcement)
        XCTAssertNil(m.update(reading: .init(pitchDegrees: 0, rollDegrees: 0), time: 1.4).announcement)
        XCTAssertNil(m.issue)
        // A sustained one does, after 0.8 s.
        XCTAssertNil(m.update(reading: .init(pitchDegrees: -50, rollDegrees: 0), time: 2.0).announcement)
        XCTAssertNil(m.update(reading: .init(pitchDegrees: -50, rollDegrees: 0), time: 2.5).announcement)
        let u = m.update(reading: .init(pitchDegrees: -50, rollDegrees: 0), time: 2.9)
        XCTAssertEqual(u.issue, .tiltedDown)
        XCTAssertEqual(u.announcement, PostureIssue.tiltedDown.message)
    }

    func testRepeatsEvery8SecondsThenAnnouncesRecoveryWithHysteresis() {
        var m = PostureMonitor()
        func tick(_ pitch: Float, _ t: TimeInterval) -> PostureUpdate { m.update(reading: .init(pitchDegrees: pitch, rollDegrees: 0), time: t) }
        _ = tick(-50, 0); _ = tick(-50, 0.9)                            // confirmed at 0.9, spoken
        XCTAssertNil(tick(-50, 5).announcement)                          // no nagging
        XCTAssertEqual(tick(-50, 9.0).announcement, PostureIssue.tiltedDown.message) // reminder 8 s after the first
        // -25 degrees is between the exit (20) and enter (30) thresholds: still wrong (hysteresis), no flicker back to "good".
        XCTAssertEqual(tick(-25, 9.5).issue, .tiltedDown)
        XCTAssertEqual(tick(-25, 11).issue, .tiltedDown)
        // Properly fixed: needs 0.5 s of good pose, then ONE recovery message.
        XCTAssertNil(tick(0, 12).announcement)
        let done = tick(0, 12.6)
        XCTAssertTrue(done.recovered)
        XCTAssertEqual(done.announcement, "Phone position is good.")
        XCTAssertNil(done.issue)
        XCTAssertNil(tick(0, 13).announcement)
    }

    func testEachWayOfHoldingItWrongIsNamed() {
        func issue(pitch: Float, roll: Float) -> PostureIssue? {
            var m = PostureMonitor()
            _ = m.update(reading: .init(pitchDegrees: pitch, rollDegrees: roll), time: 0)
            return m.update(reading: .init(pitchDegrees: pitch, rollDegrees: roll), time: 1).issue
        }
        XCTAssertNil(issue(pitch: 0, roll: 0))
        XCTAssertNil(issue(pitch: -15, roll: 10))        // a relaxed, slightly tilted hold is fine
        XCTAssertNil(issue(pitch: 20, roll: -15))
        XCTAssertEqual(issue(pitch: -50, roll: 0), .tiltedDown)
        XCTAssertEqual(issue(pitch: 50, roll: 0), .tiltedUp)
        XCTAssertEqual(issue(pitch: 0, roll: 40), .leaningRight)
        XCTAssertEqual(issue(pitch: 0, roll: -40), .leaningLeft)
        XCTAssertEqual(issue(pitch: 0, roll: 90), .sideways)
        XCTAssertEqual(issue(pitch: 0, roll: -85), .sideways)
    }
}

// MARK: - Labels, phrases, band

final class ObstacleVocabularyTests: XCTestCase {

    func testMeshClassificationMapping() {
        XCTAssertEqual(ObstacleLabelMapper.kind(fromMeshClass: "wall"), .wall)
        XCTAssertEqual(ObstacleLabelMapper.kind(fromMeshClass: "seat"), .chair)
        XCTAssertEqual(ObstacleLabelMapper.kind(fromMeshClass: "Door"), .door)
        XCTAssertNil(ObstacleLabelMapper.kind(fromMeshClass: "floor"))
        XCTAssertNil(ObstacleLabelMapper.kind(fromMeshClass: "ceiling"))
        XCTAssertNil(ObstacleLabelMapper.kind(fromMeshClass: "none"))
    }

    func testImageLabelMappingUsesWholeWordsAndConfidence() {
        func kind(_ labels: [(String, Float)]) -> ObstacleKind? {
            ObstacleLabelMapper.kind(fromImageLabels: labels.map { (label: $0.0, confidence: $0.1) })?.kind
        }
        XCTAssertEqual(kind([("trash_can", 0.9)]), .trashCan)
        XCTAssertEqual(kind([("garbage can", 0.5), ("wall", 0.4)]), .trashCan)
        XCTAssertEqual(kind([("Rubbish Bin", 0.7)]), .trashCan)
        XCTAssertEqual(kind([("wastebasket", 0.6)]), .trashCan)
        XCTAssertNil(kind([("cabin", 0.9)]), "'bin' inside 'cabin' must not match")
        XCTAssertNil(kind([("binoculars", 0.95)]), "'bin' inside 'binoculars' must not match")
        XCTAssertEqual(kind([("office_chair", 0.8)]), .chair)
        XCTAssertEqual(kind([("adult", 0.7)]), .person)
        XCTAssertEqual(kind([("potted plant", 0.5)]), .plant)
        XCTAssertEqual(kind([("staircase", 0.6)]), .stairs)
        XCTAssertEqual(kind([("cabinet", 0.9)]), .furniture, "labels seen in the real vocabulary of the phone")
        XCTAssertEqual(kind([("wheelchair", 0.7)]), .chair)
        XCTAssertEqual(kind([("folding_chair", 0.6)]), .chair)
        XCTAssertEqual(kind([("decorative_plant", 0.5)]), .plant)
        XCTAssertEqual(kind([("swivel_chair", 0.5)]), .chair)
        XCTAssertNil(kind([("trash_can", 0.2)]), "below the confidence floor")
        XCTAssertEqual(kind([("person", 0.6), ("chair", 0.8)]), .chair, "the more confident label wins")
        XCTAssertNil(kind([]))
    }

    func testObstacleBandIgnoresFloorAndCeiling() {
        // Phone at 1.3 m: the floor is y=0. Below 15 cm above the floor and above 30 cm over the phone are not obstacles.
        XCTAssertFalse(ObstacleBand.contains(pointY: 0.02, cameraY: 1.3))
        XCTAssertTrue(ObstacleBand.contains(pointY: 0.30, cameraY: 1.3))    // trash can rim
        XCTAssertTrue(ObstacleBand.contains(pointY: 1.40, cameraY: 1.3))    // head height
        XCTAssertFalse(ObstacleBand.contains(pointY: 2.40, cameraY: 1.3))   // ceiling
    }

    func testDistancePhrases() {
        XCTAssertEqual(DistanceSpeech.phrase(meters: 0.3), "right in front of you")
        XCTAssertEqual(DistanceSpeech.phrase(meters: 0.7), "about 1 step")
        XCTAssertEqual(DistanceSpeech.phrase(meters: 1.4), "about 2 steps")
        XCTAssertEqual(DistanceSpeech.phrase(meters: 4.4), "about 4 meters")
        XCTAssertEqual(DistanceSpeech.meters(1), "1 meter")
        XCTAssertEqual(DistanceSpeech.meters(5.2), "5 meters")
    }

    func testStopSentencesNameTheObjectAndWhereItIs() {
        func stop(_ k: ObstacleKind, _ side: Side = .ahead, conf: Float = 1) -> String {
            ObstacleSpeech.stop(ObstacleReport(kind: k, side: side, distanceMeters: 0.5, confidence: conf))
        }
        XCTAssertEqual(stop(.wall), "Stop. You are heading toward a wall.")
        XCTAssertEqual(stop(.trashCan), "Stop. You are about to walk into a trash can.")
        XCTAssertEqual(stop(.chair), "Stop. You are about to walk into a chair.")
        XCTAssertEqual(stop(.table), "Stop. You are about to walk into a table.")
        XCTAssertEqual(stop(.person), "Stop. A person is directly ahead.")
        XCTAssertEqual(stop(.stairs), "Stop. Stairs directly ahead.")
        XCTAssertEqual(stop(.furniture), "Stop. You are about to walk into a piece of furniture.")
        XCTAssertEqual(stop(.unknown), "Stop. Obstacle directly ahead.")
        XCTAssertEqual(stop(.table, .left), "Stop. A table very close on your left.")
        XCTAssertEqual(stop(.trashCan, conf: 0.4), "Stop. Possibly a trash can directly ahead.", "honest when unsure")
        XCTAssertEqual(ObstacleSpeech.stop(nil), "Stop. Obstacle ahead.")
    }

    func testCautionSentencesIncludeSideAndDistance() {
        XCTAssertEqual(ObstacleSpeech.caution(ObstacleReport(kind: .chair, side: .left, distanceMeters: 1.4)), "Careful. A chair on your left, about 2 steps.")
        XCTAssertEqual(ObstacleSpeech.caution(ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 2.8)), "Careful. A wall ahead, about 3 meters.")
        XCTAssertEqual(ObstacleSpeech.caution(ObstacleReport(kind: .trashCan, side: .right, distanceMeters: 1.0, confidence: 0.4)),
                       "Careful. Possibly a trash can on your right, about 1 step.")
        XCTAssertEqual(ObstacleSpeech.caution(nil), "Obstacle ahead.")
    }
}

// MARK: - Route look-ahead, landmarks

final class RouteLookaheadTests: XCTestCase {

    private func line(_ points: [SIMD3<Float>], labelsAtEnd: String? = nil, stairsEdge: Int? = nil) -> (RouteFollower, [MapNode]) {
        var nodes = points.enumerated().map { MapNode(kind: .corridor, position: $1) }
        if let l = labelsAtEnd { nodes[nodes.count - 1].kind = .room; nodes[nodes.count - 1].label = l }
        let edges = (0..<(nodes.count - 1)).map { MapEdge(from: nodes[$0].id, to: nodes[$0 + 1].id, distance: simd_distance(points[$0], points[$0 + 1]),
                                                         hazard: $0 == stairsEdge ? .stairs : nil) }
        let graph = WaypointGraph(map: BuildingMap(name: "t", nodes: nodes, edges: edges))
        return (RouteFollower(route: nodes, graph: graph), nodes)
    }

    func testFindsTheNextTurnAlongTheRouteNotStraightLine() throws {
        // 9 m straight, then turn right for 6 m.
        let (f, _) = line([[0, 0, 0], [0, 0, -3], [0, 0, -6], [0, 0, -9], [3, 0, -9], [6, 0, -9]])
        let first = f.update(position: [0, 0, 0], forward: [0, 0, -1])
        let m = try XCTUnwrap(first.upcoming)
        XCTAssertEqual(m.kind, .turnRight)
        XCTAssertEqual(m.distanceMeters, 9, accuracy: 0.05)
        // After walking 6 m the same maneuver is 3 m away.
        _ = f.update(position: [0, 0, -3], forward: [0, 0, -1])
        let later = try XCTUnwrap(f.update(position: [0, 0, -6], forward: [0, 0, -1]).upcoming)
        XCTAssertEqual(later.kind, .turnRight)
        XCTAssertEqual(later.distanceMeters, 3, accuracy: 0.05)
    }

    func testTurnLeftStairsAndArrival() throws {
        let (left, _) = line([[0, 0, 0], [0, 0, -4], [-4, 0, -4]])
        XCTAssertEqual(left.update(position: [0, 0, 0], forward: [0, 0, -1]).upcoming?.kind, .turnLeft)

        let (stairs, _) = line([[0, 0, 0], [0, 0, -3], [0, 0, -6]], stairsEdge: 1)
        let s = try XCTUnwrap(stairs.update(position: [0, 0, 0], forward: [0, 0, -1]).upcoming)
        XCTAssertEqual(s.kind, .stairs)
        XCTAssertEqual(s.distanceMeters, 3, accuracy: 0.05)

        let (straight, _) = line([[0, 0, 0], [0, 0, -5], [0, 0, -10]], labelsAtEnd: "Room 204")
        let a = try XCTUnwrap(straight.update(position: [0, 0, 0], forward: [0, 0, -1]).upcoming)
        XCTAssertEqual(a.kind, .arrive)
        XCTAssertEqual(a.label, "Room 204")
        XCTAssertEqual(a.distanceMeters, 10, accuracy: 0.05)
    }

    func testLandmarkOnTheRightAbeamOfTheUser() throws {
        let sample = try loadSampleMap()
        let graph = WaypointGraph(map: sample)
        func id(_ s: String) -> UUID { UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000\(s)")! }
        let route = try XCTUnwrap(Router.route(in: graph, from: id("A1"), to: id("A5")))
        let f = RouteFollower(route: route, graph: graph)
        _ = f.update(position: [0, 0, 0], forward: [0, 0, -1])
        let abeam = f.update(position: [0, 0, -9], forward: [0, 0, -1]) // Room 204 is 1.5 m to the right
        XCTAssertEqual(abeam.landmark?.label, "Room 204")
        XCTAssertEqual(abeam.landmark?.side, .right)
    }
}

// MARK: - The planner speaking all of it

final class AccessibleGuidancePlannerTests: XCTestCase {

    private let node = UUID()

    private func instruction(_ kind: GuidanceInstruction.Kind = .continueStraight, upcoming: Maneuver? = nil, landmark: Landmark? = nil,
                             target: UUID? = nil) -> GuidanceInstruction {
        GuidanceInstruction(kind: kind, bearingRadians: 0, distanceMeters: 3, targetNodeId: target ?? node, targetLabel: nil,
                            targetPosition: [0, 0, -3], hazard: nil, upcoming: upcoming, landmark: landmark)
    }

    private func spoken(_ actions: [FeedbackAction]) -> [String] {
        actions.compactMap { if case .speak(let t, _) = $0 { return t }; return nil }
    }

    private func turn(_ d: Float, _ id: UUID) -> Maneuver { Maneuver(kind: .turnRight, distanceMeters: d, nodeId: id) }

    // ---- posture

    func testBadPostureSpeaksVibratesAndMutesGuidance() {
        var p = FeedbackPlanner()
        let bad = PostureUpdate(reading: .init(pitchDegrees: -50, rollDegrees: 0), issue: .tiltedDown,
                                announcement: PostureIssue.tiltedDown.message, recovered: false)
        let a = p.plan(instruction: instruction(.turnRight), obstacle: .clear, trackingOK: true, posture: bad)
        XCTAssertEqual(a, [.speak(PostureIssue.tiltedDown.message, priority: .high), .haptic(.holdPhoneUpright), .beacon(nil)])

        let quiet = PostureUpdate(reading: bad.reading, issue: .tiltedDown, announcement: nil, recovered: false)
        XCTAssertEqual(p.plan(instruction: instruction(.turnRight), obstacle: .clear, trackingOK: true, posture: quiet), [.beacon(nil)],
                       "no turn cues from a wrong heading, and no nagging")

        let ok = PostureUpdate(reading: .init(pitchDegrees: 0, rollDegrees: 0), issue: nil, announcement: "Phone position is good.", recovered: true)
        let back = p.plan(instruction: instruction(.turnRight), obstacle: .clear, trackingOK: true, posture: ok)
        XCTAssertEqual(spoken(back), ["Phone position is good."], "only the confirmation on the recovery tick")
        let next = p.plan(instruction: instruction(.turnRight), obstacle: .clear, trackingOK: true,
                          posture: PostureUpdate(reading: ok.reading, issue: nil, announcement: nil, recovered: false))
        XCTAssertTrue(next.contains { if case .speak(let t, _) = $0 { return t.hasPrefix("Turn right") } else { return false } },
                      "guidance resumes with the current instruction on the next tick")
    }

    func testObstacleWarningsStillWorkWhilePostureIsWrong() {
        var p = FeedbackPlanner()
        let bad = PostureUpdate(reading: .init(pitchDegrees: -50, rollDegrees: 0), issue: .tiltedDown, announcement: PostureIssue.tiltedDown.message, recovered: false)
        let a = p.plan(instruction: instruction(), obstacle: .stop, trackingOK: true, posture: bad,
                       report: ObstacleReport(kind: .wall, distanceMeters: 0.4))
        XCTAssertEqual(a.first, .speak("Stop. You are heading toward a wall.", priority: .high), "a wall outranks the posture message")
    }

    // ---- obstacles by type

    func testObstacleKindIsSpokenAndReannouncedWhenItChanges() {
        var p = FeedbackPlanner()
        let wall = ObstacleReport(kind: .wall, distanceMeters: 0.5)
        let can = ObstacleReport(kind: .trashCan, distanceMeters: 0.5)
        let first = p.plan(instruction: instruction(), obstacle: .stop, trackingOK: true, report: wall)
        XCTAssertEqual(first, [.speak("Stop. You are heading toward a wall.", priority: .high), .haptic(.obstacleStop), .beacon(nil)])
        XCTAssertEqual(p.plan(instruction: instruction(), obstacle: .stop, trackingOK: true, report: wall), [.beacon(nil)], "same thing, no chatter")
        let changed = p.plan(instruction: instruction(), obstacle: .stop, trackingOK: true, report: can)
        XCTAssertEqual(spoken(changed), ["Stop. You are about to walk into a trash can."])
        XCTAssertFalse(changed.contains(.haptic(.obstacleStop)), "no second buzz for a relabel")
    }

    func testStopIsRepeatedEveryThreeSecondsWhileItPersists() {
        var p = FeedbackPlanner()
        let r = ObstacleReport(kind: .chair, distanceMeters: 0.4)
        XCTAssertFalse(spoken(p.plan(instruction: nil, obstacle: .stop, trackingOK: true, report: r, time: 10)).isEmpty)
        XCTAssertTrue(spoken(p.plan(instruction: nil, obstacle: .stop, trackingOK: true, report: r, time: 12.5)).isEmpty)
        let again = p.plan(instruction: nil, obstacle: .stop, trackingOK: true, report: r, time: 13.1)
        XCTAssertEqual(spoken(again), ["Stop. You are about to walk into a chair."])
        XCTAssertTrue(again.contains(.haptic(.obstacleStop)))
    }

    func testCautionIsHighPriorityAndNamesTheObject() {
        var p = FeedbackPlanner()
        let a = p.plan(instruction: nil, obstacle: .caution, trackingOK: true, report: ObstacleReport(kind: .person, side: .left, distanceMeters: 1.9))
        XCTAssertEqual(a.first, .speak("Careful. A person on your left, about 3 steps.", priority: .high))
        XCTAssertTrue(a.contains(.haptic(.obstacleCaution)))
    }

    // ---- route guidance

    func testRouteBriefingReplacesFirstContinueStraightAndIsSaidOnce() {
        var p = FeedbackPlanner()
        let a = p.plan(instruction: instruction(upcoming: turn(12, UUID())), obstacle: .clear, trackingOK: true)
        XCTAssertEqual(spoken(a), ["Walk straight about 12 meters, then turn right."])
        XCTAssertTrue(spoken(p.plan(instruction: instruction(upcoming: turn(11.5, UUID())), obstacle: .clear, trackingOK: true)).isEmpty)
    }

    func testCountdownToATurnIsSpokenAt10_5_2MetersOnly() {
        var p = FeedbackPlanner()
        let turnNode = UUID()
        var said: [String] = []
        for d: Float in [14, 12, 9.6, 8, 6, 4.8, 3.5, 1.9, 1.4, 0.9, 0.4] {
            said += spoken(p.plan(instruction: instruction(upcoming: turn(d, turnNode)), obstacle: .clear, trackingOK: true))
        }
        XCTAssertEqual(said, ["Walk straight about 14 meters, then turn right.",
                              "In 10 meters, turn right.", "In 5 meters, turn right.", "In 2 meters, turn right."])
    }

    func testFirstSeenCloseDoesNotBurstOldWarnings() {
        var p = FeedbackPlanner()
        let turnNode = UUID()
        var said: [String] = []
        for d: Float in [1.8, 1.5, 1.3] { said += spoken(p.plan(instruction: instruction(upcoming: turn(d, turnNode)), obstacle: .clear, trackingOK: true)) }
        XCTAssertEqual(said.filter { $0.hasPrefix("In ") }, ["In 2 meters, turn right."])
    }

    func testStairsAndArrivalCountdowns() {
        XCTAssertEqual(ManeuverSpeech.warning(Maneuver(kind: .stairs, distanceMeters: 4.6, nodeId: node)), "In 5 meters, stairs.")
        XCTAssertEqual(ManeuverSpeech.warning(Maneuver(kind: .arrive, distanceMeters: 9.6, nodeId: node, label: "Room 204")), "In 10 meters, you will arrive at Room 204.")
        XCTAssertEqual(ManeuverSpeech.briefing(distanceToFirstManeuver: Maneuver(kind: .arrive, distanceMeters: 12, nodeId: node, label: "Room 204")),
                       "Walk straight about 12 meters to Room 204.")
        XCTAssertEqual(ManeuverSpeech.briefing(distanceToFirstManeuver: Maneuver(kind: .stairs, distanceMeters: 8, nodeId: node)),
                       "Walk straight about 8 meters. Then there are stairs.")
        XCTAssertNil(ManeuverSpeech.briefing(distanceToFirstManeuver: nil))
    }

    func testLandmarkIsAnnouncedOnce() {
        var p = FeedbackPlanner()
        let l = Landmark(label: "Room 206", side: .right, nodeId: UUID())
        let first = spoken(p.plan(instruction: instruction(landmark: l), obstacle: .clear, trackingOK: true))
        XCTAssertTrue(first.contains("Room 206 on your right."))
        XCTAssertFalse(spoken(p.plan(instruction: instruction(landmark: l), obstacle: .clear, trackingOK: true)).contains("Room 206 on your right."))
    }
}
