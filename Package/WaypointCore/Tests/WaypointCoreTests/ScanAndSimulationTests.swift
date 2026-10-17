//
// File:     Tests/WaypointCoreTests/ScanAndSimulationTests.swift
// Purpose:  Proves the scan bounding-box math, the export size budget, the camera-transform helper,
//           and - most importantly - an END-TO-END walk: a virtual walker follows the sample route
//           through RouteFollower + FeedbackPlanner and must produce sensible spoken/haptic cues and
//           finish with "arrived". This is the closest thing to a navigation test we can run without a phone.
//
import XCTest
import simd
@testable import WaypointCore

final class ScanAndSimulationTests: XCTestCase {

    // MARK: OrientedBox

    /// Points on the corners/edges of a 10 m x 2 m x 2.5 m hallway rotated by `yaw` and moved to `origin`.
    private func hallwayPoints(yaw: Float, origin: SIMD3<Float>) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for x: Float in [0, 2] { for y: Float in [0, 2.5] { for z: Float in stride(from: 0, through: 10, by: 1) {
            pts.append(origin + OrientedBox.rotateY(SIMD3<Float>(x, y, z), by: yaw))
        } } }
        return pts
    }

    func testFitBestRecoversRotatedHallway() throws {
        let yaw: Float = 30 * .pi / 180
        let pts = hallwayPoints(yaw: yaw, origin: [3, 0, -4])
        let box = try XCTUnwrap(OrientedBox.fitBest(points: pts, yawStepDegrees: 5))
        let dims = [box.size.x, box.size.z].sorted()
        XCTAssertEqual(dims[0], 2, accuracy: 0.05)
        XCTAssertEqual(dims[1], 10, accuracy: 0.05)
        XCTAssertEqual(box.size.y, 2.5, accuracy: 1e-4)
        XCTAssertTrue(pts.allSatisfy { box.contains($0) }, "box must contain every point")
        // An axis-aligned fit of the same points is much bigger, so the yaw search really helped.
        let naive = try XCTUnwrap(OrientedBox.fit(points: pts, yaw: 0))
        XCTAssertGreaterThan(naive.floorArea, box.floorArea * 1.5)
    }

    func testBoxContainsCornersExpandedAndEmpty() throws {
        let box = OrientedBox(center: [1, 1, 1], halfExtents: [1, 0.5, 2], yaw: .pi / 6)
        XCTAssertEqual(box.corners().count, 8)
        XCTAssertTrue(box.corners().allSatisfy { box.contains($0) })
        XCTAssertTrue(box.contains([1, 1, 1]))
        XCTAssertFalse(box.contains([10, 1, 1]))
        XCTAssertEqual(box.volume, 2 * 1 * 4, accuracy: 1e-5)

        let bigger = box.expanded(by: 0.5)
        XCTAssertEqual(bigger.halfExtents, [1.5, 1.0, 2.5])
        XCTAssertTrue(box.corners().allSatisfy { bigger.contains($0) })
        XCTAssertEqual(box.expanded(by: -5).halfExtents, SIMD3<Float>(repeating: 0.01)) // clamped, never inverted

        XCTAssertNil(OrientedBox.fit(points: [], yaw: 0))
        XCTAssertNil(OrientedBox.fitBest(points: []))
        XCTAssertEqual(OrientedBox.edgeIndices.count, 12)
    }

    // MARK: ExportBudget

    func testExportBudget() {
        XCTAssertEqual(ExportBudget.keepFraction(vertices: 1_000, triangles: 2_000), 1)
        // 4M vertices + 8M triangles ~ 192 MB -> must keep roughly a fifth to fit 40 MB.
        let f = ExportBudget.keepFraction(vertices: 4_000_000, triangles: 8_000_000)
        XCTAssertLessThan(f, 0.25)
        XCTAssertGreaterThan(f, 0.15)
        let kept = ExportBudget.estimatedBytes(vertices: Int(Float(4_000_000) * f), triangles: Int(Float(8_000_000) * f))
        XCTAssertLessThanOrEqual(kept, ExportBudget.defaultBudgetBytes + 100_000)
        XCTAssertLessThan(ExportBudget.defaultBudgetBytes, ExportBudget.supabaseFreeTierFileLimit)
        XCTAssertEqual(ExportBudget.keepFraction(vertices: 100_000_000, triangles: 200_000_000), 0.05) // floor
    }

    // MARK: cameraTransform

    func testCameraTransformMatchesARKitPortraitConvention() {
        let t = Geometry.cameraTransform(position: [2, 1.5, -3], forward: [1, 0.7, 0]) // pitch comes only from the pitch argument
        XCTAssertEqual(Geometry.translation(of: t), [2, 1.5, -3])
        let f = Geometry.cameraForward(of: t)
        XCTAssertEqual(f.x, 1, accuracy: 1e-5); XCTAssertEqual(f.y, 0, accuracy: 1e-5); XCTAssertEqual(f.z, 0, accuracy: 1e-5)
        // A point 3 m ahead and 1 m to the user's right (facing +x, so right is +z). In ARKit's sensor-fixed camera frame for an upright phone
        // that is local (x = 0 [no height difference], y = +1 [camera +y = the user's right], z = -3 [looking along -z]).
        let world = SIMD3<Float>(2 + 3, 1.5, -3 + 1)
        let local = Geometry.transformPoint(t.inverse, world)
        XCTAssertEqual(local.x, 0, accuracy: 1e-4)
        XCTAssertEqual(local.y, 1, accuracy: 1e-4)
        XCTAssertEqual(local.z, -3, accuracy: 1e-4)
        // Converted to the user frame (x right, y up, ahead = -z) the audio engine needs:
        let user = Geometry.cameraLocalToUser(local)
        XCTAssertEqual(user.x, 1, accuracy: 1e-4); XCTAssertEqual(user.y, 0, accuracy: 1e-4); XCTAssertEqual(user.z, -3, accuracy: 1e-4)
        // A point 1 m ABOVE the phone is local x = -1 (camera +x points toward the bottom of the phone) -> user y = +1.
        let above = Geometry.cameraLocalToUser(Geometry.transformPoint(t.inverse, SIMD3<Float>(2 + 3, 2.5, -3)))
        XCTAssertEqual(above.y, 1, accuracy: 1e-4)
        // Degenerate forward falls back to -z.
        XCTAssertEqual(Geometry.cameraForward(of: Geometry.cameraTransform(position: .zero, forward: [0, 1, 0])).z, -1, accuracy: 1e-5)
    }

    // MARK: PoseSimulator

    func testSimulatorFollowsRouteAndFinishes() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        let route = try XCTUnwrap(Router.route(in: graph, from: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000A1")!,
                                               to: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000B1")!))
        var sim = PoseSimulator(route: route)
        var steps = 0
        while !sim.isFinished && steps < 5_000 { sim.step(dt: 0.1); steps += 1 }
        XCTAssertTrue(sim.isFinished)
        XCTAssertLessThan(steps, 400) // ~11 m at 1.2 m/s plus a turn
        XCTAssertEqual(simd_distance(sim.position, route.last!.position), 0, accuracy: 0.06)
    }

    /// Walks the whole sample route and records what the feedback layer would say/feel.
    func testEndToEndWalkProducesExpectedCues() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        let route = try XCTUnwrap(Router.route(in: graph, from: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000A1")!,
                                               to: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000B1")!))
        var sim = PoseSimulator(route: route)
        let follower = RouteFollower(route: route, graph: graph)
        var planner = FeedbackPlanner()
        var spoken: [String] = []
        var haptics: [HapticCue] = []
        var beaconSamples = 0

        var guardCounter = 0
        while guardCounter < 2_000 {
            guardCounter += 1
            let instruction = follower.update(position: sim.position, forward: sim.forward)
            for action in planner.plan(instruction: instruction, obstacle: .clear, trackingOK: true) {
                switch action {
                case .speak(let text, _): spoken.append(text)
                case .haptic(let cue): haptics.append(cue)
                case .beacon(let target): if target != nil { beaconSamples += 1 }
                }
            }
            if instruction.kind == .arrived { break }
            sim.step(dt: 0.1)
        }

        XCTAssertEqual(spoken.last, "You have arrived at Room 204.")
        XCTAssertEqual(spoken.filter { $0.hasPrefix("You have arrived") }.count, 1, "arrival announced exactly once")
        XCTAssertTrue(spoken.contains { $0.hasPrefix("Right") || $0.hasPrefix("Slightly right") },
                      "the last leg into Room 204 is a right turn: \(spoken)")
        XCTAssertTrue(haptics.contains(.turnRight))
        XCTAssertEqual(haptics.last, .arrived)
        XCTAssertGreaterThan(beaconSamples, 20, "the beacon follows the walker the whole way")
        XCTAssertFalse(spoken.contains("Turn around."))
        // No repeated-announcement spam: far fewer utterances than ticks.
        XCTAssertLessThan(spoken.count, 12)
    }

    func testSimulatorWalkerStartingBackwardsGetsTurnAround() throws {
        let graph = WaypointGraph(map: try loadSampleMap())
        let route = try XCTUnwrap(Router.route(in: graph, from: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000A1")!,
                                               to: UUID(uuidString: "5A3E0000-0000-4000-8000-0000000000A5")!))
        let sim = PoseSimulator(route: route, startFacing: [0, 0, 1]) // facing away from the route
        let follower = RouteFollower(route: route, graph: graph)
        XCTAssertEqual(follower.update(position: sim.position, forward: sim.forward).kind, .turnAround)
    }
}

// MARK: Fast, exact bounding box (convex hull) - added when the live scan lagged

final class FastBoxFitTests: XCTestCase {

    /// Deterministic pseudo-random numbers so a failure can be reproduced.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    func testHullOfSquareWithInteriorAndCollinearPoints() {
        var pts: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 4], [0, 4], [2, 0], [4, 2], [2, 2], [1, 1], [3, 3], [0, 0]]
        var shuffler = LCG(state: 7)
        pts.shuffle(using: &shuffler)
        let hull = ConvexHull2D.hull(pts)
        XCTAssertEqual(Set(hull.map { "\($0.x),\($0.y)" }), ["0.0,0.0", "4.0,0.0", "4.0,4.0", "0.0,4.0"])
        XCTAssertEqual(ConvexHull2D.hull([[1, 1], [2, 2]]).count, 2)
        XCTAssertTrue(ConvexHull2D.hull([]).isEmpty)
    }

    /// THE lossless guarantee: the hull-based fit equals the brute-force fit over every point, on many random clouds.
    func testHullFitEqualsBruteForceOnRandomClouds() throws {
        var rng = LCG(state: 42)
        for trial in 0..<60 {
            let yaw = Float.random(in: 0..<Float.pi, using: &rng)
            let w = Float.random(in: 1...20, using: &rng), d = Float.random(in: 1...40, using: &rng)
            let n = Int.random(in: 20...2_000, using: &rng)
            let origin = SIMD3<Float>(Float.random(in: -50...50, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -50...50, using: &rng))
            let pts: [SIMD3<Float>] = (0..<n).map { _ in
                let local = SIMD3<Float>(Float.random(in: 0...w, using: &rng), Float.random(in: 0...3, using: &rng), Float.random(in: 0...d, using: &rng))
                return origin + OrientedBox.rotateY(local, by: yaw)
            }
            let fast = try XCTUnwrap(OrientedBox.fitBest(points: pts))
            let slow = try XCTUnwrap(OrientedBox.fitBestBruteForce(points: pts))
            XCTAssertEqual(fast.yaw, slow.yaw, accuracy: 1e-6, "trial \(trial): yaw")
            for i in 0..<3 {
                XCTAssertEqual(fast.center[i], slow.center[i], accuracy: 1e-3, "trial \(trial): center \(i)")
                XCTAssertEqual(fast.halfExtents[i], slow.halfExtents[i], accuracy: 1e-3, "trial \(trial): extents \(i)")
            }
            XCTAssertTrue(pts.allSatisfy { fast.contains($0, slack: 1e-3) }, "trial \(trial): box must contain every point")
        }
    }

    /// Per-anchor hulls merged together equal the hull of everything (how the app streams the mesh).
    func testMergedPerAnchorHullsEqualWholeCloud() throws {
        var rng = LCG(state: 9)
        let cloud: [SIMD3<Float>] = (0..<6_000).map { _ in
            SIMD3<Float>(Float.random(in: -10...10, using: &rng), Float.random(in: 0...3, using: &rng), Float.random(in: -30...30, using: &rng))
        }
        let chunks = stride(from: 0, to: cloud.count, by: 500).map { Array(cloud[$0..<min($0 + 500, cloud.count)]) }
        var merged: [SIMD2<Float>] = []
        var minY = Float.infinity, maxY = -Float.infinity
        for chunk in chunks {
            merged += ConvexHull2D.hull(chunk.map { SIMD2($0.x, $0.z) })
            minY = min(minY, chunk.map(\.y).min()!); maxY = max(maxY, chunk.map(\.y).max()!)
        }
        let viaChunks = try XCTUnwrap(OrientedBox.fitBest(hull: ConvexHull2D.hull(merged), minY: minY, maxY: maxY))
        let direct = try XCTUnwrap(OrientedBox.fitBest(points: cloud))
        XCTAssertEqual(viaChunks.size.x, direct.size.x, accuracy: 1e-4)
        XCTAssertEqual(viaChunks.size.z, direct.size.z, accuracy: 1e-4)
        XCTAssertEqual(viaChunks.yaw, direct.yaw, accuracy: 1e-6)
    }

    func testFastFitIsMuchFasterOnAHugeCloud() throws {
        var rng = LCG(state: 3)
        let cloud: [SIMD3<Float>] = (0..<300_000).map { _ in
            SIMD3<Float>(Float.random(in: 0...12, using: &rng), Float.random(in: 0...3, using: &rng), Float.random(in: 0...60, using: &rng))
        }
        let t0 = Date(); _ = OrientedBox.fitBestBruteForce(points: cloud); let slow = Date().timeIntervalSince(t0)
        let t1 = Date(); _ = OrientedBox.fitBest(points: cloud); let fast = Date().timeIntervalSince(t1)
        print("box fit, 300k points: brute force \(Int(slow * 1000)) ms, hull \(Int(fast * 1000)) ms")
        XCTAssertLessThan(fast, slow, "hull fit should beat brute force")
    }
}

