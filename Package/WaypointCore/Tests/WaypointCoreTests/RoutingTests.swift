//
// File:     Tests/WaypointCoreTests/RoutingTests.swift
// Purpose:  Proves graph lookups, A* (including stairs avoidance), MapBuilder, and RouteFollower
//           bearings (left/right/behind) and arrival - the logic the blind user's safety rests on.
//
import XCTest
import simd
@testable import WaypointCore

final class RoutingTests: XCTestCase {

    private func id(_ suffix: String) -> UUID { UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000\(suffix)")! }

    func testLabelSearchIsFuzzy() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        XCTAssertEqual(graph.nodes(matchingLabel: "room204").first?.label, "Room 204")
        XCTAssertEqual(graph.nodes(matchingLabel: "204").first?.label, "Room 204")
        XCTAssertEqual(graph.nodes(matchingLabel: "ROOM 204").count, 1)
        XCTAssertTrue(graph.nodes(matchingLabel: "").isEmpty)
        XCTAssertTrue(graph.nodes(matchingLabel: "999").isEmpty)
    }

    func testNearestNode() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        XCTAssertEqual(graph.nearestNode(to: [0.1, 0, -8.7])?.id, id("A4"))
    }

    func testRouteToRoom204() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        let route = try XCTUnwrap(Router.route(in: graph, from: id("A1"), to: id("B1")))
        XCTAssertEqual(route.map(\.id), [id("A1"), id("A2"), id("A3"), id("A4"), id("B1")])
    }

    func testRouteSameNodeAndUnknownNode() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        XCTAssertEqual(Router.route(in: graph, from: id("A1"), to: id("A1"))?.count, 1)
        XCTAssertNil(Router.route(in: graph, from: id("A1"), to: UUID()))
    }

    func testUnreachableNodeReturnsNil() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [5, 0, 0])
        let graph = WaypointGraph(map: BuildingMap(name: "x", nodes: [a, b], edges: []))
        XCTAssertNil(Router.route(in: graph, from: a.id, to: b.id))
    }

    func testStairsAvoidedWhenAlternativeExists() {
        // A --(stairs, 2m)--> B   vs   A -> C -> B (4m + 4m). Without stairs allowed, go around.
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [2, 0, 0])
        let c = MapNode(kind: .corridor, position: [1, 0, 4])
        let map = BuildingMap(name: "x", nodes: [a, b, c], edges: [
            MapEdge(from: a.id, to: b.id, distance: 2, hazard: .stairs),
            MapEdge(from: a.id, to: c.id, distance: 4),
            MapEdge(from: c.id, to: b.id, distance: 4),
        ])
        let graph = WaypointGraph(map: map)
        XCTAssertEqual(Router.route(in: graph, from: a.id, to: b.id, allowStairs: false)?.count, 3)
        XCTAssertEqual(Router.route(in: graph, from: a.id, to: b.id, allowStairs: true)?.count, 2)
    }

    func testStairsStillUsedWhenOnlyWay() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [2, 0, 0])
        let graph = WaypointGraph(map: BuildingMap(name: "x", nodes: [a, b], edges: [
            MapEdge(from: a.id, to: b.id, distance: 2, hazard: .stairs)]))
        XCTAssertEqual(Router.route(in: graph, from: a.id, to: b.id)?.count, 2)
    }

    func testMapBuilderDropsBreadcrumbsAndPOIs() {
        let builder = MapBuilder(map: BuildingMap(name: "t"), deviceName: "test", breadcrumbSpacing: 1.5)
        XCTAssertNotNil(builder.observe(position: [0, 0, 0]))     // first node
        XCTAssertNil(builder.observe(position: [0, 0, -1.0]))     // too close
        XCTAssertNotNil(builder.observe(position: [0, 0, -1.6]))  // far enough
        let stairs = builder.addPOI(kind: .stairs, label: "Stairs", position: [0, 0, -2.6])
        XCTAssertNotNil(builder.observe(position: [0, 0, -3.3]))  // POI must not break the chain
        let m = builder.map
        XCTAssertEqual(m.nodes.count, 4)
        XCTAssertEqual(m.edges.count, 3)
        XCTAssertEqual(m.edges.first { $0.to == stairs.id }?.hazard, .stairs)
        // Chain continues from the last breadcrumb (index 1), not from the POI.
        XCTAssertTrue(m.edges.contains { $0.from == m.nodes[1].id && $0.to == m.nodes[3].id })
    }

    // MARK: RouteFollower

    private func straightRoute() -> (RouteFollower, [MapNode]) {
        let n = (0..<3).map { MapNode(kind: .corridor, position: [0, 0, Float(-3 * $0)]) }
        let edges = [MapEdge(from: n[0].id, to: n[1].id, distance: 3),
                     MapEdge(from: n[1].id, to: n[2].id, distance: 3, hazard: .stairs)]
        let graph = WaypointGraph(map: BuildingMap(name: "r", nodes: n, edges: edges))
        return (RouteFollower(route: n, graph: graph), n)
    }

    func testFollowerStraightAhead() {
        let (f, nodes) = straightRoute()
        let i = f.update(position: [0, 0, 0], forward: [0, 0, -1]) // facing -z, target at z=-3
        XCTAssertEqual(i.kind, .continueStraight)
        XCTAssertEqual(i.targetNodeId, nodes[1].id)
        XCTAssertEqual(i.distanceMeters, 3, accuracy: 1e-4)
    }

    func testFollowerLeftRightBehind() {
        let (f, _) = straightRoute()
        /// Cues are debounced now (HeadingCue): a CHANGE must persist for a few ticks before it is
        /// announced, which is what stopped "go left, go right, turn around" while walking straight
        /// down a corridor. This test spins the user on the spot between calls, so it has to hold each
        /// heading for a few ticks - a real user cannot rotate 180 degrees between two AR frames either.
        func settle(forward: SIMD3<Float>) -> GuidanceInstruction.Kind {
            var kind = GuidanceInstruction.Kind.continueStraight
            for _ in 0..<4 { kind = f.update(position: [0, 0, 0], forward: forward).kind }
            return kind
        }
        // Target is straight down -z. Facing +x (east): -z is on the user's LEFT.
        XCTAssertEqual(settle(forward: [1, 0, 0]), .turnLeft, "the first cue is immediate")
        // Facing -x (west): -z is on the user's RIGHT.
        XCTAssertEqual(settle(forward: [-1, 0, 0]), .turnRight)
        // Facing +z: target is behind.
        XCTAssertEqual(settle(forward: [0, 0, 1]), .turnAround)
    }

    func testFollowerAdvancesAndArrives() {
        let (f, nodes) = straightRoute()
        _ = f.update(position: [0, 0, 0], forward: [0, 0, -1])
        XCTAssertEqual(f.targetIndex, 1)
        let mid = f.update(position: [0, 0, -2.5], forward: [0, 0, -1]) // within 1 m of node 1
        XCTAssertEqual(mid.targetNodeId, nodes[2].id)
        XCTAssertEqual(mid.hazard, .stairs) // edge node1 -> node2 is stairs
        let end = f.update(position: [0, 0, -5.8], forward: [0, 0, -1])
        XCTAssertEqual(end.kind, .arrived)
    }

    // MARK: Geometry

    func testSignedBearingConvention() {
        XCTAssertEqual(Geometry.signedBearing(forward: [0, 0, -1], toTarget: [1, 0, 0]), .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(Geometry.signedBearing(forward: [0, 0, -1], toTarget: [-1, 0, 0]), -.pi / 2, accuracy: 1e-5)
        XCTAssertEqual(abs(Geometry.signedBearing(forward: [0, 0, -1], toTarget: [0, 0, 1])), .pi, accuracy: 1e-5)
        XCTAssertEqual(Geometry.signedBearing(forward: [0, 1, 0], toTarget: [1, 0, 0]), 0) // looking straight up
    }

    func testMarkerAlignmentRoundTrip() {
        // Marker surveyed at map (2,0,-5) rotated 90deg. ARKit later sees it at world (10,0,3) rotated 0.
        let marker = MarkerRef(name: "m", widthMeters: 0.2, position: [2, 0, -5], yaw: .pi / 2)
        let markerWorld = Geometry.translationMatrix([10, 0, 3])
        let mapToWorld = marker.mapToWorldTransform(markerWorld: markerWorld)
        // The marker's own position in the map frame must land exactly on its world position.
        let p = Geometry.transformPoint(mapToWorld, marker.position)
        XCTAssertEqual(p.x, 10, accuracy: 1e-4)
        XCTAssertEqual(p.y, 0, accuracy: 1e-4)
        XCTAssertEqual(p.z, 3, accuracy: 1e-4)
    }
}

