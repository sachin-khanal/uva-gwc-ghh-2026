//
// File:     Tests/WaypointCoreTests/MeshDecimatorTests.swift
// Purpose:  Scan meshes are shrunk to the export budget by vertex clustering without breaking triangles or shape.
//
import XCTest
import simd
@testable import WaypointCore

final class MeshDecimatorTests: XCTestCase {

    /// An n x n grid of unit-step vertices in the y=0 plane, two triangles per square.
    private func grid(_ n: Int, step: Float = 0.1) -> IndexedMesh {
        var v: [SIMD3<Float>] = []
        for z in 0...n { for x in 0...n { v.append([Float(x) * step, 0, Float(z) * step]) } }
        var idx: [UInt32] = []
        let w = n + 1
        for z in 0..<n { for x in 0..<n {
            let a = UInt32(z * w + x), b = a + 1, c = a + UInt32(w), d = c + 1
            idx += [a, b, c, b, d, c]
        } }
        return IndexedMesh(vertices: v, indices: idx)
    }

    private func assertValid(_ m: IndexedMesh, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.indices.count % 3, 0, file: file, line: line)
        XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.vertices.count }, "index out of range", file: file, line: line)
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            XCTAssertTrue(m.indices[t] != m.indices[t + 1] && m.indices[t + 1] != m.indices[t + 2] && m.indices[t] != m.indices[t + 2],
                          "degenerate triangle kept", file: file, line: line)
        }
    }

    func testClusteringShrinksButStaysValidAndFlat() {
        let m = grid(40) // 1681 vertices, 3200 triangles
        let c = MeshDecimator.cluster(m, cellSize: 0.5)
        assertValid(c)
        XCTAssertLessThan(c.vertices.count, m.vertices.count / 5)
        XCTAssertLessThan(c.triangleCount, m.triangleCount / 5)
        XCTAssertGreaterThan(c.triangleCount, 0)
        XCTAssertTrue(c.vertices.allSatisfy { abs($0.y) < 1e-5 }, "a flat floor stays flat")
    }

    func testTinyCellKeepsTheMeshAlmostUntouched() {
        let m = grid(10)
        let c = MeshDecimator.cluster(m, cellSize: 0.01)
        XCTAssertEqual(c.triangleCount, m.triangleCount)
        XCTAssertEqual(c.vertices.count, m.vertices.count)
    }

    func testDeterministic() {
        let m = grid(30)
        XCTAssertEqual(MeshDecimator.cluster(m, cellSize: 0.35), MeshDecimator.cluster(m, cellSize: 0.35))
    }

    func testBadInputIsDroppedNotCrashed() {
        let m = IndexedMesh(vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [.nan, 0, 0]],
                            indices: [0, 1, 2, 0, 1, 99, 0, 3, 1, 0, 1]) // ok, out-of-range, NaN vertex, trailing partial triangle
        let c = MeshDecimator.cluster(m, cellSize: 0.01)
        assertValid(c)
        XCTAssertEqual(c.triangleCount, 1)
        XCTAssertTrue(MeshDecimator.cluster(IndexedMesh(), cellSize: 1).isEmpty)
        XCTAssertEqual(MeshDecimator.cluster(m, cellSize: 0), m, "cell size 0 is a no-op")
    }

    func testFitLeavesAMeshThatAlreadyFitsAlone() {
        let m = grid(5)
        let r = MeshDecimator.fit(m)
        XCTAssertNil(r.cellSize)
        XCTAssertEqual(r.mesh, m)
        XCTAssertTrue(r.fitsBudget)
    }

    func testFitShrinksToTheBudgetAndKeepsAsMuchDetailAsPossible() {
        let m = grid(100) // 10201 vertices, 20000 triangles, ~0.5 MB estimated
        XCTAssertGreaterThan(m.estimatedBytes, 100_000)
        let r = MeshDecimator.fit(m, budgetBytes: 100_000, startCellSize: 0.05)
        XCTAssertTrue(r.fitsBudget)
        XCTAssertLessThanOrEqual(r.mesh.estimatedBytes, 100_000)
        XCTAssertNotNil(r.cellSize)
        assertValid(r.mesh)
        // a stricter budget never gives MORE detail
        let tighter = MeshDecimator.fit(m, budgetBytes: 20_000, startCellSize: 0.05)
        XCTAssertLessThanOrEqual(tighter.mesh.triangleCount, r.mesh.triangleCount)
    }

    func testImpossibleBudgetIsReportedNotHidden() {
        let r = MeshDecimator.fit(grid(30), budgetBytes: 10, maxPasses: 3)
        XCTAssertFalse(r.fitsBudget)
    }

    func testCropKeepsOnlyTrianglesInsideTheBox() {
        let m = grid(20) // 2 m x 2 m floor patch at y=0
        let inside = OrientedBox(center: [0.5, 0, 0.5], halfExtents: [0.5, 0.5, 0.5], yaw: 0)
        let c = MeshCrop.crop(m, to: inside)
        assertValid(c)
        XCTAssertGreaterThan(c.triangleCount, 0)
        XCTAssertLessThan(c.triangleCount, m.triangleCount / 3)
        XCTAssertTrue(c.vertices.allSatisfy { $0.x <= 1.2 && $0.z <= 1.2 })
        let nothing = MeshCrop.crop(m, to: OrientedBox(center: [50, 0, 50], halfExtents: [1, 1, 1], yaw: 0))
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertEqual(MeshCrop.crop(m, to: OrientedBox(center: [1, 0, 1], halfExtents: [5, 5, 5], yaw: 0)).triangleCount, m.triangleCount)
    }
}