// MARK: - Room extents: knowing you are INSIDE a room (device report, 2026-10-17)

final class RoomExtractorTests: XCTestCase {

    /// Wall points around a rectangular room, with an optional gap for a doorway.
    private func walls(width: Float, depth: Float, origin: SIMD2<Float> = .zero,
                       doorGap: ClosedRange<Float>? = nil, step: Float = 0.05) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        var x = origin.x
        while x <= origin.x + width {
            points.append(SIMD2(x, origin.y))
            points.append(SIMD2(x, origin.y + depth))
            x += step
        }
        var z = origin.y
        while z <= origin.y + depth {
            if let gap = doorGap, gap.contains(z) { z += step; continue } // doorway in the left wall
            points.append(SIMD2(origin.x, z))
            points.append(SIMD2(origin.x + width, z))
            z += step
        }
        return points
    }

    func testFindsARectangularRoomAndItsArea() throws {
        let result = try XCTUnwrap(RoomExtractor.extract(
            seed: SIMD3(2, 0, 2), wallPoints: walls(width: 4, depth: 5)))
        XCTAssertEqual(result.extent.halfExtents.x, 2, accuracy: 0.25)
        XCTAssertEqual(result.extent.halfExtents.y, 2.5, accuracy: 0.25)
        XCTAssertEqual(result.areaSquareMeters, 20, accuracy: 3, "4 x 5 m of floor")
        XCTAssertEqual(result.extent.center.x, 2, accuracy: 0.3)
        XCTAssertEqual(result.extent.center.z, 2.5, accuracy: 0.3)
    }

    func testStandingInsideCountsAsInsideAndOutsideDoesNot() throws {
        let result = try XCTUnwrap(RoomExtractor.extract(
            seed: SIMD3(2, 0, 2), wallPoints: walls(width: 4, depth: 5)))
        let extent = result.extent
        XCTAssertTrue(extent.contains(SIMD3(2, 0, 2.5)), "the middle of the room")
        XCTAssertTrue(extent.contains(SIMD3(0.4, 0, 0.4)), "a corner, still inside")
        XCTAssertFalse(extent.contains(SIMD3(2, 0, 9)), "well down the corridor outside")
        XCTAssertFalse(extent.contains(SIMD3(-3, 0, 2.5)))
    }

    /// The whole point: arrival is now containment, so you are "there" anywhere in the room, and the
    /// far corner counts just as much as the spot the volunteer happened to stand on.
    func testArrivalUsesTheRoomExtentNotTheDistanceToThePin() throws {
        let corridor = MapNode(kind: .corridor, position: SIMD3(2, 0, -4))
        let extracted = try XCTUnwrap(RoomExtractor.extract(seed: SIMD3(2, 0, 2),
                                                            wallPoints: walls(width: 4, depth: 5)))
        // The pin sits at one end of the room; the user walks in at the other.
        let room = MapNode(kind: .room, label: "Room 204", position: SIMD3(2, 0, 4.5),
                           extent: extracted.extent)
        let map = BuildingMap(name: "t", nodes: [corridor, room],
                              edges: [MapEdge(from: corridor.id, to: room.id, distance: 8.5)])
        let follower = RouteFollower(route: [corridor, room], graph: WaypointGraph(map: map))

        _ = follower.update(position: corridor.position, forward: SIMD3(0, 0, 1))
        let justInside = follower.update(position: SIMD3(2, 0, 0.6), forward: SIMD3(0, 0, 1))
        XCTAssertEqual(justInside.kind, .arrived,
                       "inside the room counts, even though the pin is ~4 m further on")
    }

    func testWithoutAnExtentArrivalFallsBackToTheRadius() {
        let corridor = MapNode(kind: .corridor, position: SIMD3(0, 0, 0))
        let room = MapNode(kind: .room, label: "Room 204", position: SIMD3(0, 0, -10)) // no extent
        let map = BuildingMap(name: "t", nodes: [corridor, room],
                              edges: [MapEdge(from: corridor.id, to: room.id, distance: 10)])
        let follower = RouteFollower(route: [corridor, room], graph: WaypointGraph(map: map))
        _ = follower.update(position: corridor.position, forward: SIMD3(0, 0, -1))
        XCTAssertEqual(follower.update(position: SIMD3(0, 0, -8), forward: SIMD3(0, 0, -1)).kind, .arrived,
                       "2 m away, inside the 2.5 m room radius - schema-1 maps still work")
    }

    /// Refusing to answer is better than inventing a room: an open space has no enclosing walls.
    func testOpenSpaceYieldsNoRoom() {
        XCTAssertNil(RoomExtractor.extract(seed: SIMD3(0, 0, 0), wallPoints: []),
                     "nothing around us at all")
        // Three walls: the fill escapes through the open side.
        var threeWalls = walls(width: 4, depth: 5)
        threeWalls.removeAll { $0.y > 4.9 }
        XCTAssertNil(RoomExtractor.extract(seed: SIMD3(2, 0, 2), wallPoints: threeWalls, maxRadius: 6))
    }

    func testCorridorIsNotMistakenForARoom() {
        // Two long parallel walls, open at both ends.
        var points: [SIMD2<Float>] = []
        var x: Float = -20
        while x <= 20 { points.append(SIMD2(x, 0)); points.append(SIMD2(x, 2)); x += 0.05 }
        XCTAssertNil(RoomExtractor.extract(seed: SIMD3(0, 0, 1), wallPoints: points, maxRadius: 10))
    }

    func testStandingInAWallIsRefused() {
        XCTAssertNil(RoomExtractor.extract(seed: SIMD3(0, 0, 0),
                                           wallPoints: walls(width: 4, depth: 5, origin: SIMD2(0, 0))))
    }

    /// A doorway narrower than the grid must not leak the fill into the corridor beyond.
    func testASmallDoorwayDoesNotLeak() throws {
        // Room with a 0.1 m gap - below the 0.15 m cell size, so it stays sealed.
        let result = try XCTUnwrap(RoomExtractor.extract(
            seed: SIMD3(2, 0, 2), wallPoints: walls(width: 4, depth: 5, doorGap: 2.0...2.1)))
        XCTAssertLessThan(result.areaSquareMeters, 25, "still just this room, not the floor beyond")
    }

    func testExtentSurvivesJSONRoundTrip() throws {
        let extent = RoomExtent(center: SIMD3(1, 0, 2), halfExtents: SIMD2(2, 3), yaw: 0.4,
                                areaSquareMeters: 21.5)
        let node = MapNode(kind: .room, label: "Room 204", position: SIMD3(1, 0, 2), extent: extent)
        let map = BuildingMap(name: "t", nodes: [node], edges: [])
        let decoded = try JSONDecoder().decode(BuildingMap.self, from: try map.jsonData())
        XCTAssertEqual(decoded.nodes.first?.extent, extent)
    }

    /// Schema-1 maps (no `extent` key at all) must still decode.
    func testOldMapsWithoutExtentsStillDecode() throws {
        let json = """
        {"id":"5A3E0000-0000-4000-8000-0000000000C1","name":"old","version":1,
         "nodes":[{"id":"5A3E0000-0000-4000-8000-0000000000C2","kind":"room","label":"Room 204",
                   "position":[1,0,2],"segmentId":"seg1","createdBy":"x"}],
         "edges":[]}
        """
        let map = try JSONDecoder().decode(BuildingMap.self, from: Data(json.utf8))
        XCTAssertNil(map.nodes.first?.extent)
        XCTAssertEqual(map.nodes.first?.label, "Room 204")
    }
}