// MARK: - Arrival wording and the start gate (device reports, 2026-10-17)

final class ArrivalAndStartGateTests: XCTestCase {

    // MARK: ArrivalSpeech - general over NodeKind, not special-cased to doors

    func testArrivalNamesThePlaceAndTheThingInFrontOfYou() {
        XCTAssertEqual(ArrivalSpeech.text(kind: .door, label: "Room 204"),
                       "You have arrived at Room 204. The door is right in front of you.")
        XCTAssertEqual(ArrivalSpeech.text(kind: .elevator, label: "North wing"),
                       "You have arrived at North wing. The elevator is right in front of you.")
        // "stairs" is plural: the verb has to agree or it reads as broken English.
        XCTAssertEqual(ArrivalSpeech.text(kind: .stairs, label: "Level 2"),
                       "You have arrived at Level 2. The stairs are right in front of you.")
    }

    func testArrivalWithoutALabelNamesTheFeature() {
        XCTAssertEqual(ArrivalSpeech.text(kind: .door, label: nil), "You have arrived at the door.")
        XCTAssertEqual(ArrivalSpeech.text(kind: .stairs, label: "  "), "You have arrived at the stairs.")
    }

    /// A room/corridor node is the place itself, so the label already says everything.
    func testArrivalAtAPlaceDoesNotInventAFeature() {
        XCTAssertEqual(ArrivalSpeech.text(kind: .room, label: "Room 204"), "You have arrived at Room 204.")
        XCTAssertEqual(ArrivalSpeech.text(kind: .junction, label: "Lobby"), "You have arrived at Lobby.")
        XCTAssertEqual(ArrivalSpeech.text(kind: nil, label: nil), "You have arrived.")
        XCTAssertEqual(ArrivalSpeech.text(kind: .room, label: nil), "You have arrived.")
    }

