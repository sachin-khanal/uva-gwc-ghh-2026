//
// File:     Tests/WaypointCoreTests/CoverageGridTests.swift
// Purpose:  The "unscanned areas" overlay: which tiles of the scan box have mesh behind them, the outline, dashes, bounds, resume guard.
//
import XCTest
import simd
@testable import WaypointCore

final class CoverageGridTests: XCTestCase {

    // A 4 m (x) by 2 m (y) by 2 m (z) box centred at the origin.
    private let box = OrientedBox(center: [0, 1, 0], halfExtents: [2, 1, 1], yaw: 0)

    private func floorPoints(step: Float = 0.1) -> [SIMD3<Float>] {
        stride(from: Float(-2), through: 2, by: step).flatMap { x in
            stride(from: Float(-1), through: 1, by: step).map { SIMD3<Float>(x, 0.02, $0) }
        }
    }

    func testNothingScannedMeansEverythingIsUncoveredAndCoverageIsZero() {
        let g = CoverageGrid(box: box)
        XCTAssertEqual(g.coverage, 0)
        XCTAssertEqual(g.uncoveredTiles().count, g.tileCount)
        XCTAssertGreaterThan(g.tileCount, 0)
    }

    func testScanningTheFloorCoversTheFloorAndLeavesTheCeilingOpen() {
        var g = CoverageGrid(box: box, cellSize: 0.5)
        g.add(points: floorPoints())
        let open = g.uncoveredTiles()
        XCTAssertTrue(open.filter { $0.face == .floor }.isEmpty, "every floor tile has mesh behind it")
        XCTAssertEqual(open.filter { $0.face == .ceiling }.count, 8 * 4, "nothing scanned up there yet")
        XCTAssertGreaterThan(g.coverage, 0)
        XCTAssertLessThan(g.coverage, 0.5)
    }

    func testAWallPointOnlyCoversItsOwnTile() {
        var g = CoverageGrid(box: box, cellSize: 0.5)
        g.add(points: [[2, 1, 0.1]]) // on the +x wall, mid height, just right of centre
        XCTAssertEqual(g.scannedCount, 1)
        let open = g.uncoveredTiles()
        XCTAssertEqual(open.count, g.tileCount - 1)
        // exactly one tile of the +x wall is missing from the open list: the one around z=0.1, y=1
        let wallOpen = open.filter { $0.face == .maxX }
        XCTAssertEqual(wallOpen.count, 4 * 4 - 1)
        XCTAssertFalse(wallOpen.contains { t in
            let c = t.corners.reduce(SIMD3<Float>.zero, +) / 4
            return abs(c.z - 0.25) < 0.01 && abs(c.y - 1.25) < 0.01
        })
    }

    func testPointsInTheMiddleOfTheRoomCoverNothing() {
        var g = CoverageGrid(box: box, cellSize: 0.5, tolerance: 0.3)
        g.add(points: [[0, 1, 0], [0.5, 1.2, 0.3]])
        XCTAssertEqual(g.scannedCount, 0)
    }

    func testPointsOutsideTheBoxAreIgnored() {
        var g = CoverageGrid(box: box)
        g.add(points: [[10, 1, 0], [0, 9, 0], [0, 1, -5]])
        XCTAssertEqual(g.scannedCount, 0)
    }

    func testCoverageOnlyGrowsAndReachesOneWhenEveryFaceIsSampled() {
        var g = CoverageGrid(box: box, cellSize: 0.5)
        var last: Float = 0
        // sample the box surface densely from all six sides
        var pts: [SIMD3<Float>] = []
        let s: Float = 0.1
        for x in stride(from: Float(-2), through: 2, by: s) { for z in stride(from: Float(-1), through: 1, by: s) { pts.append([x, 0, z]); pts.append([x, 2, z]) } }
        for y in stride(from: Float(0), through: 2, by: s) { for z in stride(from: Float(-1), through: 1, by: s) { pts.append([-2, y, z]); pts.append([2, y, z]) } }
        for y in stride(from: Float(0), through: 2, by: s) { for x in stride(from: Float(-2), through: 2, by: s) { pts.append([x, y, -1]); pts.append([x, y, 1]) } }
        for chunk in stride(from: 0, to: pts.count, by: 500) {
            g.add(points: Array(pts[chunk..<min(pts.count, chunk + 500)]))
            XCTAssertGreaterThanOrEqual(g.coverage, last)
            last = g.coverage
        }
        XCTAssertEqual(g.coverage, 1, accuracy: 0.001)
        XCTAssertTrue(g.uncoveredTiles().isEmpty)
        XCTAssertTrue(g.outline().isEmpty)
    }

