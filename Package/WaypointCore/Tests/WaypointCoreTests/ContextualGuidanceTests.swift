//
// File:     Tests/WaypointCoreTests/ContextualGuidanceTests.swift
// Purpose:  The four user-reported guidance fixes (2026-10-17): (1) no warnings at the destination, only "arrived";
//           (2) sensor surroundings feed the warnings; (3) a short opening briefing; (4) Siri voice selection.
//
import XCTest
import simd
@testable import WaypointCore

final class ContextualGuidanceTests: XCTestCase {

    private let node = UUID()

    private func instr(_ kind: GuidanceInstruction.Kind = .continueStraight, distance: Float = 3,
                       upcoming: Maneuver? = nil, targetKind: NodeKind? = .room, label: String? = "Room 204") -> GuidanceInstruction {
        GuidanceInstruction(kind: kind, bearingRadians: 0, distanceMeters: distance, targetNodeId: node, targetLabel: label,
                            targetPosition: [0, 0, -5], hazard: nil, upcoming: upcoming, targetKind: targetKind)
    }
    private func spoken(_ actions: [FeedbackAction]) -> [String] {
        actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
    }

    // MARK: 1. Arrival

    func testArrivalIsSayOnceAndLatchesAgainstEverythingAfter() {
        var p = FeedbackPlanner()
        let arrived = p.plan(instruction: instr(.arrived, distance: 0.4), obstacle: .stop, trackingOK: true,
                             report: ObstacleReport(kind: .door, distanceMeters: 0.4), time: 10)
        XCTAssertEqual(spoken(arrived).count, 1)
        XCTAssertTrue(spoken(arrived)[0].hasPrefix("You have arrived"))
        XCTAssertFalse(spoken(arrived)[0].contains("Stop"))
        // Afterwards: no obstacle alarms, no "lost position", no posture chatter.
        for t in [11.0, 14.0, 30.0] {
            XCTAssertTrue(spoken(p.plan(instruction: instr(.arrived, distance: 0.4), obstacle: .stop, trackingOK: true,
                                        report: ObstacleReport(kind: .wall, distanceMeters: 0.3), time: t)).isEmpty)
        }
        XCTAssertTrue(spoken(p.plan(instruction: nil, obstacle: .clear, trackingOK: false, time: 40)).isEmpty, "lost tracking after arrival must be silent")
        // A new navigation starts clean.
        p.reset()
        XCTAssertFalse(spoken(p.plan(instruction: instr(), obstacle: .stop, trackingOK: true, report: ObstacleReport(kind: .chair, distanceMeters: 0.5), time: 50)).isEmpty)
    }

    func testWallAndDoorAlarmsAreMutedInTheLastFewMetersButChairsStillWarn() {
        let near = Maneuver(kind: .arrive, distanceMeters: 2.0, nodeId: UUID(), label: "Room 204")
        for kind in [ObstacleKind.wall, .door, .window] {
            var p = FeedbackPlanner()
            let said = spoken(p.plan(instruction: instr(upcoming: near), obstacle: .stop, trackingOK: true,
                                     report: ObstacleReport(kind: kind, distanceMeters: 0.6), time: 1))
            XCTAssertFalse(said.contains { $0.contains("Stop") || $0.contains("Careful") }, "\(kind): \(said)")
        }
        var p = FeedbackPlanner()
        let chair = spoken(p.plan(instruction: instr(upcoming: near), obstacle: .stop, trackingOK: true,
                                  report: ObstacleReport(kind: .chair, distanceMeters: 0.6), time: 1))
        XCTAssertTrue(chair.contains { $0.contains("Stop") }, "a chair near the door is still a danger")
    }

    func testWallFarFromDestinationStillWarns() {
        var p = FeedbackPlanner()
        let far = Maneuver(kind: .arrive, distanceMeters: 12, nodeId: UUID(), label: "Room 204")
        let said = spoken(p.plan(instruction: instr(upcoming: far), obstacle: .stop, trackingOK: true,
                                 report: ObstacleReport(kind: .wall, distanceMeters: 0.6), time: 1))
        XCTAssertTrue(said.contains { $0.contains("wall") })
    }

    // MARK: 2. Context feeds warnings

    func testWarningsCarryAWayOutFromTheSurroundings() {
        let chair = ObstacleReport(kind: .chair, distanceMeters: 0.6)
        XCTAssertEqual(SceneAdvice.hint(for: chair, context: SceneContext(leftClearance: 2.5, rightClearance: 0.4)), "Open space on your left.")
        XCTAssertEqual(SceneAdvice.hint(for: chair, context: SceneContext(leftClearance: 0.3, rightClearance: nil)), "Open space on your right.")
        XCTAssertEqual(SceneAdvice.hint(for: chair, context: SceneContext(leftClearance: 0.3, rightClearance: 0.4)), "No room to pass on either side.")
        XCTAssertEqual(SceneAdvice.hint(for: chair, context: SceneContext()), "Clear on both sides.")
        XCTAssertEqual(SceneAdvice.hint(for: chair, context: SceneContext(leftClearance: 3, rightClearance: 1.5)), "More room on your left.")
        XCTAssertNil(SceneAdvice.hint(for: chair, context: nil), "no sensor, no advice")
        let onLeft = ObstacleReport(kind: .person, side: .left, distanceMeters: 1)
        XCTAssertEqual(SceneAdvice.hint(for: onLeft, context: SceneContext(rightClearance: 2)), "Keep to the right.")
        XCTAssertNil(SceneAdvice.hint(for: onLeft, context: SceneContext(rightClearance: 0.4)))
    }