    // MARK: Arrival outranks the obstacle warning

    private func arrivedInstruction(kind: NodeKind, label: String?) -> GuidanceInstruction {
        GuidanceInstruction(kind: .arrived, bearingRadians: 0, distanceMeters: 0.4,
                            targetNodeId: UUID(), targetLabel: label,
                            targetPosition: .zero, hazard: nil, targetKind: kind)
    }

    private func spokenText(_ actions: [FeedbackAction]) -> [String] {
        actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
    }

    /// The bug: the door you walked to is within STOP range, so the obstacle branch spoke
    /// "Stop. You are about to walk into a door." and returned before arrival was ever announced.
    func testArrivalIsAnnouncedEvenWhenTheDestinationIsAtStopRange() {
        var planner = FeedbackPlanner()
        let actions = planner.plan(
            instruction: arrivedInstruction(kind: .door, label: "Room 204"),
            obstacle: .stop, trackingOK: true,
            report: ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.4, confidence: 0.9),
            time: 1)

        let said = spokenText(actions)
        XCTAssertEqual(said, ["You have arrived at Room 204. The door is right in front of you."])
        XCTAssertFalse(said.contains { $0.contains("walk into") }, "the destination must not be described as an obstacle")
        XCTAssertTrue(actions.contains { if case .haptic(.arrived) = $0 { return true } else { return false } })
        XCTAssertTrue(actions.contains { if case .beacon(nil) = $0 { return true } else { return false } },
                      "the beacon is muted once there is nothing left to steer toward")
    }

    func testArrivalIsSaidOnceNotOnEveryTick() {
        var planner = FeedbackPlanner()
        let i = arrivedInstruction(kind: .room, label: "Room 204")
        let first = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, time: 1)
        let second = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, time: 2)
        let third = planner.plan(instruction: i, obstacle: .stop, trackingOK: true, time: 9)

        XCTAssertEqual(spokenText(first), ["You have arrived at Room 204."])
        XCTAssertTrue(spokenText(second).isEmpty, "no repeat")
        XCTAssertTrue(spokenText(third).isEmpty, "and no repeat once the stop-repeat timer would have fired")
    }

    /// Before arrival the obstacle warning must still work exactly as it did.
    func testObstacleWarningIsUnchangedWhileStillWalking() {
        var planner = FeedbackPlanner()
        let walking = GuidanceInstruction(kind: .continueStraight, bearingRadians: 0, distanceMeters: 8,
                                          targetNodeId: UUID(), targetLabel: nil, targetPosition: .zero,
                                          hazard: nil, targetKind: .corridor)
        let actions = planner.plan(instruction: walking, obstacle: .stop, trackingOK: true,
                                   report: ObstacleReport(kind: .wall, side: .ahead, distanceMeters: 0.5, confidence: 0.9),
                                   time: 1)
        XCTAssertTrue(spokenText(actions).contains { $0.hasPrefix("Stop.") })
    }

    // MARK: StartGate

    func testGateWaitsForThePoseToStopJumping() {
        var gate = StartGate(requiredStableTicks: 3, maxJumpMeters: 0.35)
        // Relocalization converging: large jumps, so the gate never opens.
        XCTAssertFalse(gate.update(position: SIMD3(0, 0, 0), trackingOK: true))
        XCTAssertFalse(gate.update(position: SIMD3(4, 0, 0), trackingOK: true))
        XCTAssertFalse(gate.update(position: SIMD3(0.5, 0, -3), trackingOK: true))
        // Settled: three consecutive small moves.
        XCTAssertFalse(gate.update(position: SIMD3(9, 0, -9), trackingOK: true))
        XCTAssertFalse(gate.update(position: SIMD3(9.1, 0, -9), trackingOK: true))
        XCTAssertTrue(gate.update(position: SIMD3(9.2, 0, -9), trackingOK: true))
    }

    func testLostTrackingRestartsTheCount() {
        var gate = StartGate(requiredStableTicks: 2, maxJumpMeters: 0.35)
        XCTAssertFalse(gate.update(position: SIMD3(1, 0, 1), trackingOK: true))
        XCTAssertFalse(gate.update(position: SIMD3(1, 0, 1), trackingOK: false), "tracking lost")
        XCTAssertFalse(gate.update(position: SIMD3(1, 0, 1), trackingOK: true), "count starts again")
        XCTAssertTrue(gate.update(position: SIMD3(1.05, 0, 1), trackingOK: true))
    }

    func testGateRejectsNonFinitePositions() {
        var gate = StartGate(requiredStableTicks: 1, maxJumpMeters: 0.35)
        XCTAssertFalse(gate.update(position: SIMD3(.nan, 0, 0), trackingOK: true))
        XCTAssertTrue(gate.update(position: SIMD3(1, 0, 1), trackingOK: true))
    }

    /// The point of the gate: routing from the FIRST pose picks the node nearest the scan origin,
    /// routing from the SETTLED pose picks the node the user is actually standing on.
    func testGateChangesWhichNodeTheRouteStartsFrom() throws {
        let origin = MapNode(kind: .corridor, position: SIMD3(0, 0, 0))
        let middle = MapNode(kind: .corridor, position: SIMD3(0, 0, -5))
        let far = MapNode(kind: .corridor, position: SIMD3(0, 0, -10))
        let room = MapNode(kind: .room, label: "Room 204", position: SIMD3(2, 0, -10))
        let map = BuildingMap(name: "t", nodes: [origin, middle, far, room], edges: [
            MapEdge(from: origin.id, to: middle.id, distance: 5),
            MapEdge(from: middle.id, to: far.id, distance: 5),
            MapEdge(from: far.id, to: room.id, distance: 2),
        ])
        let graph = WaypointGraph(map: map)

        // The user really stands next to `far`, but the first converging pose reads as the origin.
        let converging = SIMD3<Float>(0.1, 0, -0.2)
        let settled = SIMD3<Float>(0.1, 0, -9.8)

        let fromConverging = try XCTUnwrap(graph.nearestNode(to: converging))
        let fromSettled = try XCTUnwrap(graph.nearestNode(to: settled))
        XCTAssertEqual(fromConverging.id, origin.id, "this is the wrong start that the gate prevents")
        XCTAssertEqual(fromSettled.id, far.id)

        let badRoute = try XCTUnwrap(Router.route(in: graph, from: fromConverging.id, to: room.id))
        let goodRoute = try XCTUnwrap(Router.route(in: graph, from: fromSettled.id, to: room.id))
        XCTAssertEqual(badRoute.count, 4, "walks back to the start of the scan first")
        XCTAssertEqual(goodRoute.count, 2, "goes straight to the destination")
    }
}

