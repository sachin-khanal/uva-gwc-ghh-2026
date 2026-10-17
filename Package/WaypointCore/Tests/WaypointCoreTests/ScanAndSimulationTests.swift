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

    func testCameraTransformMatchesARKitConvention() {
        let t = Geometry.cameraTransform(position: [2, 1.5, -3], forward: [1, 0.7, 0]) // pitch ignored
        XCTAssertEqual(Geometry.translation(of: t), [2, 1.5, -3])
        let f = Geometry.cameraForward(of: t)
        XCTAssertEqual(f.x, 1, accuracy: 1e-5); XCTAssertEqual(f.y, 0, accuracy: 1e-5); XCTAssertEqual(f.z, 0, accuracy: 1e-5)
        // A point 3 m ahead and 1 m to the user's right (facing +x, right is +z) is local (+1, 0, -3).
        let world = SIMD3<Float>(2 + 3, 1.5, -3 + 1)
        let local = Geometry.transformPoint(t.inverse, world)
        XCTAssertEqual(local.x, 1, accuracy: 1e-4)
        XCTAssertEqual(local.z, -3, accuracy: 1e-4)
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
        XCTAssertTrue(spoken.contains("Turn right."), "the last leg into Room 204 is a right turn")
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