    func testRotatedBoxMapsPointsThroughItsOwnAxes() {
        let rotated = OrientedBox(center: [5, 1, 5], halfExtents: [2, 1, 1], yaw: .pi / 2)
        var g = CoverageGrid(box: rotated, cellSize: 0.5)
        // the box's +x wall, after a 90 degree turn about y, faces world -z (see OrientedBox.rotateY): find a point ON it via corners
        let c = rotated.corners()
        let onFloor = (c[0] + c[1]) / 2 + SIMD3<Float>(0, 0.05, 0) // midpoint of a floor edge, slightly above
        g.add(points: [onFloor])
        XCTAssertGreaterThanOrEqual(g.scannedCount, 1)
        XCTAssertTrue(g.uncoveredTiles().allSatisfy { t in t.corners.allSatisfy { rotated.contains($0, slack: 0.05) } }, "tiles stay on the box")
    }

    func testTilesLieInsideTheBoxAndNormalsPointInward() {
        let g = CoverageGrid(box: box, cellSize: 0.5)
        for t in g.uncoveredTiles() {
            XCTAssertEqual(t.corners.count, 4)
            XCTAssertTrue(t.corners.allSatisfy { box.contains($0, slack: 0.001) })
            let centre = t.corners.reduce(SIMD3<Float>.zero, +) / 4
            XCTAssertGreaterThan(simd_dot(box.center - centre, t.normal), 0, "inward normal \(t.face)")
        }
    }

    func testOutlineRingsAnIslandOfUnscannedTiles() {
        var g = CoverageGrid(box: OrientedBox(center: [0, 0.5, 0], halfExtents: [1, 0.5, 1], yaw: 0), cellSize: 0.5, tolerance: 0.1)
        // scan the whole floor except the single tile around (0.25, 0.25)
        var pts: [SIMD3<Float>] = []
        for x in stride(from: Float(-1), through: 1, by: 0.05) { for z in stride(from: Float(-1), through: 1, by: 0.05) {
            if x > 0 && x < 0.5 && z > 0 && z < 0.5 { continue }
            pts.append([x, 0, z])
        } }
        g.add(points: pts)
        let floorOpen = g.uncoveredTiles().filter { $0.face == .floor }
        XCTAssertEqual(floorOpen.count, 1)
        let floorOutline = g.outline().filter { $0.normal == [0, 1, 0] }
        XCTAssertEqual(floorOutline.count, 4, "one open tile has four outline edges")
    }

    func testDashedSplitsAndRespectsLength() {
        let seg = CoverageSegment(a: [0, 0, 0], b: [1, 0, 0], normal: [0, 1, 0])
        let dashes = CoverageGrid.dashed([seg], dash: 0.1, gap: 0.1)
        XCTAssertEqual(dashes.count, 5)
        XCTAssertTrue(dashes.allSatisfy { simd_distance($0.a, $0.b) <= 0.1001 })
        XCTAssertEqual(CoverageGrid.dashed([seg], dash: 0.1, gap: 0).count, 10)
        XCTAssertEqual(CoverageGrid.dashed([seg], dash: 0, gap: 0.1), [seg], "invalid dash leaves the segment alone")
    }

    func testHugeBoxStaysWithinTheTileBudget() {
        let huge = OrientedBox(center: [0, 1.5, 0], halfExtents: [60, 1.5, 30], yaw: 0)
        let g = CoverageGrid(box: huge, maxTiles: 4000)
        XCTAssertLessThanOrEqual(g.tileCount, 4400, "grew the tile size to stay bounded")
        XCTAssertGreaterThan(g.cellSize, 0.4)
    }

    func testResumeGuard() {
        XCTAssertTrue(ResumeGuard.canResume(pausedAt: [0, 0, 0], now: [1, 0, 1]))
        XCTAssertFalse(ResumeGuard.canResume(pausedAt: [0, 0, 0], now: [0, 0, 5]))
        XCTAssertTrue(ResumeGuard.canResume(pausedAt: nil, now: [9, 0, 9]), "unknown positions must never trap the user")
        XCTAssertEqual(ResumeGuard.message(distance: 4.6), "You are 5 meters from where you paused. Walk back to that spot, then resume.")
    }
}