// MARK: - Natural path following, loop closure, doors and turn angles (device reports, 2026-10-17)

final class NaturalGuidanceTests: XCTestCase {

    // MARK: HeadingCue - "it kept saying go left, go right, turn around"

    func testSmallWobbleWhileWalkingStraightNeverProducesATurn() {
        var cue = HeadingCue()
        _ = cue.update(bearing: 0)
        // +-20 degrees of drift, the sort of thing half a step sideways produces.
        for degrees in [8, -12, 15, -18, 5, -20, 19, -6] {
            XCTAssertEqual(cue.update(bearing: Float(degrees) * .pi / 180), .continueStraight,
                           "\(degrees) degrees off-course is normal walking, not a turn")
        }
    }

    func testARealTurnIsAnnouncedOnceItPersists() {
        var cue = HeadingCue(enterDegrees: 45, exitDegrees: 22, turnAroundDegrees: 150, requiredTicks: 3)
        _ = cue.update(bearing: 0)
        let sixty: Float = 60 * .pi / 180
        XCTAssertEqual(cue.update(bearing: sixty), .continueStraight, "not yet - could be a wobble")
        XCTAssertEqual(cue.update(bearing: sixty), .continueStraight)
        XCTAssertEqual(cue.update(bearing: sixty), .turnRight, "held long enough to be real")
    }

