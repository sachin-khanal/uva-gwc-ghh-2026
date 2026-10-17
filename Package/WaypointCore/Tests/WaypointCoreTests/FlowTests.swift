//
// File:     Tests/WaypointCoreTests/FlowTests.swift
// Purpose:  Proves the pure logic behind the new Scanner / Navigator screens (Flows/*): screen state
//           machines, finish gating, route summaries and their spoken form, map health warnings,
//           plan-view projection, and the observe-only mapping from NavigationController /
//           CaptureController strings (if those strings change, these tests must fail).
//
import XCTest
import simd
@testable import WaypointCore

final class FlowTests: XCTestCase {

    private func id(_ suffix: String) -> UUID { UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000\(suffix)")! }

    // MARK: ScanFlow

    func testScanFlowHappyPath() {
        var flow = ScanFlow()
        XCTAssertEqual(flow.step, .library)
        flow.newScan();        XCTAssertEqual(flow.step, .setup)
        flow.startScanning();  XCTAssertEqual(flow.step, .scanning)
        flow.finishScanning(); XCTAssertEqual(flow.step, .review)
        flow.share();          XCTAssertEqual(flow.step, .share)
        XCTAssertTrue(flow.back()); XCTAssertEqual(flow.step, .review)
        flow.done();           XCTAssertEqual(flow.step, .library)
    }

    func testScanFlowIgnoresIllegalMovesAndCannotBackOutOfScanning() {
        var flow = ScanFlow()
        flow.finishScanning() // not scanning yet
        flow.share()
        XCTAssertEqual(flow.step, .library)
        XCTAssertFalse(flow.back())

        flow.newScan(); flow.startScanning()
        XCTAssertFalse(flow.back(), "back must not silently drop a scan in progress")
        XCTAssertEqual(flow.step, .scanning)
        flow.discardScan()
        XCTAssertEqual(flow.step, .library)

        flow.openReview()
        XCTAssertEqual(flow.step, .review)
    }

    func testFinishGate() {
        XCTAssertEqual(FinishGate.evaluate(quality: .extending, labelledTagCount: 3).isReady, false)
        XCTAssertNotNil(FinishGate.evaluate(quality: .limited, labelledTagCount: 0).reason)
        XCTAssertEqual(FinishGate.evaluate(quality: .mapped, labelledTagCount: 0),
                       .blocked("Tag at least one room or door with a label."))
        XCTAssertEqual(FinishGate.evaluate(quality: .mapped, labelledTagCount: 1), .ready)
    }

    func testScanTrackingParsesCaptureControllerSummaries() {
        XCTAssertEqual(ScanTracking.from(summary: "Tracking OK"), .normal)
        XCTAssertEqual(ScanTracking.from(summary: "Not started"), .starting)
        XCTAssertEqual(ScanTracking.from(summary: "Initializing - move the phone slowly"), .starting)
        XCTAssertEqual(ScanTracking.from(summary: "Moving too fast"), .limited("Moving too fast"))
        XCTAssertEqual(ScanTracking.from(summary: "Tracking unavailable"), .unavailable)
    }

    func testScanQualityProgressIsMonotonic() {
        let progress = ScanQuality.allCases.map(\.progress)
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(ScanQuality.mapped.progress, 1)
    }

    // MARK: NavigateFlow

    func testNavigateFlowSkipsBuildingWithOneMap() {
        XCTAssertEqual(NavigateFlow(mapCount: 1).step, .destination)
        XCTAssertEqual(NavigateFlow(mapCount: 3).step, .building)
        XCTAssertEqual(NavigateFlow(mapCount: 0).step, .building)
    }

    func testNavigateFlowFullRouteAndBack() {
        var flow = NavigateFlow(mapCount: 2)
        flow.chooseMap();         XCTAssertEqual(flow.step, .destination)
        flow.chooseDestination(); XCTAssertEqual(flow.step, .confirm)
        XCTAssertTrue(flow.back()); XCTAssertEqual(flow.step, .destination)
        flow.chooseDestination(); flow.start()
        XCTAssertEqual(flow.step, .active)
        flow.arrive();            XCTAssertEqual(flow.step, .arrived)
        flow.routeBack();         XCTAssertEqual(flow.step, .confirm)
        flow.start(); flow.arrive(); flow.newDestination()
        XCTAssertEqual(flow.step, .destination)
        XCTAssertTrue(flow.back()); XCTAssertEqual(flow.step, .building)
        XCTAssertFalse(flow.back(), "back from the first screen leaves Navigate mode")
    }

    func testBackNeverEndsAnActiveRoute() {
        var flow = NavigateFlow(mapCount: 1)
        flow.chooseDestination(); flow.start()
        XCTAssertTrue(flow.back())
        XCTAssertEqual(flow.step, .active)
        flow.stop()
        XCTAssertEqual(flow.step, .destination)
        XCTAssertFalse(flow.back(), "single map: destination is the first screen")
    }

    func testDefaultStartIsFirstBreadcrumbAndNeverTheDestination() throws {
        let map = try loadSampleMap()
        XCTAssertEqual(NavigateFlow.defaultStart(in: map, excluding: id("B1"))?.id, id("A1"))
        XCTAssertEqual(NavigateFlow.defaultStart(in: map, excluding: id("A1"))?.id, id("A2"))
    }

    // MARK: RouteSummary

    func testRouteSummaryToRoom204() throws {
        let map = try loadSampleMap()
        let summary = try XCTUnwrap(RouteSummary.make(map: map, from: id("A1"), to: id("B1")))
        XCTAssertEqual(summary.steps.map(\.kind), [.continueStraight, .turnRight, .arrived])
        XCTAssertEqual(summary.steps[0].distance, 9, accuracy: 0.001)
        XCTAssertEqual(summary.totalDistance, 10.5, accuracy: 0.001)
        XCTAssertEqual(summary.turnCount, 1)
        XCTAssertFalse(summary.hasStairs)
        // A2/A3 are plain breadcrumbs on a straight run and are collapsed by RouteSimplifier, so the
        // summary describes the walk ("straight, then right") rather than every breadcrumb.
        XCTAssertEqual(summary.nodeIds, [id("A1"), id("A4"), id("B1")])
        XCTAssertEqual(summary.spokenSummary, "Room 204. About 11 metres, 1 turn, no stairs.")
        XCTAssertEqual(summary.shortSummary, "About 11 m · 1 turn · no stairs")
    }

    func testRouteSummaryKeepsStairsAsTheirOwnStep() throws {
        let map = try loadSampleMap()
        let summary = try XCTUnwrap(RouteSummary.make(map: map, from: id("A1"), to: id("B3")))
        XCTAssertEqual(summary.steps.count, 3)
        XCTAssertEqual(summary.steps[1].hazard, .stairs)
        XCTAssertEqual(summary.totalDistance, 15, accuracy: 0.001)
        XCTAssertTrue(summary.hasStairs)
        XCTAssertEqual(summary.turnCount, 0)
        XCTAssertTrue(summary.spokenSummary.hasSuffix("includes stairs."))
    }

    func testRouteSummaryLeftTurnAndEdgeCases() throws {
        let map = try loadSampleMap()
        // A4 -> A1 walks toward +z (back to the start); the lobby door is then at -x, which is on the
        // RIGHT when facing +z. The door edge carries a doorThreshold hazard.
        let back = try XCTUnwrap(RouteSummary.make(map: map, from: id("A4"), to: id("B4")))
        XCTAssertEqual(back.steps.map(\.kind), [.continueStraight, .turnRight, .arrived])
        XCTAssertEqual(back.hazards, [.doorThreshold])

        let same = try XCTUnwrap(RouteSummary.make(map: map, from: id("A1"), to: id("A1")))
        XCTAssertEqual(same.steps.map(\.kind), [.arrived])
        XCTAssertEqual(same.totalDistance, 0)

        XCTAssertNil(RouteSummary.make(map: map, from: id("A1"), to: UUID()))
    }

    func testRouteSummaryDetectsLeftTurn() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [0, 0, -4])
        let c = MapNode(kind: .room, label: "Lab", position: [-3, 0, -4]) // -x while facing -z = left
        let map = BuildingMap(name: "L", nodes: [a, b, c], edges: [
            MapEdge(from: a.id, to: b.id, distance: 4), MapEdge(from: b.id, to: c.id, distance: 3)])
        let summary = RouteSummary.make(map: map, from: a.id, to: c.id)
        XCTAssertEqual(summary?.steps.map(\.kind), [.continueStraight, .turnLeft, .arrived])
        XCTAssertEqual(summary?.destinationLabel, "Lab")
    }

    // MARK: SpokenText

    func testSpokenDistances() {
        XCTAssertEqual(SpokenText.distance(0.4), "less than a metre")
        XCTAssertEqual(SpokenText.distance(1.4), "about 1 metre")
        XCTAssertEqual(SpokenText.distance(3.6), "about 4 metres")
        XCTAssertEqual(SpokenText.distance(19.4), "about 19 metres")
        XCTAssertEqual(SpokenText.distance(23), "about 25 metres")
        XCTAssertEqual(SpokenText.distance(.nan), "an unknown distance")
        XCTAssertEqual(SpokenText.turns(0), "no turns")
        XCTAssertEqual(SpokenText.turns(2), "2 turns")
        XCTAssertEqual(SpokenText.capitalizingFirst("about 3 metres"), "About 3 metres")
        XCTAssertEqual(SpokenText.capitalizingFirst(""), "")
    }

    // MARK: GuidanceSnapshot (observe-only adapter for NavigationController)

    func testParseInstructionMatchesNavigationControllerFormat() {
        // NavigationController formats: "\(kind.rawValue), \(String(format: "%.1f", distance)) m"
        let parsed = GuidanceSnapshot.parseInstruction("turnRight, 3.0 m")
        XCTAssertEqual(parsed?.kind, .turnRight)
        XCTAssertEqual(parsed?.distance ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(GuidanceSnapshot.parseInstruction("arrived, 0.4 m")?.kind, .arrived)
        XCTAssertNil(GuidanceSnapshot.parseInstruction(""))
        XCTAssertNil(GuidanceSnapshot.parseInstruction("sideways, 2.0 m"))
    }

    func testDerivePhaseFromNavigationControllerStrings() {
        func phase(_ status: String, _ instruction: String = "", _ obstacle: ObstacleLevel = .clear) -> GuidancePhase {
            GuidanceSnapshot.derive(status: status, instruction: instruction, obstacle: obstacle, destinationLabel: "Room 204").phase
        }
        XCTAssertEqual(phase("Looking for your position..."), .localizing)
        XCTAssertEqual(phase("Navigating", "turnLeft, 2.0 m"), .guiding)
        XCTAssertEqual(phase("Navigating"), .localizing, "no instruction yet")
        XCTAssertEqual(phase("Position lost. Hold still.", "turnLeft, 2.0 m"), .lost)
        XCTAssertEqual(phase("Tracking limited", "turnLeft, 2.0 m"), .lost)
        XCTAssertEqual(phase("Simulating walk", "continueStraight, 5.0 m", .stop), .obstacleStop)
        XCTAssertEqual(phase("Simulating walk", "arrived, 0.5 m"), .arrived)
        XCTAssertEqual(phase("Simulation finished", "arrived, 0.5 m"), .arrived)
        XCTAssertEqual(phase("Stopped"), .idle)
        if case .failed(let message) = phase("No route in this map") {
            XCTAssertTrue(message.contains("Room 204"))
        } else {
            XCTFail("expected failed")
        }
    }

    func testSnapshotTexts() {
        let guiding = GuidanceSnapshot(phase: .guiding, kind: .turnRight, distanceToNext: 3.2,
                                       obstacle: .caution, destinationLabel: "Room 204")
        XCTAssertEqual(guiding.headline, "Turn right")
        XCTAssertEqual(guiding.detail, "About 3 metres to the next point")
        XCTAssertEqual(guiding.spokenText, "Turn right. About 3 metres to the next point. Obstacle ahead.")

        let arrived = GuidanceSnapshot(phase: .arrived, destinationLabel: "Room 204")
        XCTAssertEqual(arrived.spokenText, "You have arrived at Room 204.")

        let lost = GuidanceSnapshot(phase: .lost)
        XCTAssertEqual(lost.spokenText, "Position lost. Hold still.")
        XCTAssertEqual(GuidanceSnapshot.idle.spokenText, "Ready.")
    }

    // MARK: MapHealth

    func testSampleMapIsHealthy() throws {
        XCTAssertEqual(MapHealth.check(try loadSampleMap()), [])
        XCTAssertEqual(MapHealth.componentCount(try loadSampleMap()), 1)
    }

    func testMapHealthWarnings() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .door, label: nil, position: [0, 0, -2])
        let c = MapNode(kind: .room, label: "Lab", position: [5, 0, 0])
        let d = MapNode(kind: .room, label: "lab ", position: [6, 0, 0])
        let map = BuildingMap(name: "x", nodes: [a, b, c, d], edges: [MapEdge(from: a.id, to: b.id, distance: 2)])
        let warnings = MapHealth.check(map)
        XCTAssertTrue(warnings.contains(.unlabeled(count: 1)))
        XCTAssertTrue(warnings.contains(.disconnected(parts: 3)))
        XCTAssertTrue(warnings.contains(.duplicateLabels(["Lab"])))
        XCTAssertFalse(warnings.contains(.noDestinations))

        XCTAssertEqual(MapHealth.check(BuildingMap(name: "empty")), [.tooSmall, .noDestinations])
        XCTAssertEqual(MapHealth.componentCount(BuildingMap(name: "empty")), 0)
        XCTAssertEqual(MapWarning.unlabeled(count: 2).message, "2 tagged places have no label.")
    }

    // MARK: PlanLayout

    func testPlanLayoutFitsAndIsNorthUp() throws {
        let map = try loadSampleMap()
        let points = PlanLayout.project(map.nodes, width: 200, height: 400, padding: 20)
        XCTAssertEqual(points.count, map.nodes.count)
        for p in points.values {
            XCTAssertGreaterThanOrEqual(p.x, 20 - 0.001); XCTAssertLessThanOrEqual(p.x, 180 + 0.001)
            XCTAssertGreaterThanOrEqual(p.y, 20 - 0.001); XCTAssertLessThanOrEqual(p.y, 380 + 0.001)
        }
        // A2 (z = -3) is further "north" (smaller z) than A1 (z = 0) so it is drawn higher (smaller y).
        XCTAssertLessThan(try XCTUnwrap(points[id("A2")]).y, try XCTUnwrap(points[id("A1")]).y)
        // Room 204 (x = +1.5) is drawn to the right of the corridor (x = 0).
        XCTAssertGreaterThan(try XCTUnwrap(points[id("B1")]).x, try XCTUnwrap(points[id("A4")]).x)
    }

    func testPlanLayoutSingleNodeIsCentredAndEmptyCases() {
        let n = MapNode(kind: .room, label: "Only", position: [3, 0, 3])
        let p = PlanLayout.project([n], width: 100, height: 60, padding: 10)[n.id]
        XCTAssertEqual(p, PlanPoint(x: 50, y: 30))
        XCTAssertTrue(PlanLayout.project([], width: 100, height: 100, padding: 10).isEmpty)
        XCTAssertTrue(PlanLayout.project([n], width: 10, height: 100, padding: 10).isEmpty)
    }
}

// MARK: - Loading the saved scan reads as "finding you", not as a frozen screen (2026-10-17)

final class LoadingPhaseTests: XCTestCase {

    /// Reading a big ARWorldMap happens BEFORE the camera starts. The status it produces must map to
    /// the localizing phase; it used to fall through to .idle and the screen looked stuck.
    func testOpeningTheSavedScanShowsAsLocalizing() {
        let s = GuidanceSnapshot.derive(status: "Opening the saved scan...", instruction: "",
                                        obstacle: .clear, destinationLabel: "Room 442")
        XCTAssertEqual(s.phase, .localizing)
    }

    func testLookingForYourPositionStillLocalizes() {
        let s = GuidanceSnapshot.derive(status: "Looking for your position...", instruction: "",
                                        obstacle: .clear, destinationLabel: "Room 442")
        XCTAssertEqual(s.phase, .localizing)
    }

    /// A genuinely idle controller must still read as idle, not as loading forever.
    func testIdleIsStillIdle() {
        XCTAssertEqual(GuidanceSnapshot.derive(status: "Idle", instruction: "", obstacle: .clear,
                                               destinationLabel: "x").phase, .idle)
    }
}
