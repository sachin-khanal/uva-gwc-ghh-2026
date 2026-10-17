//
// File:     Tests/WaypointCoreTests/RoutePlannerTests.swift
// Purpose:  Proves route memory is used as a default but never trusted blindly: blockages,
//           map changes and stairs preference force recomputation; signs can re-anchor the user.
//
import XCTest
import simd
@testable import WaypointCore

final class RoutePlannerTests: XCTestCase {

    // Short path A-B-D (4 m + 4 m) and a longer detour A-C-D (6 m + 6 m). C is labelled "Room 7".
    private func diamond() -> (BuildingMap, a: MapNode, b: MapNode, c: MapNode, d: MapNode) {
        let a = MapNode(kind: .room, label: "Room 1", position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [4, 0, 0])
        let c = MapNode(kind: .room, label: "Room 7", position: [4, 0, 6])
        let d = MapNode(kind: .room, label: "Room 2", position: [8, 0, 0])
        let map = BuildingMap(name: "diamond", nodes: [a, b, c, d], edges: [
            MapEdge(from: a.id, to: b.id, distance: 4), MapEdge(from: b.id, to: d.id, distance: 4),
            MapEdge(from: a.id, to: c.id, distance: 6), MapEdge(from: c.id, to: d.id, distance: 6),
        ])
        return (map, a, b, c, d)
    }