    /// Hysteresis: once turning, we do not flip back to "straight" the moment the angle dips.
    func testTurnDoesNotFlutterBackToStraight() {
        var cue = HeadingCue(enterDegrees: 45, exitDegrees: 22, turnAroundDegrees: 150, requiredTicks: 3)
        _ = cue.update(bearing: 60 * .pi / 180) // first cue is immediate
        XCTAssertEqual(cue.update(bearing: 30 * .pi / 180), .turnRight, "30 is below enter but above exit")
        for _ in 0..<3 { _ = cue.update(bearing: 10 * .pi / 180) }
        XCTAssertEqual(cue.update(bearing: 10 * .pi / 180), .continueStraight, "comfortably back on course")
    }

    func testFirstCueIsImmediateSoAUserFacingTheWrongWayIsToldAtOnce() {
        var cue = HeadingCue()
        XCTAssertEqual(cue.update(bearing: .pi), .turnAround)
    }

    // MARK: Steering point - follow the corridor, not the exact line the volunteer walked

    func testSteeringAimsFurtherAheadThanTheNextBreadcrumb() {
        let nodes = (0..<8).map { MapNode(kind: .corridor, position: SIMD3(0, 0, Float($0) * -1.5)) }
        var edges: [MapEdge] = []
        for i in 0..<(nodes.count - 1) { edges.append(MapEdge(from: nodes[i].id, to: nodes[i + 1].id, distance: 1.5)) }
        let map = BuildingMap(name: "corridor", nodes: nodes, edges: edges)
        let follower = RouteFollower(route: nodes, graph: WaypointGraph(map: map))

        let aim = follower.steeringPoint(from: SIMD3(0, 0, 0), distanceToTarget: 0)
        XCTAssertLessThanOrEqual(aim.z, -3.0, "aims at least the lookahead distance down the corridor")
        XCTAssertNotEqual(aim.z, -1.5, "not just the next breadcrumb")
    }

    func testSteeringFallsBackToTheDestinationAtTheEndOfTheRoute() {
        let a = MapNode(kind: .corridor, position: SIMD3(0, 0, 0))
        let b = MapNode(kind: .room, label: "Room 204", position: SIMD3(0, 0, -1))
        let map = BuildingMap(name: "t", nodes: [a, b], edges: [MapEdge(from: a.id, to: b.id, distance: 1)])
        let follower = RouteFollower(route: [a, b], graph: WaypointGraph(map: map))
        XCTAssertEqual(follower.steeringPoint(from: SIMD3(0, 0, 0), distanceToTarget: 1).z, -1, accuracy: 1e-4)
    }

    // MARK: Arrival radius depends on what the destination is

