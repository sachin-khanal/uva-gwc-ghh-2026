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
        // Target is straight down -z. Facing +x (east): -z is on the user's LEFT.
        XCTAssertEqual(f.update(position: [0, 0, 0], forward: [1, 0, 0]).kind, .turnLeft)
        // Facing -x (west): -z is on the user's RIGHT.
        XCTAssertEqual(f.update(position: [0, 0, 0], forward: [-1, 0, 0]).kind, .turnRight)
        // Facing +z: target is behind.
        XCTAssertEqual(f.update(position: [0, 0, 0], forward: [0, 0, 1]).kind, .turnAround)
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