    func testSecondRequestComesFromMemoryAndIsShortest() {
        let (map, a, b, _, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        let first = p.plan(from: a.id, to: d.id)
        XCTAssertEqual(first?.source, .computed)
        XCTAssertEqual(first?.nodes.map(\.id), [a.id, b.id, d.id])
        let second = p.plan(from: a.id, to: d.id)
        XCTAssertEqual(second?.source, .memory)
        XCTAssertEqual(second?.nodes.map(\.id), [a.id, b.id, d.id])
        XCTAssertEqual(second?.totalDistance, 8)
        XCTAssertEqual(p.memory.entries.values.first?.uses, 2)
    }

    func testBlockageForcesDetourAndMemoryRecoversAfterExpiry() {
        let (map, a, b, c, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = p.plan(from: a.id, to: d.id, now: t0)                       // memorise A-B-D
        let detour = p.detour(around: (b.id, d.id), from: a.id, to: d.id, ttl: 60, now: t0)
        XCTAssertEqual(detour?.source, .detour)
        XCTAssertEqual(detour?.nodes.map(\.id), [a.id, c.id, d.id])
        // Detour must not overwrite the default memory.
        XCTAssertEqual(p.plan(from: a.id, to: d.id, now: t0.addingTimeInterval(30))?.nodes.map(\.id), [a.id, c.id, d.id])
        // After the TTL the blockage lapses and the remembered shortest route is back.
        let later = p.plan(from: a.id, to: d.id, now: t0.addingTimeInterval(61))
        XCTAssertEqual(later?.source, .memory)
        XCTAssertEqual(later?.nodes.map(\.id), [a.id, b.id, d.id])
    }

    func testFullyBlockedReturnsNil() {
        let (map, a, b, c, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        p.reportBlocked(b.id, d.id); p.reportBlocked(c.id, d.id)
        XCTAssertNil(p.plan(from: a.id, to: d.id))
        p.clearAllBlockages()
        XCTAssertNotNil(p.plan(from: a.id, to: d.id))
    }

    func testMapChangeInvalidatesMemory() {
        var (map, a, b, _, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        _ = p.plan(from: a.id, to: d.id)
        // A shortcut appears (e.g. a scan extension): memory must not keep serving the old route.
        map.edges.append(MapEdge(from: a.id, to: d.id, distance: 5))
        p.update(graph: WaypointGraph(map: map))
        let r = p.plan(from: a.id, to: d.id)
        XCTAssertEqual(r?.source, .computed)
        XCTAssertEqual(r?.nodes.map(\.id), [a.id, d.id])
        XCTAssertNotEqual(r?.nodes.map(\.id), [a.id, b.id, d.id])
    }

    func testStairsPreferenceIsPartOfTheKey() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [2, 0, 0])
        let c = MapNode(kind: .corridor, position: [1, 0, 4])
        let map = BuildingMap(name: "x", nodes: [a, b, c], edges: [
            MapEdge(from: a.id, to: b.id, distance: 2, hazard: .stairs),
            MapEdge(from: a.id, to: c.id, distance: 4), MapEdge(from: c.id, to: b.id, distance: 4)])
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        XCTAssertEqual(p.plan(from: a.id, to: b.id, allowStairs: false)?.nodes.count, 3)
        XCTAssertEqual(p.plan(from: a.id, to: b.id, allowStairs: true)?.nodes.count, 2)
        XCTAssertEqual(p.plan(from: a.id, to: b.id, allowStairs: false)?.nodes.count, 3)
    }

    func testMemoryRoundTripsThroughJSON() throws {
        let (map, a, _, _, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        _ = p.plan(from: a.id, to: d.id)
        let data = try JSONEncoder().encode(p.memory)
        let restored = RoutePlanner(graph: WaypointGraph(map: map), memory: try JSONDecoder().decode(RouteMemory.self, from: data))
        XCTAssertEqual(restored.plan(from: a.id, to: d.id)?.source, .memory)
    }

    func testWarmPrecomputesAllLabelledPairs() {
        let (map, _, _, _, _) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        XCTAssertEqual(p.warm(), 6)             // 3 labelled places -> 3*2 ordered pairs
        XCTAssertEqual(p.memory.entries.count, 6)
    }

    func testSignInterpretation() {
        let (map, _, _, c, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        XCTAssertEqual(p.interpretSign("Room 2", userPosition: [8.5, 0, 0.5]), .consistent(nodeId: d.id))
        XCTAssertEqual(p.interpretSign("7", userPosition: [8, 0, 0]), .relocate(nodeId: c.id))   // sign says 7, map thinks we are at Room 2
        XCTAssertEqual(p.interpretSign("999", userPosition: [0, 0, 0]), .unknown)
        XCTAssertEqual(p.interpretSign("", userPosition: [0, 0, 0]), .unknown)
    }

    func testSignWithDuplicateLabelIsAmbiguousUnlessOneIsNear() {
        let x = MapNode(kind: .room, label: "Room 3", position: [0, 0, 0])
        let y = MapNode(kind: .room, label: "Room 3", position: [50, 0, 0])
        let p = RoutePlanner(graph: WaypointGraph(map: BuildingMap(name: "dup", nodes: [x, y], edges: [])))
        XCTAssertEqual(p.interpretSign("3", userPosition: [25, 0, 0]), .ambiguous)
        XCTAssertEqual(p.interpretSign("3", userPosition: [1, 0, 0]), .consistent(nodeId: x.id))
    }

    func testRelocateThenReplanFromSignNode() {
        let (map, a, b, c, d) = diamond()
        let p = RoutePlanner(graph: WaypointGraph(map: map))
        // User believed to be at A, but reads "Room 7": re-anchor at C and plan to D.
        guard case .relocate(let at) = p.interpretSign("Room 7", userPosition: a.position) else { return XCTFail() }
        XCTAssertEqual(at, c.id)
        XCTAssertEqual(p.plan(from: at, to: d.id)?.nodes.map(\.id), [c.id, d.id])
        _ = b
    }
}

final class LiveAdaptationHelperTests: XCTestCase {
    func testOffRouteDistance() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [10, 0, 0])
        let route = [a, b]
        XCTAssertEqual(RoutePlanner.offRouteDistance(position: [5, 0, 3], route: route), 3, accuracy: 0.001)
        XCTAssertEqual(RoutePlanner.offRouteDistance(position: [13, 0, 4], route: route), 5, accuracy: 0.001) // beyond the end: distance to endpoint
        XCTAssertEqual(RoutePlanner.offRouteDistance(position: [3, 0, 4], route: [a]), 5, accuracy: 0.001)
        XCTAssertEqual(RoutePlanner.offRouteDistance(position: [0, 0, 0], route: []), .infinity)
    }

    func testBlockageTrackerNeedsSustainedStopAndFiresOnce() {
        var t = BlockageTracker(seconds: 4)
        XCTAssertFalse(t.update(level: .stop, time: 0))
        XCTAssertFalse(t.update(level: .stop, time: 3.9))
        XCTAssertTrue(t.update(level: .stop, time: 4.0))
        XCTAssertFalse(t.update(level: .stop, time: 6))          // already fired
        XCTAssertFalse(t.update(level: .clear, time: 7))         // person walked away: re-arm
        XCTAssertFalse(t.update(level: .stop, time: 8))
        XCTAssertTrue(t.update(level: .stop, time: 12))
    }

    func testBriefStopDoesNotFire() {
        var t = BlockageTracker(seconds: 4)
        XCTAssertFalse(t.update(level: .stop, time: 0))
        XCTAssertFalse(t.update(level: .caution, time: 2))
        XCTAssertFalse(t.update(level: .stop, time: 3))
        XCTAssertFalse(t.update(level: .stop, time: 6))          // only 3 s since re-start
    }
}

final class RouteMemoryStoreTests: XCTestCase {
    func testRouteMemoryPersistsPerMapAndIsNotInBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let map = try loadSampleMap()
        try store.save(map)

        XCTAssertTrue(store.loadRouteMemory(mapId: map.id).entries.isEmpty)       // nothing yet
        let planner = RoutePlanner(graph: WaypointGraph(map: map))
        planner.warm()
        try store.saveRouteMemory(planner.memory, mapId: map.id)

        let reloaded = RoutePlanner(graph: WaypointGraph(map: map), memory: store.loadRouteMemory(mapId: map.id))
        let a = try XCTUnwrap(map.destinations.first), b = try XCTUnwrap(map.destinations.last)
        XCTAssertEqual(reloaded.plan(from: a.id, to: b.id)?.source, .memory)

        let bundleJSON = String(decoding: try JSONEncoder().encode(try store.makeBundle(id: map.id)), as: UTF8.self)
        XCTAssertFalse(bundleJSON.contains("fingerprint"))                         // cache is never shared
    }

    func testCorruptOrMissingMemoryFileGivesEmptyMemoryAndUnknownMapThrows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let map = try loadSampleMap()
        try store.save(map)
        try Data("not json".utf8).write(to: store.directory(for: map.id).appendingPathComponent("route-memory.json"))
        XCTAssertTrue(store.loadRouteMemory(mapId: map.id).entries.isEmpty)
        XCTAssertThrowsError(try store.saveRouteMemory(RouteMemory(), mapId: UUID()))
    }
}