    func testArrivalRadiusIsLargerForARoomThanADoor() {
        XCTAssertGreaterThan(ArrivalRadius.meters(for: .room), ArrivalRadius.meters(for: .door))
        XCTAssertEqual(ArrivalRadius.meters(for: .door), 1.2, accuracy: 1e-5)
        XCTAssertEqual(ArrivalRadius.meters(for: nil), 1.0, accuracy: 1e-5)
    }

    func testYouArriveAtARoomFromFurtherAwayThanADoor() {
        func arrives(kind: NodeKind, at distance: Float) -> Bool {
            let a = MapNode(kind: .corridor, position: SIMD3(0, 0, 0))
            let b = MapNode(kind: kind, label: "X", position: SIMD3(0, 0, -10))
            let map = BuildingMap(name: "t", nodes: [a, b], edges: [MapEdge(from: a.id, to: b.id, distance: 10)])
            let f = RouteFollower(route: [a, b], graph: WaypointGraph(map: map))
            // Walk from the start so the follower advances past `a`; it only tests arrival once the
            // destination is the current target.
            _ = f.update(position: SIMD3(0, 0, 0), forward: SIMD3(0, 0, -1))
            return f.update(position: SIMD3(0, 0, -10 + distance), forward: SIMD3(0, 0, -1)).kind == .arrived
        }
        XCTAssertTrue(arrives(kind: .room, at: 2.0), "2 m inside a room counts as arrived")
        XCTAssertFalse(arrives(kind: .door, at: 2.0), "2 m from a door does not")
        XCTAssertTrue(arrives(kind: .door, at: 1.0))
    }

    // MARK: Loop closure - "it made me walk around the whole room"

    func testWalkingBackToAnEarlierSpotClosesTheLoop() throws {
        let builder = MapBuilder(map: BuildingMap(name: "core"), deviceName: "test")
        // A square loop around a central core, 2 m spacing, back to the start.
        builder.breadcrumbSpacing = 2
        var path: [SIMD3<Float>] = []
        for i in 0...4 { path.append(SIMD3(Float(i) * 2, 0, 0)) }
        for i in 1...4 { path.append(SIMD3(8, 0, Float(i) * -2)) }
        for i in 1...4 { path.append(SIMD3(8 - Float(i) * 2, 0, -8)) }
        for i in 1...4 { path.append(SIMD3(0, 0, -8 + Float(i) * 2)) }
        for p in path { builder.observe(position: p) }

        let map = builder.map
        let graph = WaypointGraph(map: map)
        let start = try XCTUnwrap(map.nodes.first)
        let last = try XCTUnwrap(map.nodes.last)
        let route = try XCTUnwrap(Router.route(in: graph, from: start.id, to: last.id))
        XCTAssertLessThanOrEqual(route.count, 3,
                                 "the walker came back to the start, so the ends must be joined, not routed all the way round")
    }

    /// The safety side of loop closure: two corridors either side of a thin wall are close in space,
    /// and joining them would route a blind user into the wall. Only an actual revisit may add an edge,
    /// so walking two parallel corridors must leave the graph a pure chain (no extra edges).
    func testParallelCorridorsAreNotJoinedThroughTheWall() {
        let builder = MapBuilder(map: BuildingMap(name: "parallel"), deviceName: "test")
        builder.breadcrumbSpacing = 2 // default revisitRadius: this is the shipped behaviour
        for i in 0...5 { builder.observe(position: SIMD3(Float(i) * 2, 0, 0)) }
        for i in stride(from: 5, through: 0, by: -1) { builder.observe(position: SIMD3(Float(i) * 2, 0, -1.5)) }

        XCTAssertEqual(builder.map.edges.count, builder.map.nodes.count - 1,
                       "a pure chain: the only edges are the ones the volunteer actually walked")
    }

    // MARK: A door on your route is the way IN, not an obstacle

    func testDoorOfTheDestinationRoomIsTreatedAsTheWayThrough() {
        XCTAssertTrue(RouteFeature.isWayThrough(obstacle: .door, target: .room))
        XCTAssertTrue(RouteFeature.isWayThrough(obstacle: .door, target: .door))
        XCTAssertTrue(RouteFeature.isWayThrough(obstacle: .stairs, target: .stairs))
        XCTAssertFalse(RouteFeature.isWayThrough(obstacle: .wall, target: .room), "a wall is never the way in")
        XCTAssertFalse(RouteFeature.isWayThrough(obstacle: .person, target: .door))
        XCTAssertFalse(RouteFeature.isWayThrough(obstacle: .stairs, target: .room), "stairs we did not route to")
    }