    func testPlannerAppendsHintToStopWarning() {
        var p = FeedbackPlanner()
        let said = spoken(p.plan(instruction: instr(), obstacle: .stop, trackingOK: true,
                                 report: ObstacleReport(kind: .chair, distanceMeters: 0.6), time: 1,
                                 context: SceneContext(leftClearance: 2, rightClearance: 0.3)))
        XCTAssertEqual(said.first, "Stop. You are about to walk into a chair. Open space on your left.")
        var q = FeedbackPlanner()
        let plain = spoken(q.plan(instruction: instr(), obstacle: .stop, trackingOK: true, report: ObstacleReport(kind: .chair, distanceMeters: 0.6), time: 1))
        XCTAssertEqual(plain.first, "Stop. You are about to walk into a chair.")
    }

    func testNarrowSpaceIsAnnouncedOnceThenRateLimited() {
        var p = FeedbackPlanner()
        let narrow = SceneContext(leftClearance: 0.5, rightClearance: 0.6)
        XCTAssertTrue(spoken(p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 1, context: narrow)).contains("Narrow space. Go slowly."))
        XCTAssertFalse(spoken(p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 2, context: narrow)).contains("Narrow space. Go slowly."))
        // leaves the narrow part, comes back 5 s later: still inside the rate limit
        _ = p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 3, context: SceneContext(leftClearance: 3, rightClearance: 3))
        XCTAssertFalse(spoken(p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 6, context: narrow)).contains("Narrow space. Go slowly."))
        _ = p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 7, context: SceneContext())
        XCTAssertTrue(spoken(p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 30, context: narrow)).contains("Narrow space. Go slowly."))
    }

    func testNothingSeenIsOpenNotNarrow() {
        XCTAssertFalse(SceneContext(leftClearance: 0.4, rightClearance: nil).isNarrow)
        XCTAssertTrue(SceneContext(leftClearance: 0.4, rightClearance: 0.5).isNarrow)
    }

    func testLateralScanKeepsNearestPerSideAndIgnoresFarAndCentre() {
        var scan = LateralScan()
        scan.add(lateral: 1.2, depth: 2); scan.add(lateral: 0.8, depth: 1)   // right: nearest 0.8
        scan.add(lateral: -2.0, depth: 2)                                     // left: 2.0
        scan.add(lateral: 0.05, depth: 1)                                     // centre band: ignored
        scan.add(lateral: -0.3, depth: 6)                                     // beyond look-ahead: ignored
        scan.add(lateral: .nan, depth: 1)
        let c = scan.context(ahead: 4)
        XCTAssertEqual(c.rightClearance, 0.8)
        XCTAssertEqual(c.leftClearance, 2.0)
        XCTAssertEqual(c.aheadClearance, 4)
        XCTAssertNil(LateralScan().context(ahead: nil).leftClearance)
    }

    // MARK: 3. Opening briefing

    private func hallway() -> (WaypointGraph, MapNode, MapNode, MapNode, [MapNode]) {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .junction, position: [0, 0, -12])
        let stairs = MapNode(kind: .stairs, label: "Stairs", position: [-3, 0, -2])
        let r206 = MapNode(kind: .room, label: "Room 206", position: [3, 0, -1])
        let dest = MapNode(kind: .room, label: "Room 204", position: [10, 0, -12])
        let map = BuildingMap(name: "h", nodes: [a, b, stairs, r206, dest], edges: [
            MapEdge(from: a.id, to: b.id, distance: 12), MapEdge(from: b.id, to: dest.id, distance: 10)])
        return (WaypointGraph(map: map), a, stairs, dest, [a, b, dest])
    }

    func testOpeningBriefingSaysWhereWhatAndHow() {
        let (graph, _, _, dest, route) = hallway()
        let first = Maneuver(kind: .turnRight, distanceMeters: 12, nodeId: route[1].id)
        let text = StartBriefing.text(position: [0, 0, 0.2], forward: [0, 0, -1], graph: graph, route: route, destination: dest,
                                      context: nil, firstManeuver: first)
        XCTAssertEqual(text, "You are near Room 206. Stairs on your left. Room 204 is about 22 meters away. Walk straight about 12 meters, then turn right.")
        XCTAssertLessThanOrEqual(text.split(separator: " ").count, 35, "must stay short")
    }

    func testBriefingUsesSensorFactsAndFallsBackPlainly() {
        let (graph, _, _, dest, route) = hallway()
        let withWall = StartBriefing.text(position: [0, 0, 0], forward: [0, 0, -1], graph: graph, route: route, destination: dest,
                                          context: SceneContext(aheadClearance: 1.6), firstManeuver: nil)
        XCTAssertTrue(withWall.contains("Something is 2 meters ahead."), withWall)
        let narrow = StartBriefing.text(position: [0, 0, 0], forward: [0, 0, -1], graph: graph, route: route, destination: dest,
                                        context: SceneContext(leftClearance: 0.4, rightClearance: 0.5), firstManeuver: nil)
        XCTAssertTrue(narrow.contains("The space is narrow."))
        // far from every named place: hallway wording, no invented rooms
        let hall = StartBriefing.text(position: [0, 0, -11], forward: [0, 0, -1], graph: graph, route: route, destination: dest,
                                      context: nil, firstManeuver: nil)
        XCTAssertTrue(hall.hasPrefix("You are in a hallway."), hall)
        XCTAssertFalse(hall.contains("Room 206"))
    }

    func testBriefingDirectionsAreRelativeToFacing() {
        let (graph, _, _, dest, route) = hallway()
        // facing the opposite way: the stairs (to the -x side) are now on the RIGHT and Room 206 on the left
        let text = StartBriefing.text(position: [0, 0, 0.2], forward: [0, 0, 1], graph: graph, route: route, destination: dest,
                                      context: nil, firstManeuver: nil)
        XCTAssertTrue(text.contains("Stairs on your right"), text)
    }

    func testQueuedBriefingReplacesPlainBriefingOnceAndIsHighPriority() {
        var p = FeedbackPlanner()
        p.queueBriefing("OPENING.")
        let first = p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 1)
        XCTAssertTrue(first.contains(.speak("OPENING.", priority: .high)))
        let again = p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 2)
        XCTAssertFalse(spoken(again).contains("OPENING."))
        p.queueBriefing("STALE.")
        p.reset()
        XCTAssertFalse(spoken(p.plan(instruction: instr(), obstacle: .clear, trackingOK: true, time: 3)).contains("STALE."), "reset drops a queued briefing")
    }

    func testSignSpeech() {
        XCTAssertEqual(SignSpeech.text(read: "Room 206", isDestination: false), "Sign reads Room 206.")
        XCTAssertEqual(SignSpeech.text(read: "Room 204", isDestination: true), "Sign reads Room 204. This is your destination.")
    }

    // MARK: 4. Voice

    private func v(_ id: String, _ name: String, _ lang: String, _ q: Int) -> VoiceCandidate { VoiceCandidate(identifier: id, name: name, language: lang, quality: q) }

    func testSiriVoiceIsPreferredForTheUsersLanguage() {
        let voices = [v("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", 1),
                      v("com.apple.voice.premium.en-US.Zoe", "Zoe", "en-US", 3),
                      v("com.apple.ttsbundle.siri_Nicky_en-US_compact", "Nicky (Siri)", "en-US", 1),
                      v("com.apple.ttsbundle.siri_Aaron_en-GB_premium", "Aaron (Siri)", "en-GB", 3),
                      v("com.apple.ttsbundle.siri_Marie_fr-FR_compact", "Marie (Siri)", "fr-FR", 1)]
        XCTAssertEqual(VoicePicker.choose(from: voices, language: "en-US"), "com.apple.ttsbundle.siri_Nicky_en-US_compact", "exact region Siri beats a better non-Siri voice")
        XCTAssertEqual(VoicePicker.choose(from: voices, language: "fr-FR"), "com.apple.ttsbundle.siri_Marie_fr-FR_compact")
    }

    func testNoSiriVoiceFallsBackToBestEnhancedOrSystemDefault() {
        let compactOnly = [v("a", "Samantha", "en-US", 1)]
        XCTAssertNil(VoicePicker.choose(from: compactOnly, language: "en-US"), "nothing better than default: let the system choose")
        let withEnhanced = compactOnly + [v("b", "Ava", "en-US", 2), v("c", "Zoe", "en-US", 3)]
        XCTAssertEqual(VoicePicker.choose(from: withEnhanced, language: "en-US"), "c")
        XCTAssertNil(VoicePicker.choose(from: [], language: "en-US"))
        XCTAssertNil(VoicePicker.choose(from: withEnhanced, language: "de-DE"))
    }

    func testSiriDetectionByIdentifierOrName() {
        XCTAssertTrue(v("com.apple.ttsbundle.siri_X", "X", "en-US", 1).isSiri)
        XCTAssertTrue(v("id", "Siri Voice 2", "en-US", 1).isSiri)
        XCTAssertFalse(v("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", 1).isSiri)
    }
}