    func testDoorAheadSaysToOpenItAndKeepsGuiding() {
        var planner = FeedbackPlanner()
        let approaching = GuidanceInstruction(
            kind: .continueStraight, bearingRadians: 0, distanceMeters: 1.6,
            targetNodeId: UUID(), targetLabel: "Room 204", targetPosition: SIMD3(0, 0, -1.6),
            hazard: nil, targetKind: .room)
        let actions = planner.plan(instruction: approaching, obstacle: .stop, trackingOK: true,
                                   report: ObstacleReport(kind: .door, side: .ahead, distanceMeters: 0.5, confidence: 0.9),
                                   time: 1)
        let said = actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
        XCTAssertTrue(said.contains { $0.contains("open it") }, "it must say the door has to be opened: \(said)")
        XCTAssertFalse(said.contains { $0.contains("walk into") })
        XCTAssertTrue(actions.contains { if case .beacon(.some) = $0 { return true } else { return false } },
                      "guidance continues toward the door rather than stopping dead")
    }

    func testARealObstacleStillStopsTheUser() {
        var planner = FeedbackPlanner()
        let approaching = GuidanceInstruction(
            kind: .continueStraight, bearingRadians: 0, distanceMeters: 5,
            targetNodeId: UUID(), targetLabel: "Room 204", targetPosition: SIMD3(0, 0, -5),
            hazard: nil, targetKind: .room)
        let actions = planner.plan(instruction: approaching, obstacle: .stop, trackingOK: true,
                                   report: ObstacleReport(kind: .person, side: .ahead, distanceMeters: 0.5, confidence: 0.9),
                                   time: 1)
        let said = actions.compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
        XCTAssertTrue(said.contains { $0.hasPrefix("Stop.") })
        XCTAssertTrue(actions.contains { if case .beacon(nil) = $0 { return true } else { return false } })
    }

    // MARK: Turn cues carry an angle, and come one at a time

    func testTurnCuesIncludeARoundedAngle() {
        XCTAssertEqual(TurnSpeech.text(kind: .turnRight, bearingRadians: 47 * .pi / 180), "Turn right 45 degrees.")
        XCTAssertEqual(TurnSpeech.text(kind: .turnLeft, bearingRadians: -63 * .pi / 180), "Turn left 65 degrees.")
        XCTAssertEqual(TurnSpeech.text(kind: .turnAround, bearingRadians: .pi), "Turn around.")
        XCTAssertNil(TurnSpeech.text(kind: .arrived, bearingRadians: 0))
    }

    func testAnglesAreRoundedNotFalselyPrecise() {
        XCTAssertEqual(TurnSpeech.rounded(degrees: 47), 45)
        XCTAssertEqual(TurnSpeech.rounded(degrees: 48), 50)
        XCTAssertEqual(TurnSpeech.rounded(degrees: 1), 5, "never announce a zero-degree turn")
    }

    func testDirectionsAreSpacedOutSoTheUserIsNotOverwhelmed() {
        var planner = FeedbackPlanner()
        func cue(_ kind: GuidanceInstruction.Kind, at time: TimeInterval) -> [String] {
            let i = GuidanceInstruction(kind: kind, bearingRadians: 0.9, distanceMeters: 5,
                                        targetNodeId: UUID(), targetLabel: nil, targetPosition: SIMD3(0, 0, -5),
                                        hazard: nil, targetKind: .corridor)
            return planner.plan(instruction: i, obstacle: .clear, trackingOK: true, time: time)
                .compactMap { if case .speak(let t, _) = $0 { return t } else { return nil } }
        }
        XCTAssertFalse(cue(.turnRight, at: 10).isEmpty, "first direction is spoken")
        XCTAssertTrue(cue(.turnLeft, at: 10.3).isEmpty, "a second direction 0.3 s later is held back")
        XCTAssertTrue(cue(.turnLeft, at: 11.0).isEmpty, "still inside the cooldown")
        XCTAssertFalse(cue(.turnLeft, at: 12.0).isEmpty, "announced once the cooldown has passed, not dropped")
    }
}
